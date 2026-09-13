import ConnectAuth
import ConnectCore
import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectFeatures

@MainActor
@Suite("LoginModel и SessionModel")
struct LoginModelTests {
    let transport = StubTransport()
    let auth: AuthService

    init() throws {
        auth = AuthService(
            userApiUrl: try #require(URL(string: "https://user.cnnect.ru")),
            transport: transport,
            store: InMemoryTokenStore()
        )
    }

    var tokenJSON: String {
        #"{"token":{"access_token":"\#(TestJWT.make(expiresAt: Date().addingTimeInterval(3600)))","refresh_token":"r"}}"#
    }

    @Test("кнопка входа активна только с логином и паролем")
    func credentialsValidation() {
        let model = LoginModel(auth: auth)
        #expect(!model.canSubmitCredentials)

        model.username = "   "
        model.password = "secret"
        #expect(!model.canSubmitCredentials)

        model.username = "@qa"
        #expect(model.canSubmitCredentials)
    }

    @Test("требование подтверждения переводит на ввод кода")
    func switchesToVerification() async {
        transport.on("/api/auth/login", status: 511, json: "{}")
        let model = LoginModel(auth: auth)
        model.username = "@qa"
        model.password = "secret"

        await model.submitCredentials()

        #expect(model.step == .emailVerification)
        #expect(model.infoMessage == "Подтвердите email кодом из письма")
        #expect(model.errorMessage == nil)
    }

    @Test("код подтверждения — ровно 6 цифр")
    func verificationCodeValidation() {
        let model = LoginModel(auth: auth)
        model.verificationCode = "12345"
        #expect(!model.canSubmitVerification)
        model.verificationCode = "12345a"
        #expect(!model.canSubmitVerification)
        model.verificationCode = "123456"
        #expect(model.canSubmitVerification)
    }

    @Test("подтверждение без токена выполняет повторный вход")
    func verificationWithoutTokenLogsIn() async throws {
        transport.on("/api/auth/verify-email", json: "{}")
        transport.on("/api/auth/login", json: tokenJSON)
        let model = LoginModel(auth: auth)
        model.username = "@qa"
        model.password = "secret"
        model.verificationCode = "123456"

        await model.submitVerification()

        #expect(model.errorMessage == nil)
        #expect(await auth.hasSession)
    }

    @Test("ошибка сервиса показывается пользователю")
    func showsServiceError() async {
        transport.on("/api/auth/login", status: 401, json: #"{"errMessage":"Неверный логин или пароль"}"#)
        let model = LoginModel(auth: auth)
        model.username = "@qa"
        model.password = "wrong"

        await model.submitCredentials()

        #expect(model.errorMessage == "Неверный логин или пароль")
        #expect(!model.isSubmitting)
    }

    @Test("после входа сессия загружает профиль")
    func sessionLoadsUserAfterLogin() async throws {
        let user = User(userId: "u1", name: "QA", email: "qa@example.com", username: "@qa", status: .online)
        let session = SessionModel(auth: auth, users: FixedUsers(user: user))
        let running = Task { await session.run() }
        defer { running.cancel() }

        try await waitUntil { session.state == .signedOut }

        transport.on("/api/auth/login", json: tokenJSON)
        try await auth.login(username: "@qa", password: "secret")

        try await waitUntil { session.state == .signedIn(user) }

        await session.logout()
        #expect(session.state == .signedOut)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

private struct FixedUsers: UserRepository {
    let user: User

    func currentUser() async throws -> User { user }
    func addPhoto(userId: String, urlS3: String, name: String, extension: String, isAvatar: Bool) async throws {}
    func card(userId: String) async throws -> Contact { Contact(userId: userId, name: user.name, username: user.username) }
}
