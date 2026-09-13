import ConnectNetworking
import Foundation

/// Сессия устройства в `connect-status-service`. Звонки привязаны к `sessionId`:
/// когда сессия умирает, events-channel-service снимает участника её звонков.
public actor StatusService {
    /// Пульс чаще, чем веб-клиент подтверждает присутствие (20 с), чтобы сессия не истекала.
    public static let pulseInterval: Duration = .seconds(15)

    private let client: HTTPClient
    private let sleep: @Sendable (Duration) async throws -> Void
    private var sessionId: String?
    private var pendingLogin: Task<String?, Never>?

    public init(
        client: HTTPClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.sleep = sleep
    }

    /// Идентификатор сессии; `nil`, если статус-сервис недоступен — звонки тогда работают без неё.
    public func currentSessionId(userId: String) async -> String? {
        if let sessionId { return sessionId }
        if let pendingLogin { return await pendingLogin.value }

        let client = client
        let task = Task<String?, Never> {
            let request = SessionRequest(userId: userId, sessionId: nil)
            guard let response = try? await client.postDecoded("/api/status/login", json: request, as: SessionResponse.self) else {
                return nil
            }
            return response.sessionId
        }
        pendingLogin = task
        let result = await task.value
        pendingLogin = nil
        sessionId = result
        return result
    }

    /// Держит сессию живой, пока задача не отменена. Ошибки сети не прерывают цикл.
    public func keepAlive(userId: String) async {
        while !Task.isCancelled {
            if let sessionId = await currentSessionId(userId: userId) {
                _ = try? await client.post("/api/status/heartbeat/pulse", json: SessionRequest(userId: userId, sessionId: sessionId))
            }
            do {
                try await sleep(Self.pulseInterval)
            } catch {
                return
            }
        }
    }

    /// Закрывает сессию при выходе из аккаунта.
    public func logout(userId: String) async {
        guard let sessionId else { return }
        self.sessionId = nil
        _ = try? await client.post("/api/status/unlogin", json: SessionRequest(userId: userId, sessionId: sessionId))
    }
}

private struct SessionRequest: Encodable, Sendable {
    let userId: String
    let sessionId: String?
}

private struct SessionResponse: Decodable, Sendable {
    let sessionId: String?
}
