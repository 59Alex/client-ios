#if DEBUG
import ConnectAuth
import ConnectCalls
import ConnectCore
import ConnectNetworking
import ConnectTestSupport
import Foundation

/// Офлайн-ответы сервисов для XCUITest: реальная логика авторизации и звонков, но без сети,
/// Keychain и WebRTC.
enum UITestStub {
    static let launchArgument = "-ui-test-stub"
    /// После входа ждёт входящий звонок от первого контакта.
    static let incomingCallArgument = "-ui-test-incoming-call"
    /// Сессия уже сохранена: приложение открывается сразу на главном экране.
    static let signedInArgument = "-ui-test-signed-in"
    /// Логин, для которого сервис требует подтвердить email.
    static let verificationUsername = "@verify"
    static let verificationCode = "123456"

    static let contacts = [
        Contact(userId: "qa-2", name: "QA Wallpaper Two", username: "qa_wallpaper_2", status: .online),
        Contact(userId: "qa-3", name: "QA Wallpaper Three", username: "qa_wallpaper_3", status: .offline, lastSeenAt: Date().addingTimeInterval(-3600)),
    ]

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

        transport.on("/api/user-card/get-contacts/qa-1") { _ in
            json(200, #"""
            [{"userId":"qa-3","name":"QA Wallpaper Three","username":"qa_wallpaper_3","status":"OFFLINE","lastSeenAt":"2026-09-13T08:00:00Z"},
             {"userId":"qa-2","name":"QA Wallpaper Two","username":"qa_wallpaper_2","status":"ONLINE"}]
            """#)
        }

        transport.on("/api/status/login") { _ in json(200, #"{"sessionId":"stub-session"}"#) }
        transport.on("/api/status/heartbeat/pulse") { _ in json(200, "{}") }

        return transport
    }

    /// Модель звонка с фейковой комнатой: собеседник «берёт трубку» через полсекунды.
    @MainActor
    static func makeCallModel(me: CallParticipant, arguments: [String]) -> P2PCallModel {
        let api = FakeP2PCallAPI(contacts: contacts)
        let model = P2PCallModel(
            me: me,
            api: api,
            rtcUrl: AppConfig.test.rtcWebSocketUrl,
            makeRoom: {
                let room = FakeCallRoom()
                room.onPublish = { room in
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        room.emitRemoteAudio(userId: "qa-2")
                    }
                }
                return room
            },
            sessionId: { "stub-session" },
            requestMicrophone: { true }
        )
        if arguments.contains(incomingCallArgument) {
            // Вызов уже ждёт в outbox: модель находит его при старте подписки на события.
            Task { await api.setPendingIncoming(.call(callId: "incoming-1", callerUserId: "qa-2", calleeUserId: me.userId)) }
        }
        return model
    }

    /// SSE без событий: реальный поток в стабе не нужен, звонки идут через FakeP2PCallAPI.
    struct SilentEventStream: EventStreamTransport {
        func events(for request: URLRequest) -> AsyncThrowingStream<ServerSentEvent, any Error> {
            AsyncThrowingStream { _ in }
        }
    }

    static func makeTokenStore(arguments: [String]) -> InMemoryTokenStore {
        guard arguments.contains(signedInArgument) else { return InMemoryTokenStore() }
        let access = TestJWT.make(expiresAt: Date().addingTimeInterval(3600))
        return InMemoryTokenStore(tokens: AuthTokens(accessToken: access, refreshToken: "stub-refresh", createdAt: Date()))
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
