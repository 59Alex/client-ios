import ConnectCalls
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectChat

@MainActor
@Suite("Экраны чатов")
struct ChatModelTests {
    let api = FakeChatAPI()
    let me = ChatUser(userId: "me", username: "@me")
    let now = Date(timeIntervalSince1970: 1_757_800_000)

    private func makeChat(unread: UnreadModel? = nil, rooms: RoomBox = RoomBox()) -> ChatModel {
        let now = now
        return ChatModel(
            kind: .p2p,
            roomId: "room",
            title: "Иван",
            me: me,
            api: api,
            unread: unread,
            rtcUrl: URL(string: "wss://rtc.cnnect.ru/livekit")!,
            makeRoom: {
                let room = FakeCallRoom()
                rooms.rooms.append(room)
                return room
            },
            now: { now },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
    }

    private func message(_ index: Int, author: String = "ivan") -> ChatMessage {
        ChatMessage(id: String(format: "00000000-0000-4000-8000-%012d", 1000 + index), text: "m\(index)", createdAtMilliseconds: Int64(index), username: author)
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    @Test("список чатов грузит все страницы и сортирует по последнему сообщению")
    func chatList() async {
        var rooms = (0..<25).map { ChatSummary(kind: .p2p, roomId: "r\($0)", title: "R\($0)", preview: ChatPreview(text: "t", createdAtMilliseconds: Int64($0))) }
        rooms.append(ChatSummary(kind: .p2p, roomId: "empty", title: "Пусто"))
        await api.setRooms(rooms, kind: .p2p)
        let model = ChatListModel(kind: .p2p, api: api)

        await model.load()

        #expect(model.chats.count == 26)
        #expect(model.chats.first?.roomId == "r24")
        #expect(model.chats.last?.roomId == "empty")
    }

    @Test("открытие чата: снимок, догрузка истории до конца")
    func loadAndPaginate() async {
        await api.setPageSize(20)
        await api.setMessages((1...45).map { message($0) }, roomId: "room")
        let chat = makeChat()

        await chat.load()
        #expect(chat.state == .loaded)
        #expect(chat.messages.count == 20)
        #expect(chat.messages.first?.text == "m45")
        #expect(chat.hasMore)

        await chat.loadMore()
        await chat.loadMore()
        #expect(chat.messages.count == 45)
        #expect(!chat.hasMore)
    }

    @Test("граница непрочитанного глубже первой страницы догружается")
    func loadsUntilFirstUnread() async {
        await api.setPageSize(10)
        await api.setMessages((1...30).map { message($0) }, roomId: "room")
        let target = message(3).id
        await api.setSummary(NotificationSummary(unread: 28, chats: [UnreadChat(chatId: "room", chatType: "P2P", unread: 28, firstUnreadMessageId: target)]))
        let unread = UnreadModel(api: api)
        await unread.refresh()
        let chat = makeChat(unread: unread)

        await chat.load()

        #expect(chat.firstUnreadMessageId == target)
        #expect(chat.messages.contains { $0.id == target })
    }

    @Test("отправка: сразу в ленте, затем серверный id и сигнал chat")
    func send() async throws {
        await api.setMessages([], roomId: "room")
        let rooms = RoomBox()
        let chat = makeChat(rooms: rooms)
        await chat.load()
        let realtime = Task { await chat.runRealtime() }
        await settle()
        let room = try #require(rooms.rooms.first)
        #expect(room.token == "text-token-room")
        #expect(chat.isConnected)

        chat.draft = "  привет  "
        await chat.send()

        #expect(chat.draft.isEmpty)
        #expect(chat.messages.count == 1)
        let sent = try #require(chat.messages.first)
        #expect(sent.text == "привет")
        #expect(sent.delivery == .sent)
        #expect(sent.clientMessageId == "local-p2p-1757800000000-me")
        #expect(await api.sent.first?.dateTimeCreateTimestamp == 1_757_800_000_000)
        let packet = try #require(room.sentPackets.last)
        #expect(packet.client == #"{"clientData":"@me"}"#)
        #expect(ChatSignal(packet: packet) == .message(sent))
        realtime.cancel()
    }

    @Test("ошибка отправки помечает сообщение, повтор доставляет его")
    func sendFailureAndRetry() async throws {
        await api.setMessages([], roomId: "room")
        await api.setFailSend(true)
        let chat = makeChat()
        await chat.load()

        chat.draft = "текст"
        await chat.send()
        let failed = try #require(chat.messages.first)
        #expect(failed.delivery == .failed)

        await api.setFailSend(false)
        await chat.retry(failed.id)
        #expect(chat.messages.count == 1)
        #expect(chat.messages.first?.delivery == .sent)
    }

    @Test("сигналы собеседника: новое сообщение, удаление, оформление")
    func incomingSignals() async throws {
        await api.setMessages([message(1)], roomId: "room")
        let rooms = RoomBox()
        let chat = makeChat(rooms: rooms)
        await chat.load()
        let realtime = Task { await chat.runRealtime() }
        await settle()
        let room = try #require(rooms.rooms.first)

        let incoming = ChatMessage(id: "server-2", text: "новое", createdAtMilliseconds: 9, username: "ivan")
        room.emit(.data(topic: "ov-signal", payload: ChatSignal.message(incoming).packet(client: "").encoded()))
        await settle()
        #expect(chat.messages.first?.id == "server-2")

        room.emit(.data(topic: "ov-signal", payload: ChatSignal.edit(messageId: "server-2", diapason: .weight(WeightRange(id: "w", from: 0, to: 2, state: .bold))).packet(client: "").encoded()))
        await settle()
        #expect(chat.messages.first?.weights.first?.state == .bold)

        room.emit(.data(topic: "ov-signal", payload: ChatSignal.delete(messageId: "server-2").packet(client: "").encoded()))
        await settle()
        #expect(chat.messages.map(\.id) == [message(1).id])
        realtime.cancel()
    }

    @Test("удаление своего сообщения уходит на сервер и сигналом")
    func deleteMessage() async throws {
        let own = message(1, author: "me")
        await api.setMessages([own], roomId: "room")
        let rooms = RoomBox()
        let chat = makeChat(rooms: rooms)
        await chat.load()
        let realtime = Task { await chat.runRealtime() }
        await settle()

        #expect(await chat.delete(own.id))
        #expect(chat.messages.isEmpty)
        #expect(await api.deleted == [own.id])
        #expect(try #require(rooms.rooms.first).sentPackets.last?.type == "chat:delete:\(own.id)")
        realtime.cancel()
    }

    @Test("прочитанными отмечаются только чужие сохранённые сообщения, пачкой")
    func markRead() async {
        let theirs = message(1)
        let mine = message(2, author: "@ME")
        let call = ChatMessage(id: "00000000-0000-4000-8000-000000009999", text: "__P2P_CALL_SUMMARY__:5|1", createdAtMilliseconds: 3, username: "ivan")
        await api.setMessages([theirs, mine, call], roomId: "room")
        let unread = UnreadModel(api: api, sleep: { _ in })
        let chat = makeChat(unread: unread)
        await chat.load()

        chat.markVisible([theirs.id, mine.id, call.id, "local-1"])
        await unread.flush()

        #expect(await api.readBatches == [[theirs.id]])
        chat.markVisible([theirs.id])
        #expect(await api.readBatches.count == 1)
    }

    @Test("сводка непрочитанного по чатам и типам")
    func unreadSummary() async {
        await api.setSummary(NotificationSummary(unread: 7, chats: [
            UnreadChat(chatId: "a", chatType: "P2P", unread: 3),
            UnreadChat(chatId: "b", chatType: "GROUP", unread: 4),
        ]))
        let unread = UnreadModel(api: api)
        await unread.refresh()

        #expect(unread.unreadCount(kind: .p2p, roomId: "a") == 3)
        #expect(unread.unreadCount(kind: .group) == 4)
        #expect(unread.revision == 1)
        await unread.refresh()
        #expect(unread.revision == 1)
    }
}

@MainActor
final class RoomBox {
    var rooms: [FakeCallRoom] = []
}
