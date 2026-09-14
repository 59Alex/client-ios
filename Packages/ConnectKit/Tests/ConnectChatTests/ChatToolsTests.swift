import ConnectCalls
import ConnectNetworking
import ConnectChat
import ConnectTestSupport
import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ConnectChat

@MainActor
@Suite("Выделение, оформление и эмодзи")
struct ChatToolsTests {
    private func chat(_ api: FakeChatAPI) -> ChatModel {
        ChatModel(kind: .p2p, roomId: "room", title: "Иван", me: ChatUser(userId: "me", username: "me"), api: api, unread: nil, rtcUrl: URL(string: "wss://x")!, makeRoom: { FakeCallRoom() })
    }

    private func message(_ id: String, _ text: String, author: String) -> ChatMessage {
        ChatMessage(id: id, text: text, createdAtMilliseconds: Int64(id.hashValue & 0xFFFF), authorId: author, username: author)
    }

    @Test("выделение выходит само, удалять можно только свои, неудачные остаются выбранными")
    func selectionDelete() async {
        let api = FakeChatAPI(messages: ["room": [message("m1", "раз", author: "me"), message("m2", "два", author: "me"), message("m3", "чужое", author: "ivan")]])
        let model = chat(api)
        await model.load()

        model.toggleSelection("m1")
        model.toggleSelection("m3")
        #expect(model.isSelecting)
        #expect(!model.canDeleteSelection)
        model.toggleSelection("m3")
        model.toggleSelection("m2")
        #expect(model.canDeleteSelection)

        await api.setFailDeleteIds(["m2"])
        let failures = await model.deleteSelected()
        #expect(failures == 1)
        #expect(model.selectedIds == ["m2"])
        #expect(!model.messages.contains { $0.id == "m1" })
        #expect(model.messages.contains { $0.id == "m2" })

        model.toggleSelection("m2")
        #expect(!model.isSelecting)
    }

    @Test("оформление: весь текст выбранных в UTF-16, диапазон — только для одного сообщения, id с сервера")
    func formatting() async throws {
        let api = FakeChatAPI(messages: ["room": [message("m1", "Привет 👋", author: "me"), message("m2", "ок", author: "ivan")]])
        let model = chat(api)
        await model.load()

        model.toggleSelection("m1")
        model.toggleSelection("m2")
        #expect(await model.format(.bold, range: 0...2))
        let sent = await api.diapasons
        #expect(sent.count == 2)
        #expect(sent.first { $0.messageId == "m1" }?.diapason == .weight(WeightRange(id: nil, from: 0, to: 8, state: .bold)))
        let m1 = try #require(model.messages.first { $0.id == "m1" })
        #expect(m1.weights.first?.id != nil)

        model.clearSelection()
        model.toggleSelection("m2")
        #expect(await model.format(.marker(color: ChatModel.TextStyle.markerColor), range: 1...5))
        #expect(await api.diapasons.last?.diapason == .marker(MarkerRange(id: nil, from: 1, to: 1, color: "#ffe066")))
    }

    @Test("тело диапазона: без id, жирный — state, маркер — color; ответ строкой")
    func remoteDiapason() async throws {
        let transport = StubTransport()
        transport.on("/api/chat-message/m 1/text-diapasons", json: #""d-7""#)
        let client = HTTPClient(baseURL: URL(string: "https://main.example")!, transport: transport)
        let api = RemoteChatAPI(main: client, notifications: client, eventStream: StubEventStream())
        let id = try await api.addDiapason(messageId: "m 1", diapason: .weight(WeightRange(id: nil, from: 0, to: 3, state: .bold)))
        #expect(id == "d-7")
        let body = String(decoding: try #require(transport.requests.last?.httpBody), as: UTF8.self)
        #expect(body.contains(#""type":"WEIGHT_TEXT""#))
        #expect(body.contains(#""state":"BOLD""#))
        #expect(!body.contains("color"))
        #expect(!body.contains("\"id\""))
    }

    @Test("эмодзи: категория, поиск по подписи, ключам и названию категории")
    func emoji() throws {
        let love = try #require(EmojiCatalog.categories.first { $0.id == "love" })
        let loveSymbols = EmojiCatalog.filter(query: "", category: love).map(\.symbol)
        #expect(loveSymbols.contains("❤️"))
        #expect(!loveSymbols.contains("😡"))
        #expect(EmojiCatalog.filter(query: "пицца", category: nil).map(\.symbol) == ["🍕"])
        #expect(EmojiCatalog.filter(query: "злые", category: nil).contains { $0.symbol == "🤬" })
        #expect(EmojiCatalog.entries.count == 83)
        #expect(EmojiCatalog.categories.count == 9)
    }
}

private struct StubEventStream: EventStreamTransport {
    func events(for request: URLRequest) -> AsyncThrowingStream<ServerSentEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
