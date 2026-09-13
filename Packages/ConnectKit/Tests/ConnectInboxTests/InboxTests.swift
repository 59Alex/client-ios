import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectInbox

@MainActor
@Suite("Уведомления, приглашения, группы")
struct InboxTests {
    @Test("уведомление сервиса разбирается, заголовок по типу чата")
    func decodesNotification() throws {
        let json = #"[{"id":12,"messageId":"m","senderUserId":"u","chatId":"r","chatType":"ROOM_EVENT","body":"","createdAt":"2026-09-14T10:00:00Z","roomName":"Команда","viewedAt":null,"messageReadAt":null},{"id":"13","chatType":"WHATEVER","body":"hi"}]"#
        let items = try JSONDecoder().decode([InboxNotification].self, from: Data(json.utf8))
        #expect(items[0].title == "Событие · Команда")
        #expect(items[0].bodyText == "Вложение")
        #expect(items[0].createdAt != nil)
        #expect(items[1].id == 13)
        #expect(items[1].title == "Сообщение в канале")
        #expect(InboxNotification(id: 1, chatType: .p2p).title == "Личное сообщение")
        #expect(InboxNotification(id: 1, chatType: .group).title == "Сообщение в группе")
    }

    @Test("центр уведомлений: прочитанные скрыты, догрузка, просмотр, скрытие")
    func notificationCenter() async {
        let items = (1...35).map { InboxNotification(id: Int64($0), chatId: "r", chatType: .p2p, body: "n\($0)") }
            + [InboxNotification(id: 99, chatType: .p2p, messageReadAt: Date())]
        let api = FakeInboxAPI(notifications: items)
        let model = NotificationCenterModel(api: api)

        await model.load()
        #expect(model.items.first?.id == 35)
        #expect(model.items.count == 29)
        #expect(model.hasMore)

        await model.loadMore()
        #expect(model.items.count == 35)
        #expect(!model.hasMore)

        await model.markViewed([35, 34, 35])
        await model.markViewed([35])
        #expect(await api.viewed == [35, 34])
        #expect(model.unviewedCount == 33)

        await model.dismiss(34)
        #expect(!model.items.contains { $0.id == 34 })
        #expect(await api.dismissed == [34])

        await model.dismissAll()
        #expect(model.items.isEmpty)
    }

    @Test("приглашения делятся на входящие и исходящие, текст для контакта")
    func invitationsSplit() async {
        let api = FakeInboxAPI(invitations: [
            Invitation(id: "1", kind: .group, targetId: "g", senderUserId: "u", recipientUserId: "me", senderName: "Иван", targetName: "Команда"),
            Invitation(id: "2", kind: .room, targetId: "r", senderUserId: "me", recipientUserId: "u", recipientName: "Иван", targetName: "Комната"),
            Invitation(id: "3", kind: .contact, targetId: nil, senderUserId: "u", recipientUserId: "me", senderName: "Иван", status: .accepted),
        ])
        let model = InvitationsModel(me: "me", api: api, sleep: { _ in })
        await model.load()

        #expect(model.incoming.map(\.id) == ["1", "3"])
        #expect(model.outgoing.map(\.id) == ["2"])
        #expect(model.pendingCount == 2)
        #expect(model.title(of: model.incoming[1]) == "Иван добавил(а) вас в контакты")
        #expect(model.incoming[0].subtitle == "Приглашение в групповой чат")
    }

    @Test("решение ждёт смены статуса и возвращает принятое приглашение")
    func acceptWaitsForProcessing() async {
        let invitation = Invitation(id: "1", kind: .group, targetId: "g", senderUserId: "u", recipientUserId: "me", targetName: "Команда")
        let api = FakeInboxAPI(invitations: [invitation])
        await api.setDecisionDelayPolls(2)
        let model = InvitationsModel(me: "me", api: api, sleep: { _ in })

        let accepted = await model.decide(invitation, action: .accept)

        #expect(accepted?.status == .accepted)
        #expect(accepted?.targetId == "g")
        #expect(await api.decisions.map(\.action) == [.accept])
        #expect(model.processingIds.isEmpty)
        #expect(model.message == nil)
    }

    @Test("долгая обработка решения показывает сообщение, отказ не возвращает приглашение")
    func slowDecision() async {
        let invitation = Invitation(id: "1", kind: .room, targetId: "r", senderUserId: "u", recipientUserId: "me")
        let api = FakeInboxAPI(invitations: [invitation])
        await api.setDecisionDelayPolls(100)
        let model = InvitationsModel(me: "me", api: api, sleep: { _ in })

        #expect(await model.decide(invitation, action: .accept) == nil)
        #expect(model.message == "Ответ принят в обработку. Статус обновится чуть позже.")

        let other = FakeInboxAPI(invitations: [invitation])
        let declining = InvitationsModel(me: "me", api: other, sleep: { _ in })
        #expect(await declining.decide(invitation, action: .decline) == nil)
        #expect(declining.invitations.first?.status == .declined)
    }

    @Test("создание группы: название обязательно и обрезается, себя в участники не добавить")
    func createGroup() async {
        let api = FakeInboxAPI()
        let model = CreateGroupModel(me: "me", api: api)

        model.name = "   "
        #expect(!model.canSubmit)
        #expect(!(await model.submit()))
        #expect(model.errorMessage == "Укажите название чата")

        model.name = String(repeating: "я", count: 250)
        #expect(model.name.count == 199)
        model.name = "  Команда  "
        model.toggle("u2")
        model.toggle("me")
        model.toggle("u1")
        model.meetingsAllowed = true

        #expect(await model.submit())
        #expect(await api.createdGroups == [NewGroup(name: "Команда", creatorUserId: "me", memberUserIds: ["u1", "u2"], meetingsAllowed: true)])
    }

    @Test("запросы API: тело решения с полем action, создание группы и приглашение")
    func remoteBodies() async throws {
        let transport = StubTransport()
        transport.on("/api/invitations/inv-1/decision", json: "{}")
        transport.on("/api/invitations", json: #"{"id":"x"}"#)
        transport.on("/api/group-room/create", json: "")
        transport.on("/api/notifications/dismiss-all", json: #"{"dismissedThroughId":456}"#)
        let base = try #require(URL(string: "https://example.test"))
        let api = RemoteInboxAPI(main: HTTPClient(baseURL: base, transport: transport), notifications: HTTPClient(baseURL: base, transport: transport))

        try await api.decide(invitationId: "inv-1", action: .cancel)
        try await api.invite(kind: .group, targetId: "g", recipientUserId: "u")
        try await api.createGroup(NewGroup(name: "G", creatorUserId: "me", memberUserIds: ["u"], meetingsAllowed: false))
        #expect(try await api.dismissAll() == 456)

        func body(_ path: String) throws -> [String: Any] {
            let data = try #require(transport.requests(to: path).first?.httpBody)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try body("/api/invitations/inv-1/decision")["action"] as? String == "CANCEL")
        let invite = try body("/api/invitations")
        #expect(invite["type"] as? String == "GROUP")
        #expect(invite["recipientUserId"] as? String == "u")
        let group = try body("/api/group-room/create")
        #expect((group["creator"] as? [String: Any])?["userId"] as? String == "me")
        #expect(group["memberUserIds"] as? [String] == ["u"])
        #expect(group["meetingsAllowed"] as? Bool == false)
    }
}
