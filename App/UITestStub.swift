#if DEBUG
import ConnectAuth
import ConnectCalls
import ConnectChat
import ConnectCore
import ConnectFeatures
import ConnectInbox
import ConnectRooms
import ConnectSettings
import ConnectNetworking
import ConnectTestSupport
import Foundation
import UIKit

/// Офлайн-ответы сервисов для XCUITest: реальная логика авторизации и звонков, но без сети,
/// Keychain и WebRTC.
enum UITestStub {
    static let launchArgument = "-ui-test-stub"
    /// После входа ждёт входящий звонок от первого контакта.
    static let incomingCallArgument = "-ui-test-incoming-call"
    /// Сессия уже сохранена: приложение открывается сразу на главном экране.
    static let signedInArgument = "-ui-test-signed-in"
    /// Не стирать последнее место при запуске: проверка восстановления навигации.
    static let keepNavigationArgument = "-ui-test-keep-navigation"
    /// Медиасервер не отвечает: панель ошибок подключения.
    static let mediaDownArgument = "-ui-test-media-down"
    /// Доступ к микрофону запрещён: подсказка с настройками.
    static let microphoneDeniedArgument = "-ui-test-mic-denied"

    struct MediaProbe: MediaServerProbe {
        let reachable: Bool
        func isReachable() async -> Bool { reachable }
    }

    /// Отдельный набор настроек, чтобы тесты не видели навигацию друг друга.
    static func navigationDefaults(arguments: [String]) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ui-test-navigation") ?? .standard
        if !arguments.contains(keepNavigationArgument) {
            defaults.removePersistentDomain(forName: "ui-test-navigation")
        }
        return defaults
    }
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

        transport.on("/api/user/register-profile") { request in
            decode(request.httpBody)["username"] == "@taken"
                ? json(409, #"{"errMessage":"Пользователь с таким логином уже существует"}"#)
                : json(200, #"{"code":211,"message":"Код верификации отправлен на почту."}"#)
        }

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

    /// Чаты стаба: личный с непрочитанным, группа и пустой чат.
    static func makeChatAPI() -> FakeChatAPI {
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let partner = "qa_wallpaper_2"
        let messages = [
            ChatMessage(id: "00000000-0000-4000-8000-000000000001", text: "Привет! Созвонимся?", createdAtMilliseconds: base - 26 * 3_600_000, authorId: "qa-2", username: partner),
            ChatMessage(id: "00000000-0000-4000-8000-000000000002", text: "__P2P_CALL_SUMMARY__:125|\(base - 25 * 3_600_000)", createdAtMilliseconds: base - 25 * 3_600_000, authorId: "qa-1", username: "@qa_wallpaper_1"),
            ChatMessage(id: "00000000-0000-4000-8000-000000000003", text: "Отлично поговорили", createdAtMilliseconds: base - 600_000, authorId: "qa-1", username: "@qa_wallpaper_1", weights: [WeightRange(id: "w1", from: 0, to: 6, state: .bold)]),
            ChatMessage(id: "00000000-0000-4000-8000-000000000004", text: "Да, скинул файл", createdAtMilliseconds: base - 300_000, authorId: "qa-2", username: partner, attachments: [ChatAttachment(urlS3: "chat/plan.pdf", name: "План", extension: ".pdf"), ChatAttachment(urlS3: "file-chat/room-qa-2/photo.png", name: "photo", extension: ".png")], markers: [MarkerRange(id: "m1", from: 12, to: 15, color: "#ffe066")]),
        ]
        return FakeChatAPI(
            ownerUsername: "@qa_wallpaper_1",
            rooms: [
                .p2p: [
                    ChatSummary(kind: .p2p, roomId: "room-qa-2", title: "QA Wallpaper Two", partnerUserId: "qa-2", partnerUsername: partner, preview: ChatPreview(text: "Да, скинул файл", createdAtMilliseconds: base - 300_000)),
                    ChatSummary(kind: .p2p, roomId: "room-qa-3", title: "QA Wallpaper Three", partnerUserId: "qa-3"),
                ],
                .group: [
                    ChatSummary(kind: .group, roomId: "group-1", title: "QA Group", preview: ChatPreview(text: nil, createdAtMilliseconds: base - 7_200_000, fileInfos: [.init(fileType: "IMAGE", count: 2)])),
                ],
            ],
            messages: ["room-qa-2": messages, "room-qa-3": [], "group-1": [], "channel-general": [
                ChatMessage(id: "00000000-0000-4000-8000-000000000010", text: "Добро пожаловать в комнату", createdAtMilliseconds: base - 3_600_000, authorId: "qa-2", username: partner),
            ]],
            summary: NotificationSummary(unread: 1, chats: [
                UnreadChat(chatId: "room-qa-2", chatType: "P2P", unread: 1, firstUnreadMessageId: "00000000-0000-4000-8000-000000000004"),
            ])
        )
    }

    /// Контакты стаба и «справочник» для поиска: `@qa_wallpaper_4` можно найти и добавить.
    static func makeContactsRepository() -> FakeContactsRepository {
        FakeContactsRepository(
            contacts: ["qa-1": contacts],
            directory: contacts + [
                Contact(userId: "qa-4", name: "QA Wallpaper Four", username: "qa_wallpaper_4", status: .online, avatarKey: "user-gallery/qa-4/avatar.png"),
                Contact(userId: "qa-1", name: "QA Wallpaper", username: "qa_wallpaper_1", status: .online),
            ]
        )
    }

    /// Уведомление о сообщении и входящее приглашение в группу.
    static func makeInboxAPI() -> FakeInboxAPI {
        FakeInboxAPI(
            notifications: [
                InboxNotification(id: 7, messageId: "00000000-0000-4000-8000-000000000004", chatId: "room-qa-2", chatType: .p2p, body: "Да, скинул файл", createdAt: Date().addingTimeInterval(-300)),
            ],
            invitations: [
                Invitation(id: "inv-1", kind: .group, targetId: "group-1", senderUserId: "qa-2", recipientUserId: "qa-1", senderName: "QA Wallpaper Two", recipientName: "QA Wallpaper", targetName: "QA Group", createdAt: Date().addingTimeInterval(-600)),
            ]
        )
    }

    /// Комната с каналами и событием в календаре, канал-лента с постами.
    static func makeRoomsAPI() -> FakeRoomsAPI {
        let now = Date()
        return FakeRoomsAPI(
            rooms: [RoomDetails(id: "room-1", name: "QA Room", channels: [
                RoomChannel(id: "channel-general", name: "general", kind: .text),
                RoomChannel(id: "channel-voice", name: "Голосовой", kind: .voice),
            ])],
            roles: ["room-1": .admin],
            events: ["room-1": [RoomEvent(id: "event-1", title: "Планёрка", description: "Обсуждаем релиз", startsAt: Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: now) ?? now)]],
            feeds: [PostFeedCard(id: "feed-1", name: "QA News", lastPost: "Первый пост", lastPostAtMilliseconds: Int64(now.timeIntervalSince1970 * 1000))],
            feedRoles: ["feed-1": .admin],
            posts: ["feed-1": [FeedPost(id: "post-1", text: "Первый пост", createdAtMilliseconds: Int64(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000), username: "qa_wallpaper_1", uniqueViewsCount: 12, commentsCount: 1)]],
            feedMembers: ["feed-1": FeedMembers(
                admin: .init(userId: "qa-1", username: "qa_wallpaper_1"),
                subscribers: [.init(userId: "qa-1", username: "qa_wallpaper_1"), .init(userId: "qa-2", username: "qa_wallpaper_2")]
            )],
            comments: ["post-1": [PostComment(id: "comment-1", postId: "post-1", text: "Отличная новость", createdAtMilliseconds: Int64(now.addingTimeInterval(-1800).timeIntervalSince1970 * 1000), userId: "qa-2", username: "qa_wallpaper_2")]]
        )
    }

    /// После входа ждёт входящий групповой звонок в «QA Group».
    static let incomingGroupCallArgument = "-ui-test-incoming-group-call"

    static func makeGroupCallAPI(arguments: [String]) -> FakeGroupCallAPI {
        let incoming = GroupCallRecord(id: "group-call-incoming", callerUserId: "qa-2", groupChatId: "group-1", name: "QA Group", participants: [("qa-2", "stub")], callees: [.init(userId: "qa-1", canceled: false)])
        return FakeGroupCallAPI(records: [incoming], pendingIncoming: arguments.contains(incomingGroupCallArgument) ? incoming : nil)
    }

    /// Комната группового звонка или голосового канала: собеседник qa-2 появляется через полсекунды.
    @MainActor
    static func makeGroupRoom() -> FakeCallRoom {
        let room = FakeCallRoom()
        room.onPublish = { room in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                room.emitRemoteAudio(userId: "qa-2")
            }
        }
        return room
    }

    /// Файлы стаба: аватар найденного пользователя и картинка в чате.
    static func makeFileAPI() -> FakeFileAPI {
        FakeFileAPI(files: [
            "user-gallery/qa-4/avatar.png": solidImage(color: .systemTeal),
            "file-chat/room-qa-2/photo.png": solidImage(color: .systemOrange),
            "user-gallery/qa-3/greeting.png": solidImage(color: .systemPink),
        ])
    }

    private static func solidImage(color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    /// SSE без событий: реальный поток в стабе не нужен, звонки идут через FakeP2PCallAPI.
    struct SilentEventStream: EventStreamTransport {
        func events(for request: URLRequest) -> AsyncThrowingStream<ServerSentEvent, any Error> {
            AsyncThrowingStream { _ in }
        }
    }

    /// `-ui-test-theme dracula`: тема оформления для скриншотов; без аргумента — тема по умолчанию.
    static func appearance(arguments: [String]) -> AppearancePreferences {
        guard let index = arguments.firstIndex(of: "-ui-test-theme"), index + 1 < arguments.count,
              let theme = AppearanceTheme(rawValue: arguments[index + 1]) else { return .standard }
        return AppearancePreferences.standard.selecting(theme)
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
