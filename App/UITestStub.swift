#if DEBUG
import ConnectNetworking
import ConnectTestSupport
import Foundation

/// Офлайн-ответы сервисов для XCUITest: реальная логика авторизации, но без сети и Keychain.
enum UITestStub {
    static let launchArgument = "-ui-test-stub"
    /// Логин, для которого сервис требует подтвердить email.
    static let verificationUsername = "@verify"
    static let verificationCode = "123456"

    static func makeTransport() -> StubTransport {
        let transport = StubTransport()

        transport.on("/api/auth/login") { request in
            let body = decode(request.httpBody)
            if body["username"] == verificationUsername {
                return json(511, #"{"message":"Подтвердите email кодом из письма"}"#)
            }
            if body["password"] != "password" {
                return json(401, #"{"errMessage":"Неверный логин или пароль"}"#)
            }
            return json(200, tokenResponse())
        }

        transport.on("/api/auth/verify-email") { request in
            decode(request.httpBody)["code"] == verificationCode
                ? json(200, tokenResponse())
                : json(400, #"{"errMessage":"Неверный код"}"#)
        }

        transport.on("/api/auth/refresh") { _ in json(200, tokenResponse()) }

        transport.on("/api/user-card/get-by-jwt") { _ in
            json(200, #"{"userId":"qa-1","phoneNumber":null,"name":"QA Wallpaper","email":"qa@example.com","username":"@qa_wallpaper_1","status":"ONLINE","contacts":[]}"#)
        }

        return transport
    }

    private static func tokenResponse() -> String {
        let access = TestJWT.make(expiresAt: Date().addingTimeInterval(3600))
        return #"{"token":{"access_token":"\#(access)","refresh_token":"stub-refresh"}}"#
    }

    private static func decode(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func json(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(body.utf8))
    }
}
#endif
