import ConnectCalls
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectChat

@Suite("Модели и протокол чатов")
struct ChatProtocolTests {
    @Test("сообщение сервиса разбирается со всеми полями")
    func decodesServerMessage() throws {
        let json = #"""
        {"id":"m-1","message":"привет","dateTimeCreateTimestamp":1757800000000,"userCardId":"u-1","username":"ivan",
         "attachedFiles":[{"urlS3":"chat/1.jpg","previewUrlS3":null,"name":"photo","extension":".jpg"}],
         "markeredTexts":[{"id":"d1","from":0,"to":4,"color":"#ffe066"}],
         "weightTexts":[{"id":"d2","from":0,"to":2,"state":"BOLD"}]}
        """#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))

        #expect(message.id == "m-1")
        #expect(message.text == "привет")
        #expect(message.authorId == "u-1")
        #expect(message.attachments.first?.kind == .image)
        #expect(message.markers == [MarkerRange(id: "d1", from: 0, to: 4, color: "#ffe066")])
        #expect(message.weights.first?.state == .bold)
        #expect(message.isOwn(username: "@Ivan"))
    }

    @Test("гостевое сообщение группы подписано именем гостя")
    func guestMessage() throws {
        let json = #"{"id":"g","message":"hi","dateTimeCreateTimestamp":1,"userCardId":null,"guestId":"x","guestDisplayName":null}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        #expect(message.username == "Гость")
        #expect(message.guestName == "Гость")
    }

    @Test("вид вложения по имени и расширению", arguments: [
        ("voice-message-1", ".webm", ChatAttachment.Kind.voiceMessage),
        ("video-message-1", ".mp4", .videoMessage),
        ("clip", ".MOV", .video),
        ("song", ".mp3", .audio),
        ("doc", ".pdf", .pdf),
        ("table", ".xlsx", .spreadsheet),
        ("pack", ".zip", .archive),
        ("notes", ".txt", .document),
        ("x", ".bin", .file),
    ])
    func attachmentKinds(name: String, ext: String, kind: ChatAttachment.Kind) {
        #expect(ChatAttachment(urlS3: "k", name: name, extension: ext).kind == kind)
    }

    @Test("итоги звонков разбираются, неверная длительность личного — обычный текст")
    func callSummaries() {
        let p2p = CallSummary(text: "__P2P_CALL_SUMMARY__:75|1757800000000")
        #expect(p2p?.isGroup == false)
        #expect(p2p?.durationText == "1:15")
        #expect(p2p?.startedAt == Date(timeIntervalSince1970: 1_757_800_000))
        #expect(CallSummary(text: "__P2P_CALL_SUMMARY__:0|1") == nil)
        #expect(CallSummary(text: "GROUP_CALL_SUMMURY:3700|1")?.durationText == "1:01:40")
        #expect(CallSummary(text: "GROUP_CALL_SUMMARY:bad|1")?.durationSeconds == 1)
        #expect(CallSummary(text: "обычный текст") == nil)
    }

    @Test("превью списка: текст, звонок или счётчики файлов с русским множественным числом")
    func previews() {
        #expect(ChatPreview(text: "hi", createdAtMilliseconds: 1).summaryText == "hi")
        #expect(ChatPreview(text: "__P2P_CALL_SUMMARY__:5|1", createdAtMilliseconds: 1).summaryText == "Созвон завершён")
        let files = ChatPreview(text: nil, createdAtMilliseconds: 1, fileInfos: [
            .init(fileType: "IMAGE", count: 2), .init(fileType: "VIDEO", count: 5), .init(fileType: "FILE", count: 11),
        ])
        #expect(files.summaryText == "2 изображения, 5 видео, 11 файлов")
        #expect(ChatPreview.plural(21, "файл", "файла", "файлов") == "файл")
    }

    @Test("строка личного чата: собеседник из chatPartner, имя или логин")
    func p2pRoom() throws {
        let json = #"[{"id":"r","name":"  ","username":"ivan","userId":"old","chatPartner":{"userId":"p"},"previewMessage":{"text":"hi","dateTimeCreateTimestamp":5,"fileInfos":[]}}]"#
        let room = try #require(try JSONDecoder().decode([P2PRoomDTO].self, from: Data(json.utf8)).first).summary
        #expect(room.title == "ivan")
        #expect(room.partnerUserId == "p")
        #expect(room.preview?.createdAtMilliseconds == 5)
    }

    @Test("сигнал chat совместим с веб-клиентом в обе стороны")
    func chatSignal() throws {
        let message = ChatMessage(id: "m", clientMessageId: "local-p2p-1-me", text: "hello", createdAtMilliseconds: 1_757_800_000_000, authorId: "me", username: "ivan")
        let packet = ChatSignal.message(message).packet(client: #"{"clientData":"ivan"}"#)
        #expect(packet.type == "chat")
        let body = try #require(JSONSerialization.jsonObject(with: Data(packet.data.utf8)) as? [String: Any])
        #expect(body["message"] as? String == "hello")
        #expect(body["clientMessageId"] as? String == "local-p2p-1-me")
        #expect((body["dateTimeCreateTimestamp"] as? NSNumber)?.int64Value == 1_757_800_000_000)
        #expect(ChatSignal(packet: packet) == .message(message))

        let web = SignalPacket(type: "chat", data: #"{"message":"x","username":"web","dateTimeCreateTimestamp":2}"#, client: "")
        guard case let .message(decoded)? = ChatSignal(packet: web) else {
            Issue.record("сигнал веб-клиента не разобран")
            return
        }
        #expect(decoded.id == "web-2")
        #expect(ChatSignal(packet: SignalPacket(type: "chat", data: #"{"message":"x"}"#, client: "")) == nil)
    }

    @Test("сигналы удаления и оформления")
    func deleteAndEditSignals() {
        #expect(ChatSignal(packet: SignalPacket(type: "chat:delete:m-1", data: "m-1", client: "")) == .delete(messageId: "m-1"))
        #expect(ChatSignal(packet: SignalPacket(type: "chat:delete", data: "m-2", client: "")) == .delete(messageId: "m-2"))

        let edit = ChatSignal.edit(messageId: "m", diapason: .weight(WeightRange(id: "d", from: 0, to: 3, state: .underline)))
        let packet = edit.packet(client: "")
        #expect(packet.type == "chat:edit:m")
        #expect(packet.data.contains("\"WEIGHT_TEXT\""))
        #expect(packet.data.contains("\"SKINY\""))
        #expect(ChatSignal(packet: packet) == edit)

        let marker = SignalPacket(type: "chat:edit:m", data: ##"{"messageId":"m","diapason":{"id":"d1","type":"MARKERED_TEXT","from":0,"to":4,"color":"#ffe066"}}"##, client: "")
        #expect(ChatSignal(packet: marker) == .edit(messageId: "m", diapason: .marker(MarkerRange(id: "d1", from: 0, to: 4, color: "#ffe066"))))
    }

    @Test("лента: слияние по id и clientMessageId, сортировка от новых, удалённые не возвращаются")
    func timeline() {
        var timeline = MessageTimeline([
            ChatMessage(id: "a", text: "old", createdAtMilliseconds: 1, username: "u"),
            ChatMessage(id: "local-1", clientMessageId: "local-1", text: "mine", createdAtMilliseconds: 3, username: "me", delivery: .sending),
        ])
        timeline.merge([ChatMessage(id: "server-1", clientMessageId: "local-1", text: "mine", createdAtMilliseconds: 3, username: "me")])
        #expect(timeline.messages.map(\.id) == ["server-1", "a"])
        #expect(timeline.messages.first?.delivery == .sent)

        timeline.merge([ChatMessage(id: "server-1", text: "mine", createdAtMilliseconds: 3, username: "me")])
        #expect(timeline.messages.count == 2)
        #expect(timeline.messages.first?.clientMessageId == "local-1")

        timeline.remove(id: "a")
        timeline.merge([ChatMessage(id: "a", text: "old", createdAtMilliseconds: 1, username: "u")])
        #expect(timeline.messages.map(\.id) == ["server-1"])

        timeline.apply(.marker(MarkerRange(id: "d", from: 0, to: 1, color: "#fff")), to: "server-1")
        timeline.apply(.marker(MarkerRange(id: "d", from: 0, to: 3, color: "#000")), to: "server-1")
        #expect(timeline.messages.first?.markers == [MarkerRange(id: "d", from: 0, to: 3, color: "#000")])
    }

    @Test("события потока уведомлений")
    func notificationEvents() {
        #expect(NotificationStreamEvent.decode(#"{"kind":"heartbeat"}"#) == .heartbeat)
        #expect(NotificationStreamEvent.decode(#"{"kind":"sync","readMessageIds":[]}"#) == .changed(kind: "sync"))
        #expect(NotificationStreamEvent.decode("{}") == nil)
    }
}

@MainActor
@Suite("Отправка итога звонка")
struct CallSummaryPublisherTests {
    @Test("итог звонка: текст веб-формата, callInfo и сигнал chat через временную сессию")
    func publishes() async throws {
        let api = FakeChatAPI(ownerUsername: "@me", messages: ["room": []])
        let rooms = SummaryRoomBox()
        let publisher = CallSummaryPublisher(me: ChatUser(userId: "me", username: "@me"), api: api, rtcUrl: URL(string: "wss://x")!, makeRoom: {
            let room = FakeCallRoom()
            rooms.rooms.append(room)
            return room
        }, now: { Date(timeIntervalSince1970: 2_000) })

        await publisher.publish(CallSummaryReport(isGroup: false, roomId: "room", durationSeconds: 125, startedAt: Date(timeIntervalSince1970: 1_875)))

        let sent = try #require(await api.sent.first)
        #expect(sent.message == "__P2P_CALL_SUMMARY__:125|1875000")
        #expect(sent.callInfo)
        let room = try #require(rooms.rooms.first)
        #expect(room.token == "text-token-room")
        #expect(room.sentPackets.first?.type == "chat")
        #expect(room.isDisconnected)
        #expect(CallSummary(text: sent.message)?.durationSeconds == 125)
        #expect(CallSummary.messageText(isGroup: true, durationSeconds: 0, startedAt: Date(timeIntervalSince1970: 0)) == "GROUP_CALL_SUMMARY:1|1")
    }
}

@MainActor
final class SummaryRoomBox {
    var rooms: [FakeCallRoom] = []
}
