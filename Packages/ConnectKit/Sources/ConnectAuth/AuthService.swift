import ConnectNetworking
import Foundation

public enum AuthError: Error, Sendable, Equatable {
    /// Нужно подтвердить email кодом из письма.
    case emailVerificationRequired(message: String?)
    /// Сервис не смог отправить письмо с кодом.
    case emailDeliveryFailed(message: String?)
    /// Вход отклонён; сообщение сервиса, если оно есть.
    case rejected(message: String?)
    /// Ответ без токена.
    case missingToken
}

public enum SessionEvent: Sendable, Equatable {
    case signedIn
    case signedOut
}

/// Сессия пользователя поверх `connect-user-service`: вход, подтверждение email,
/// обновление токенов и выдача bearer-токена остальным клиентам.
public actor AuthService: AccessTokenProvider {
    static let emailVerificationRequiredCodes: Set<Int> = [211, 501, 511]
    static let emailDeliveryErrorCode = 512
    /// Токен обновляется заранее, если жить ему осталось меньше этого интервала.
    static let refreshLeeway: TimeInterval = 2 * 60

    private let client: HTTPClient
    private let store: any TokenStore
    private let now: @Sendable () -> Date
    private var tokens: AuthTokens?
    private var pendingRefresh: Task<AuthTokens, any Error>?
    private var observers: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]

    public init(
        userApiUrl: URL,
        transport: any HTTPTransport,
        store: any TokenStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        client = HTTPClient(baseURL: userApiUrl, transport: transport)
        self.store = store
        self.now = now
        tokens = store.load()
    }

    public var hasSession: Bool {
        guard let tokens else { return false }
        return !tokens.isAccessTokenExpired(now: now()) || tokens.refreshToken != nil
    }

    public func sessionEvents() -> AsyncStream<SessionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    // MARK: - Login

    public func login(username: String, password: String) async throws {
        clearTokens(notify: false)

        let response = try await client.post("/api/auth/login", json: Credentials(username: username, password: password))
        let object = Self.jsonObject(response.body)
        let body = try? JSONDecoder().decode(APIErrorBody.self, from: response.body)

        guard response.isSuccess else {
            let codes = [response.statusCode, body?.code].compactMap { $0 }
            if codes.contains(Self.emailDeliveryErrorCode) {
                throw AuthError.emailDeliveryFailed(message: body?.displayMessage)
            }
            if codes.contains(where: Self.emailVerificationRequiredCodes.contains) {
                throw AuthError.emailVerificationRequired(message: body?.displayMessage)
            }
            throw AuthError.rejected(message: body?.displayMessage)
        }

        let code = body?.code ?? response.statusCode
        if code == Self.emailDeliveryErrorCode {
            throw AuthError.emailDeliveryFailed(message: body?.message)
        }
        if object?["emailVerificationRequired"] as? Bool == true || Self.emailVerificationRequiredCodes.contains(code) {
            throw AuthError.emailVerificationRequired(message: body?.message)
        }

        try saveTokens(from: object?["token"])
    }

    /// Подтверждает email. Возвращает `true`, если сервис сразу выдал токены.
    public func verifyEmail(username: String, code: String) async throws -> Bool {
        let response = try await client.post("/api/auth/verify-email", json: EmailVerification(username: username, code: code))
        guard response.isSuccess else {
            let body = try? JSONDecoder().decode(APIErrorBody.self, from: response.body)
            throw AuthError.rejected(message: body?.displayMessage)
        }

        guard let token = Self.jsonObject(response.body)?["token"] else { return false }
        try saveTokens(from: token)
        return true
    }

    /// Регистрация профиля. `true` — сервис отправил код подтверждения на почту (код 211).
    public func register(_ profile: NewProfile) async throws -> Bool {
        let response = try await client.post("/api/user/register-profile", json: profile)
        let body = try? JSONDecoder().decode(APIErrorBody.self, from: response.body)
        let code = body?.code ?? response.statusCode
        if code == 211 || response.statusCode == 211 {
            return true
        }
        guard response.isSuccess else {
            throw AuthError.rejected(message: body?.displayMessage)
        }
        return false
    }

    public func logout() {
        clearTokens(notify: true)
    }

    // MARK: - AccessTokenProvider

    public func validAccessToken() async -> String? {
        guard let current = tokens else { return nil }

        if let refreshToken = current.refreshToken, isExpiringSoon(current) {
            do {
                return try await refresh(using: refreshToken).accessToken
            } catch {
                // Временный сбой обновления не должен разлогинивать при ещё живом токене.
            }
        }

        guard let latest = tokens, !latest.isAccessTokenExpired(now: now()) else { return nil }
        return latest.accessToken
    }

    public func handleUnauthorized() {
        clearTokens(notify: true)
    }

    // MARK: - Refresh

    /// Одновременные вызовы разделяют один запрос обновления.
    func refresh(using refreshToken: String) async throws -> AuthTokens {
        if let pendingRefresh {
            return try await pendingRefresh.value
        }

        let client = client
        let createdAt = now()
        let task = Task<AuthTokens, any Error> {
            let response = try await client.post("/api/auth/refresh", json: RefreshRequest(refreshToken: refreshToken))
            guard response.isSuccess else {
                throw APIError.http(statusCode: response.statusCode, body: try? JSONDecoder().decode(APIErrorBody.self, from: response.body))
            }
            let object = Self.jsonObject(response.body)
            let tokenResponse = (object?["token"] as? [String: Any]) ?? object ?? [:]
            guard var tokens = AuthTokens(tokenResponse: tokenResponse, createdAt: createdAt) else {
                throw AuthError.missingToken
            }
            tokens.refreshToken = tokens.refreshToken ?? refreshToken
            return tokens
        }
        pendingRefresh = task
        defer { pendingRefresh = nil }

        let refreshed = try await task.value
        // Пользователь мог выйти, пока шёл запрос.
        if tokens?.refreshToken == refreshToken {
            tokens = refreshed
            store.save(refreshed)
        }
        return refreshed
    }

    // MARK: - Private

    private func isExpiringSoon(_ tokens: AuthTokens) -> Bool {
        guard let expiresAt = tokens.accessTokenExpiresAt else { return false }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshLeeway
    }

    private func saveTokens(from tokenResponse: Any?) throws {
        guard
            let tokenResponse = tokenResponse as? [String: Any],
            let newTokens = AuthTokens(tokenResponse: tokenResponse, createdAt: now())
        else { throw AuthError.missingToken }

        tokens = newTokens
        store.save(newTokens)
        notify(.signedIn)
    }

    private func clearTokens(notify shouldNotify: Bool) {
        let hadTokens = tokens != nil
        tokens = nil
        pendingRefresh = nil
        store.clear()
        if shouldNotify && hadTokens {
            notify(.signedOut)
        }
    }

    private func notify(_ event: SessionEvent) {
        for continuation in observers.values {
            continuation.yield(event)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private struct Credentials: Encodable, Sendable {
    let username: String
    let password: String
}

private struct EmailVerification: Encodable, Sendable {
    let username: String
    let code: String
}

private struct RefreshRequest: Encodable, Sendable {
    let refreshToken: String
}

/// Тело `POST /api/user/register-profile`.
public struct NewProfile: Encodable, Sendable, Equatable {
    public var username: String
    public var password: String
    public var email: String
    public var name: String
    public var phoneNumber: String?

    public init(username: String, password: String, email: String, name: String, phoneNumber: String?) {
        self.username = username
        self.password = password
        self.email = email
        self.name = name
        self.phoneNumber = phoneNumber
    }
}
