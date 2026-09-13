import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectAuth

@Suite("AuthService")
struct AuthServiceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let transport = StubTransport()
    let store = InMemoryTokenStore()

    func makeService() throws -> AuthService {
        let now = now
        return AuthService(
            userApiUrl: try #require(URL(string: "https://user.cnnect.ru")),
            transport: transport,
            store: store,
            now: { now }
        )
    }

    func tokenJSON(expiresIn seconds: TimeInterval, refresh: String? = "refresh-1", snakeCase: Bool = true) -> String {
        let access = TestJWT.make(expiresAt: now.addingTimeInterval(seconds))
        let accessKey = snakeCase ? "access_token" : "accessToken"
        let refreshKey = snakeCase ? "refresh_token" : "refreshToken"
        guard let refresh else { return #"{"\#(accessKey)":"\#(access)"}"# }
        return #"{"\#(accessKey)":"\#(access)","\#(refreshKey)":"\#(refresh)"}"#
    }

    @Test("успешный вход сохраняет токены", arguments: [true, false])
    func loginSavesTokens(snakeCase: Bool) async throws {
        transport.on("/api/auth/login", json: #"{"token":\#(tokenJSON(expiresIn: 3600, snakeCase: snakeCase))}"#)
        let service = try makeService()

        try await service.login(username: "@qa", password: "secret")

        #expect(store.load()?.refreshToken == "refresh-1")
        #expect(await service.hasSession)
        let body = try #require(transport.requests(to: "/api/auth/login").first?.httpBody)
        let sent = try JSONDecoder().decode([String: String].self, from: body)
        #expect(sent == ["username": "@qa", "password": "secret"])
    }

    @Test("коды 211/501/511 требуют подтверждения email", arguments: [211, 501, 511])
    func verificationRequiredByStatus(status: Int) async throws {
        transport.on("/api/auth/login", status: status, json: #"{"message":"Подтвердите"}"#)
        let service = try makeService()

        await #expect(throws: AuthError.emailVerificationRequired(message: "Подтвердите")) {
            try await service.login(username: "@qa", password: "secret")
        }
    }

    @Test("флаг emailVerificationRequired в успешном ответе")
    func verificationRequiredByFlag() async throws {
        transport.on("/api/auth/login", json: #"{"emailVerificationRequired":true}"#)
        let service = try makeService()

        await #expect(throws: AuthError.emailVerificationRequired(message: nil)) {
            try await service.login(username: "@qa", password: "secret")
        }
        #expect(store.load() == nil)
    }

    @Test("код 512 в теле — ошибка отправки письма")
    func emailDeliveryFailure() async throws {
        transport.on("/api/auth/login", status: 400, json: #"{"code":"512","errMessage":"SMTP"}"#)
        let service = try makeService()

        await #expect(throws: AuthError.emailDeliveryFailed(message: "SMTP")) {
            try await service.login(username: "@qa", password: "secret")
        }
    }

    @Test("отказ передаёт сообщение сервиса")
    func rejectedLogin() async throws {
        transport.on("/api/auth/login", status: 401, json: #"{"errMessage":"Неверный пароль"}"#)
        let service = try makeService()

        await #expect(throws: AuthError.rejected(message: "Неверный пароль")) {
            try await service.login(username: "@qa", password: "wrong")
        }
    }

    @Test("живой токен выдаётся без обновления")
    func freshTokenIsReturned() async throws {
        let access = TestJWT.make(expiresAt: now.addingTimeInterval(3600))
        store.save(AuthTokens(accessToken: access, refreshToken: "refresh-1", createdAt: now))
        let service = try makeService()

        #expect(await service.validAccessToken() == access)
        #expect(transport.requests.isEmpty)
    }

    @Test("истекающий токен обновляется, refresh token сохраняется, если сервис его не прислал")
    func expiringTokenIsRefreshed() async throws {
        store.save(AuthTokens(accessToken: TestJWT.make(expiresAt: now.addingTimeInterval(30)), refreshToken: "refresh-1", createdAt: now))
        transport.on("/api/auth/refresh", json: tokenJSON(expiresIn: 3600, refresh: nil))
        let service = try makeService()

        let token = await service.validAccessToken()

        #expect(token != nil)
        #expect(store.load()?.accessToken == token)
        #expect(store.load()?.refreshToken == "refresh-1")
    }

    @Test("одновременные запросы разделяют одно обновление")
    func concurrentRefreshIsShared() async throws {
        store.save(AuthTokens(accessToken: TestJWT.make(expiresAt: now.addingTimeInterval(-10)), refreshToken: "refresh-1", createdAt: now))
        let json = tokenJSON(expiresIn: 3600)
        transport.on("/api/auth/refresh") { _ in
            try await Task.sleep(for: .milliseconds(50))
            return HTTPResponse(statusCode: 200, body: Data(json.utf8))
        }
        let service = try makeService()

        async let first = service.validAccessToken()
        async let second = service.validAccessToken()
        let tokens = await [first, second]

        #expect(tokens[0] != nil && tokens[0] == tokens[1])
        #expect(transport.requests(to: "/api/auth/refresh").count == 1)
    }

    @Test("сбой обновления не разлогинивает при ещё живом токене")
    func refreshFailureKeepsValidToken() async throws {
        let access = TestJWT.make(expiresAt: now.addingTimeInterval(60))
        store.save(AuthTokens(accessToken: access, refreshToken: "refresh-1", createdAt: now))
        transport.on("/api/auth/refresh", status: 503, json: "{}")
        let service = try makeService()

        #expect(await service.validAccessToken() == access)
    }

    @Test("истёкший токен без обновления не выдаётся")
    func expiredTokenWithoutRefresh() async throws {
        store.save(AuthTokens(accessToken: TestJWT.make(expiresAt: now.addingTimeInterval(-10)), createdAt: now))
        let service = try makeService()

        #expect(await service.validAccessToken() == nil)
        #expect(await !service.hasSession)
    }

    @Test("401 очищает хранилище и сообщает о выходе")
    func unauthorizedSignsOut() async throws {
        store.save(AuthTokens(accessToken: TestJWT.make(expiresAt: now.addingTimeInterval(3600)), createdAt: now))
        let service = try makeService()
        let events = await service.sessionEvents()

        await service.handleUnauthorized()

        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .signedOut)
        #expect(store.load() == nil)
    }

    @Test("подтверждение email с токеном входит в сессию")
    func verifyEmailSignsIn() async throws {
        transport.on("/api/auth/verify-email", json: #"{"token":\#(tokenJSON(expiresIn: 3600))}"#)
        let service = try makeService()

        #expect(try await service.verifyEmail(username: "@qa", code: "123456"))
        #expect(await service.hasSession)
    }
}
