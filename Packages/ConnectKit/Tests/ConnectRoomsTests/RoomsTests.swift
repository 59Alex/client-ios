import ConnectChat
import ConnectNetworking
import ConnectTestSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ConnectRooms

@MainActor
@Suite("Комнаты, календарь и каналы-ленты")
struct RoomsTests {
    @Test("комната сервиса: каналы в порядке сервиса, роль строкой")
    func decodesRoom() throws {
        let json = #"{"id":"r","name":"Команда","channels":[{"id":"t1","name":"general","type":"TEXT","channelMembers":[]},{"id":"v1","name":"Голос","type":"VOICE"}],"roomMembers":[{"userId":"u","name":"Иван","username":"ivan"}]}"#
        let room = try JSONDecoder().decode(RoomDetails.self, from: Data(json.utf8))
        #expect(room.channels.map(\.kind) == [.text, .voice])
        #expect(room.members.first?.userId == "u")
        #expect(try JSONDecoder().decode(MemberRole.self, from: Data(#""MODERATOR""#.utf8)).canManage)
    }

    @Test("ссылка-приглашение: base64 id комнаты, код уходит без декодирования")
    func inviteLinks() throws {
        let origin = try #require(URL(string: "https://cnnect.ru"))
        let url = InviteLinks.roomURL(origin: origin, roomId: "0b8f2c1e-1111-2222-3333-444455556666")
        #expect(url.absoluteString == "https://cnnect.ru/invite/MGI4ZjJjMWUtMTExMS0yMjIyLTMzMzMtNDQ0NDU1NTU2NjY2")
        #expect(InviteLinks.roomCode(from: url.absoluteString) == "MGI4ZjJjMWUtMTExMS0yMjIyLTMzMzMtNDQ0NDU1NTU2NjY2")
        #expect(InviteLinks.roomCode(from: "  abc%3D  ") == "abc%3D")
        #expect(InviteLinks.roomCode(from: "https://cnnect.ru/invite/abc%3D") == "abc=")
        #expect(InviteLinks.roomCode(from: "https://example.com/other") == nil)
    }

    @Test("комнаты: непрочитанное по текстовым каналам, создание и вход по ссылке")
    func roomsList() async {
        let api = FakeRoomsAPI(rooms: [RoomDetails(id: "r", name: "Команда", channels: [RoomChannel(id: "t1", name: "general", kind: .text), RoomChannel(id: "t2", name: "random", kind: .text), RoomChannel(id: "v", name: "Голос", kind: .voice)])])
        let chats = FakeChatAPI(summary: NotificationSummary(unread: 5, chats: [
            UnreadChat(chatId: "t1", chatType: "ROOM", unread: 2),
            UnreadChat(chatId: "t2", chatType: "ROOM", unread: 3),
            UnreadChat(chatId: "t1", chatType: "P2P", unread: 9),
        ]))
        let unread = UnreadModel(api: chats)
        await unread.refresh()
        let model = RoomsModel(me: "me", api: api)
        await model.load()

        #expect(model.unreadCount(model.rooms[0], unread: unread) == 5)
        #expect(await model.createRoom(name: "  ") == "Укажите название комнаты")
        #expect(await model.createRoom(name: String(repeating: "a", count: 200)) != nil)
        #expect(await model.createRoom(name: " Новая ") == nil)
        #expect(model.rooms.map(\.name) == ["Команда", "Новая"])
        #expect(await model.join(link: "https://cnnect.ru/invite/Q09ERQ==") == nil)
        #expect(await api.joinedCodes == ["Q09ERQ=="])
    }

    @Test("комната: разделение каналов, создание канала только с правами")
    func roomChannels() async {
        let api = FakeRoomsAPI(rooms: [RoomDetails(id: "r", name: "R", channels: [RoomChannel(id: "v", name: "Голос", kind: .voice), RoomChannel(id: "t", name: "general", kind: .text)])], roles: ["r": .subscriber])
        let model = RoomModel(roomId: "r", me: "me", api: api)
        await model.load()

        #expect(model.textChannels.map(\.id) == ["t"])
        #expect(model.voiceChannels.map(\.id) == ["v"])
        #expect(!model.canManage)
        #expect(await model.createChannel(name: "news", kind: .text) == "Не удалось создать канал. Проверьте права")

        let admin = RoomModel(roomId: "r", me: "me", api: FakeRoomsAPI(rooms: [RoomDetails(id: "r", name: "R", channels: [])], roles: ["r": .admin]))
        await admin.load()
        #expect(await admin.createChannel(name: String(repeating: "x", count: 81), kind: .text) != nil)
        #expect(await admin.createChannel(name: " news ", kind: .text) == nil)
        #expect(admin.textChannels.map(\.name) == ["news"])
    }

    @Test("календарь: сетка 6 недель с понедельника, валидация напоминаний")
    func calendar() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Moscow"))
        let september = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 14)))
        let range = RoomCalendarModel.gridRange(for: september, calendar: calendar)
        #expect(calendar.component(.weekday, from: range.lowerBound) == 2)
        #expect(calendar.component(.day, from: range.lowerBound) == 31)
        #expect(range.upperBound.timeIntervalSince(range.lowerBound) == 42 * 86400)

        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12)))
        let starts = now.addingTimeInterval(3 * 86400)
        let api = FakeRoomsAPI()
        let model = RoomCalendarModel(roomId: "r", api: api, calendar: calendar, now: { now })

        #expect(model.validate(title: " ", description: "", startsAt: starts, reminders: []) == "Укажите название события")
        #expect(model.validate(title: "Созвон", description: "", startsAt: starts, reminders: [now.addingTimeInterval(-60)]) != nil)
        #expect(model.validate(title: "Созвон", description: "", startsAt: starts, reminders: [starts.addingTimeInterval(60)]) != nil)
        #expect(model.validate(title: "Созвон", description: "", startsAt: starts, reminders: [now.addingTimeInterval(3600), now.addingTimeInterval(7200)]) == "Напоминания должны быть не чаще чем раз в 12 часов")
        let five = (1...5).map { now.addingTimeInterval(Double($0) * 13 * 3600) }
        #expect(model.validate(title: "Созвон", description: "", startsAt: starts, reminders: five) == "Не больше 4 напоминаний")

        #expect(await model.create(title: " Созвон ", description: "", startsAt: starts, reminders: [starts.addingTimeInterval(-86400)]) == nil)
        #expect(model.events.map(\.title) == ["Созвон"])
        #expect(model.events(on: starts).count == 1)
    }

    @Test("событие календаря кодируется ISO с миллисекундами в UTC")
    func eventEncoding() throws {
        let event = RoomEvent(id: "", title: "Стендап", startsAt: Date(timeIntervalSince1970: 1_789_452_000), notificationTimes: [Date(timeIntervalSince1970: 1_789_408_800)])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        #expect(object["startsAt"] as? String == "2026-09-15T06:00:00.000Z")
        #expect(object["notificationTimes"] as? [String] == ["2026-09-14T18:00:00.000Z"])
        #expect(object["id"] == nil)
    }

    @Test("канал-лента: посты по возрастанию, догрузка старых, публикация для админа")
    func feed() async {
        let posts = (1...25).map { FeedPost(id: "p\($0)", text: "пост \($0)", createdAtMilliseconds: Int64($0), username: "owner") }
        let api = FakeRoomsAPI(feeds: [PostFeedCard(id: "f", name: "Новости", lastPostAtMilliseconds: 25)], feedRoles: ["f": .admin], posts: ["f": posts])
        let model = FeedModel(feedId: "f", me: ChatUser(userId: "me", username: "me"), api: api, now: { Date(timeIntervalSince1970: 100) })

        await model.load()
        #expect(model.posts.count == 20)
        #expect(model.posts.first?.id == "p6")
        #expect(model.posts.last?.id == "p25")
        #expect(model.hasOlder)
        #expect(model.canPost)
        #expect(!model.canUnsubscribe)

        await model.loadOlder()
        #expect(model.posts.first?.id == "p1")

        model.draft = "  Анонс  "
        #expect(await model.publish())
        #expect(model.posts.last?.text == "Анонс")
        #expect(model.draft.isEmpty)
    }

    @Test("подписчик не публикует, может отписаться; неподписанный подписывается")
    func feedSubscription() async {
        let api = FakeRoomsAPI(feedRoles: ["f": .subscriber])
        let model = FeedModel(feedId: "f", me: ChatUser(userId: "me", username: "me"), api: api)
        await model.load()
        #expect(!model.canPost)
        #expect(model.canUnsubscribe)

        await model.setSubscribed(false)
        #expect(model.role == nil)
        #expect(!model.isSubscribed)

        await model.setSubscribed(true)
        #expect(model.role == .subscriber)
    }

    @Test("список лент сортируется по последнему посту, создание требует название")
    func feedsList() async {
        let api = FakeRoomsAPI(feeds: [PostFeedCard(id: "a", name: "A", lastPostAtMilliseconds: 1), PostFeedCard(id: "b", name: "B", lastPostAtMilliseconds: 5)])
        let model = FeedsModel(me: "me", api: api)
        await model.load()
        #expect(model.feeds.map(\.id) == ["b", "a"])
        #expect(await model.create(name: " ") == "Укажите название канала")
        #expect(await model.create(name: "C") == nil)
        #expect(model.feeds.count == 3)
    }

    @Test("сообщения текстового канала: массив без страниц, channelId в теле и в токене")
    func channelChatRequests() async throws {
        let transport = StubTransport()
        transport.on("/api/chat-message/get-for-channel/c1", json: #"[{"id":"m","message":"hi","dateTimeCreateTimestamp":1,"username":"ivan"}]"#)
        transport.on("/api/chat-message/create", json: #"{"id":"new"}"#)
        transport.on("/api/connection/get-token", json: #"{"openviduConnectionUri":"tok"}"#)
        let client = HTTPClient(baseURL: try #require(URL(string: "https://domain.cnnect.ru")), transport: transport)
        let api = RemoteChatAPI(main: client, notifications: client, eventStream: NoEvents())

        let snapshot = try await api.snapshot(.channel, roomId: "c1")
        #expect(snapshot.messages.content.map(\.id) == ["m"])
        #expect(!snapshot.messages.hasMore)
        #expect(try await api.send(.channel, message: OutgoingMessage(userId: "me", roomId: "c1", message: "x", dateTimeCreateTimestamp: 2)) == "new")
        #expect(try await api.textToken(.channel, userId: "me", roomId: "c1") == "tok")

        let body = try #require(transport.requests(to: "/api/chat-message/create").first?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["channelId"] as? String == "c1")
        #expect(object["roomId"] == nil)
        let tokenBody = try #require(transport.requests(to: "/api/connection/get-token").first?.httpBody)
        #expect(String(decoding: tokenBody, as: UTF8.self).contains(#""channelId":"c1""#))
    }
}

private struct NoEvents: EventStreamTransport {
    func events(for request: URLRequest) -> AsyncThrowingStream<ServerSentEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
