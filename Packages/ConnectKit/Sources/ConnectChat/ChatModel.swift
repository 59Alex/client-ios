import ConnectCalls
import ConnectCore
import ConnectFiles
import Foundation
import Observation

public struct ChatUser: Sendable, Equatable {
    public var userId: String
    public var username: String

    public init(userId: String, username: String) {
        self.userId = userId
        self.username = username
    }
}

/// Открытый чат: снимок, догрузка истории, отправка, удаление и реалтайм через текстовую
/// комнату LiveKit (`Chat.tsx`, `TextSessionHolder.tsx`).
@MainActor
@Observable
public final class ChatModel {
    public enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// Пауза перед переподключением текстовой сессии, как у веб-клиента.
    public static let reconnectDelay: Duration = .seconds(5)

    public let kind: ChatKind
    public let roomId: String
    public private(set) var title: String
    public private(set) var state: State = .loading
    public private(set) var timeline = MessageTimeline()
    public private(set) var hasMore = false
    public private(set) var isLoadingMore = false
    public private(set) var isConnected = false
    public private(set) var isPartnerBanned = false
    public private(set) var members: [Contact] = []
    /// Собеседник личного чата: для приветственного стикера.
    public private(set) var partnerUserId: String?
    /// Граница «Новые сообщения», зафиксированная при открытии.
    public private(set) var firstUnreadMessageId: String?
    public var draft = ""
    public private(set) var pendingAttachments: [PendingAttachment] = []

    private let me: ChatUser
    private let api: any ChatAPI
    private let unread: UnreadModel?
    private let rtcUrl: URL
    private let makeRoom: @MainActor () -> any SignalRoom
    private let files: (any FileAPI)?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var nextPage = 1
    private var room: (any SignalRoom)?

    public init(
        kind: ChatKind,
        roomId: String,
        title: String,
        me: ChatUser,
        api: any ChatAPI,
        unread: UnreadModel?,
        rtcUrl: URL,
        makeRoom: @escaping @MainActor () -> any SignalRoom,
        files: (any FileAPI)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.kind = kind
        self.roomId = roomId
        self.title = title
        self.me = me
        self.api = api
        self.unread = unread
        self.rtcUrl = rtcUrl
        self.makeRoom = makeRoom
        self.files = files
        self.now = now
        self.sleep = sleep
    }

    public var messages: [ChatMessage] { timeline.messages }

    public var canSend: Bool {
        guard !isPartnerBanned, !pendingAttachments.contains(where: { $0.state == .uploading }) else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !uploadedAttachments.isEmpty
    }

    public var canAttach: Bool { files != nil && !isPartnerBanned }

    private var uploadedAttachments: [ChatAttachment] {
        pendingAttachments.compactMap {
            if case let .uploaded(attachment) = $0.state { return attachment }
            return nil
        }
    }

    public func isOwn(_ message: ChatMessage) -> Bool {
        message.isOwn(username: me.username)
    }

    // MARK: - Загрузка

    public func load() async {
        if firstUnreadMessageId == nil {
            firstUnreadMessageId = unread?.firstUnreadMessageId(kind: kind, roomId: roomId)
        }
        do {
            try await resync()
            state = .loaded
            await loadUntilFirstUnread()
        } catch is CancellationError {
            return
        } catch {
            if state != .loaded {
                state = .failed("Не удалось загрузить сообщения")
            }
        }
    }

    public func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.history(kind, roomId: roomId, page: nextPage)
            timeline.merge(page.content)
            hasMore = page.hasMore
            nextPage = page.number + 1
        } catch {
            // Повтор при следующей прокрутке к началу.
        }
    }

    private func resync() async throws {
        let snapshot = try await api.snapshot(kind, roomId: roomId)
        timeline.merge(snapshot.messages.content)
        if nextPage <= 1 {
            hasMore = snapshot.messages.hasMore
            nextPage = snapshot.messages.number + 1
        }
        isPartnerBanned = snapshot.partnerBanned || snapshot.banned
        members = snapshot.members
        partnerUserId = snapshot.partnerUserId
        if let name = snapshot.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            title = name
        }
    }

    /// Граница непрочитанного может быть глубже первой страницы: догружаем до неё.
    private func loadUntilFirstUnread() async {
        guard let target = firstUnreadMessageId else { return }
        var attempts = 0
        while !messages.contains(where: { $0.id == target }) {
            guard hasMore, attempts < 20 else {
                firstUnreadMessageId = nil
                return
            }
            attempts += 1
            await loadMore()
        }
    }

    // MARK: - Текстовая сессия

    /// Держит текстовую сессию, пока задача не отменена; после переподключения перечитывает снимок.
    public func runRealtime() async {
        while !Task.isCancelled {
            let room = makeRoom()
            self.room = room
            do {
                let token = try await api.textToken(kind, userId: me.userId, roomId: roomId)
                try await room.connect(url: rtcUrl, token: token)
                isConnected = true
                try? await resync()
                for await event in room.events {
                    await handle(event)
                    if case .disconnected = event { break }
                }
            } catch {
                // Переподключение ниже.
            }
            isConnected = false
            self.room = nil
            await room.disconnect()
            do {
                try await sleep(Self.reconnectDelay)
            } catch {
                return
            }
        }
    }

    public func stopRealtime() async {
        let room = room
        self.room = nil
        isConnected = false
        await room?.disconnect()
    }

    private var clientData: String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(["clientData": me.username]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func handle(_ event: CallRoomEvent) async {
        switch event {
        case let .data(topic, payload):
            guard topic == CallProtocol.signalTopic, let packet = SignalPacket.decode(payload), let signal = ChatSignal(packet: packet) else { return }
            switch signal {
            case let .message(message):
                timeline.merge([message])
            case let .delete(messageId):
                timeline.remove(id: messageId)
            case let .edit(messageId, diapason):
                timeline.apply(diapason, to: messageId)
            }
        case .reconnected:
            isConnected = true
            try? await resync()
        case .reconnecting:
            isConnected = false
        default:
            break
        }
    }

    private func signal(_ signal: ChatSignal) async {
        guard let room, isConnected else { return }
        try? await room.send(signal.packet(client: clientData).encoded(), topic: CallProtocol.signalTopic)
    }

    // MARK: - Действия

    // MARK: - Вложения

    /// Загружает файл в connect-s3 (корзина `file-chat`, ключ — комната) до отправки сообщения.
    public func attach(data: Data, filename: String, mimeType: String) async {
        guard let files else { return }
        let pending = PendingAttachment(filename: filename)
        pendingAttachments.append(pending)
        do {
            let uploaded = try await files.upload(data: data, filename: filename, mimeType: mimeType, bucket: .chat, key: roomId, userId: me.userId, username: me.username)
            let attachment = ChatAttachment(urlS3: uploaded.urlS3, previewUrlS3: uploaded.previewUrlS3, name: uploaded.name, extension: uploaded.extension)
            guard pendingAttachments.contains(where: { $0.id == pending.id }) else {
                // Файл убрали, пока он загружался.
                try? await files.delete(urls: [uploaded.urlS3])
                return
            }
            setAttachmentState(pending.id, .uploaded(attachment))
        } catch {
            setAttachmentState(pending.id, .failed)
        }
    }

    /// Приветствие в пустом личном чате: картинка каждый раз загружается в свою галерею
    /// и уходит сообщением без текста (`ChatGreeting.tsx`).
    public func sendGreeting(data: Data, filename: String, mimeType: String) async -> Bool {
        guard let files, kind == .p2p, messages.isEmpty, !isPartnerBanned else { return false }
        do {
            let uploaded = try await files.upload(data: data, filename: filename, mimeType: mimeType, bucket: .userGallery, key: me.userId, userId: me.userId, username: me.username)
            let attachment = ChatAttachment(urlS3: uploaded.urlS3, name: uploaded.name, extension: uploaded.extension)
            pendingAttachments = [PendingAttachment(filename: filename, state: .uploaded(attachment))]
            draft = ""
            await send()
            return messages.first?.delivery == .sent
        } catch {
            return false
        }
    }

    public func removeAttachment(_ id: UUID) async {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = pendingAttachments.remove(at: index)
        if case let .uploaded(attachment) = removed.state {
            try? await files?.delete(urls: [attachment.urlS3])
        }
    }

    private func setAttachmentState(_ id: UUID, _ state: PendingAttachment.State) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        pendingAttachments[index].state = state
    }

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let attachments = uploadedAttachments
        draft = ""
        pendingAttachments.removeAll()
        let timestamp = Int64(now().timeIntervalSince1970 * 1000)
        let localId = "local-\(kind.localIdPrefix)-\(timestamp)-\(me.userId)"
        let message = ChatMessage(
            id: localId,
            clientMessageId: localId,
            text: text,
            createdAtMilliseconds: timestamp,
            authorId: me.userId,
            username: me.username,
            attachments: attachments,
            delivery: .sending
        )
        timeline.merge([message])
        await deliver(message)
    }

    public func retry(_ messageId: String) async {
        guard let message = messages.first(where: { $0.id == messageId }), message.delivery == .failed else { return }
        timeline.update(id: messageId) { $0.delivery = .sending }
        var pending = message
        pending.delivery = .sending
        await deliver(pending)
    }

    public func discardFailed(_ messageId: String) {
        guard messages.first(where: { $0.id == messageId })?.delivery == .failed else { return }
        timeline.remove(id: messageId)
    }

    private func deliver(_ message: ChatMessage) async {
        let outgoing = OutgoingMessage(
            userId: me.userId,
            roomId: roomId,
            message: message.text,
            dateTimeCreateTimestamp: message.createdAtMilliseconds,
            attachedFiles: message.attachments
        )
        do {
            let createdId = try await api.send(kind, message: outgoing)
            var persisted = message
            persisted.id = createdId
            persisted.delivery = .sent
            timeline.merge([persisted])
            await signal(.message(persisted))
        } catch {
            timeline.update(id: message.id) { $0.delivery = .failed }
        }
    }

    public func delete(_ messageId: String) async -> Bool {
        do {
            try await api.delete(messageId: messageId)
            timeline.remove(id: messageId)
            await signal(.delete(messageId: messageId))
            return true
        } catch {
            return false
        }
    }

    /// Сообщения собеседников, показанные на экране, отмечаются прочитанными.
    public func markVisible(_ messageIds: [String]) {
        let others = messages.filter { messageIds.contains($0.id) && !isOwn($0) && $0.callSummary == nil }.map(\.id)
        unread?.markRead(others)
    }
}

/// Файл, прикреплённый к ещё не отправленному сообщению.
public struct PendingAttachment: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case uploading
        case uploaded(ChatAttachment)
        case failed
    }

    public let id = UUID()
    public var filename: String
    public var state: State = .uploading

    public init(filename: String, state: State = .uploading) {
        self.filename = filename
        self.state = state
    }
}
