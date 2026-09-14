import ConnectCalls
import ConnectFiles
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

@MainActor
@Suite("Прогресс загрузки вложений")
struct UploadProgressTests {
    @Test("проценты по fileId, не больше 99% до ответа, не откатываются, после загрузки 100%")
    func progress() async throws {
        let files = FakeFileAPI()
        await files.setHoldUploads(true)
        let chat = ChatModel(kind: .p2p, roomId: "room", title: "Иван", me: ChatUser(userId: "me", username: "me"), api: FakeChatAPI(messages: ["room": []]), unread: nil, rtcUrl: URL(string: "wss://x")!, makeRoom: { FakeCallRoom() }, files: files)

        let upload = Task { await chat.attach(data: Data("pdf".utf8), filename: "a.pdf", mimeType: "application/pdf") }
        for _ in 0..<200 {
            let subscribed = await files.hasProgressSubscriber()
            let started = await !files.uploadFileIds.isEmpty
            if subscribed && started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = try #require(chat.pendingAttachments.first)
        #expect(await files.uploadFileIds == [pending.fileId])
        #expect(pending.progress == nil)

        await files.pushProgress(UploadProgress(fileId: "other", progressPercent: 50))
        await files.pushProgress(UploadProgress(fileId: pending.fileId, progressPercent: 40))
        for _ in 0..<200 where chat.pendingAttachments.first?.progress == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(chat.pendingAttachments.first?.progress == 0.4)

        chat.applyProgress(UploadProgress(fileId: pending.fileId, progressPercent: 30))
        #expect(chat.pendingAttachments.first?.progress == 0.4)
        chat.applyProgress(UploadProgress(fileId: pending.fileId, progressPercent: 100))
        #expect(chat.pendingAttachments.first?.progress == 0.99)

        await files.finishUpload(pending.fileId)
        await upload.value
        #expect(chat.pendingAttachments.first?.progress == 1)
        #expect(chat.canSend)
    }

    @Test("кадр прогресса разбирается, мусор отбрасывается")
    func remoteStream() async throws {
        #expect(UploadProgress.decode(#"{"userId":"me","fileId":"f1","progressPercent":12.5,"processingStatus":"UPLOADING"}"#) == UploadProgress(fileId: "f1", progressPercent: 12.5, processingStatus: "UPLOADING"))
        #expect(UploadProgress.decode("oops") == nil)
    }
}

@MainActor
@Suite("Голосовые сообщения")
struct VoiceMessageTests {
    @Test("имя как на вебе, распознаются m4a и mp4")
    func naming() {
        let date = Date(timeIntervalSince1970: 1_757_844_000.123)
        let filename = ChatModel.voiceFilename(at: date)
        #expect(filename.hasPrefix("voice-message-2025-09-14T10-00-00-123Z"))
        #expect(filename.hasSuffix(".m4a"))
        #expect(ChatAttachment(urlS3: "a", name: "voice-message-x", extension: ".m4a").kind == .voiceMessage)
        #expect(ChatAttachment(urlS3: "a", name: "voice-message-x", extension: ".webm").kind == .voiceMessage)
        #expect(ChatAttachment(urlS3: "a", name: "voice-message-x", extension: ".mp4").kind == .voiceMessage)
        #expect(ChatAttachment(urlS3: "a", name: "song", extension: ".m4a").kind == .audio)
        #expect(ChatAttachment(urlS3: "a", name: "clip", extension: ".mp4").kind == .video)
    }

    @Test("голосовое уходит сразу одним вложением и не трогает черновик")
    func send() async throws {
        let api = FakeChatAPI(messages: ["room": []])
        let files = FakeFileAPI()
        let chat = ChatModel(kind: .p2p, roomId: "room", title: "Иван", me: ChatUser(userId: "me", username: "me"), api: api, unread: nil, rtcUrl: URL(string: "wss://x")!, makeRoom: { FakeCallRoom() }, files: files)
        await chat.load()
        chat.draft = "недописанный текст"

        #expect(await chat.sendVoiceMessage(data: Data("aac".utf8)))

        let sent = try #require(await api.sent.first)
        #expect(sent.message.isEmpty)
        #expect(sent.attachedFiles.count == 1)
        #expect(sent.attachedFiles.first?.kind == .voiceMessage)
        #expect(sent.attachedFiles.first?.extension == ".m4a")
        #expect(chat.draft == "недописанный текст")
        #expect(chat.messages.first?.delivery == .sent)
    }
}
