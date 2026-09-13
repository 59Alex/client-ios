import ConnectChat
import Foundation

/// API чатов в памяти для тестов и офлайн-стаба приложения.
public actor FakeChatAPI: ChatAPI {
    public var roomsByKind: [ChatKind: [ChatSummary]] = [:]
    public var messagesByRoom: [String: [ChatMessage]] = [:]
    public var pageSize = 20
    public var summary = NotificationSummary(unread: 0, chats: [])
    public var failSend = false
    public private(set) var sent: [OutgoingMessage] = []
    public private(set) var deleted: [String] = []
    public private(set) var readBatches: [[String]] = []
    private var nextId = 0
    private let ownerUsername: String
    private var continuations: [AsyncThrowingStream<NotificationStreamEvent, any Error>.Continuation] = []

    public init(
        ownerUsername: String = "me",
        rooms: [ChatKind: [ChatSummary]] = [:],
        messages: [String: [ChatMessage]] = [:],
        summary: NotificationSummary = NotificationSummary(unread: 0, chats: [])
    ) {
        self.ownerUsername = ownerUsername
        roomsByKind = rooms
        messagesByRoom = messages
        self.summary = summary
    }

    public func setRooms(_ rooms: [ChatSummary], kind: ChatKind) { roomsByKind[kind] = rooms }
    public func setMessages(_ messages: [ChatMessage], roomId: String) { messagesByRoom[roomId] = messages }
    public func setSummary(_ value: NotificationSummary) { summary = value }
    public func setFailSend(_ value: Bool) { failSend = value }
    public func setPageSize(_ value: Int) { pageSize = value }

    public func rooms(_ kind: ChatKind, page: Int) async throws -> [ChatSummary] {
        let all = roomsByKind[kind] ?? []
        let start = page * 20
        guard start < all.count else { return [] }
        return Array(all[start..<min(all.count, start + 20)])
    }

    public func snapshot(_ kind: ChatKind, roomId: String) async throws -> ChatSnapshot {
        ChatSnapshot(id: roomId, messages: page(roomId: roomId, number: 0))
    }

    public func history(_ kind: ChatKind, roomId: String, page number: Int) async throws -> MessagePage {
        page(roomId: roomId, number: number)
    }

    public func send(_ kind: ChatKind, message: OutgoingMessage) async throws -> String {
        if failSend { throw URLError(.notConnectedToInternet) }
        sent.append(message)
        nextId += 1
        let id = String(format: "00000000-0000-4000-9000-%012d", nextId)
        let stored = ChatMessage(id: id, text: message.message, createdAtMilliseconds: message.dateTimeCreateTimestamp, authorId: message.userId, username: ownerUsername, attachments: message.attachedFiles)
        messagesByRoom[message.roomId, default: []].append(stored)
        return id
    }

    public func delete(messageId: String) async throws {
        deleted.append(messageId)
        for key in messagesByRoom.keys {
            messagesByRoom[key]?.removeAll { $0.id == messageId }
        }
    }

    public func textToken(_ kind: ChatKind, userId: String, roomId: String) async throws -> String {
        "text-token-\(roomId)"
    }

    public func notificationSummary() async throws -> NotificationSummary {
        summary
    }

    public func markRead(messageIds: [String]) async throws {
        readBatches.append(messageIds)
    }

    public nonisolated func notificationEvents() -> AsyncThrowingStream<NotificationStreamEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<NotificationStreamEvent, any Error>.makeStream()
        Task { await self.register(continuation) }
        return stream
    }

    public func pushNotificationEvent(_ event: NotificationStreamEvent) {
        continuations.forEach { $0.yield(event) }
    }

    private func register(_ continuation: AsyncThrowingStream<NotificationStreamEvent, any Error>.Continuation) {
        continuations.append(continuation)
    }

    private func page(roomId: String, number: Int) -> MessagePage {
        let ordered = (messagesByRoom[roomId] ?? []).sorted { $0.createdAtMilliseconds > $1.createdAtMilliseconds }
        let start = number * pageSize
        let slice = start < ordered.count ? Array(ordered[start..<min(ordered.count, start + pageSize)]) : []
        return MessagePage(content: slice, number: number, last: start + pageSize >= ordered.count, totalElements: ordered.count)
    }
}
