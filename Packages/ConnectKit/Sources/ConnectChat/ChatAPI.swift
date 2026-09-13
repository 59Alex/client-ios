import ConnectNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Новое сообщение для `message/create`.
public struct OutgoingMessage: Encodable, Sendable, Equatable {
    public var userId: String
    public var roomId: String
    public var message: String
    public var dateTimeCreateTimestamp: Int64
    public var attachedFiles: [ChatAttachment]

    public init(userId: String, roomId: String, message: String, dateTimeCreateTimestamp: Int64, attachedFiles: [ChatAttachment] = []) {
        self.userId = userId
        self.roomId = roomId
        self.message = message
        self.dateTimeCreateTimestamp = dateTimeCreateTimestamp
        self.attachedFiles = attachedFiles
    }
}

/// Непрочитанное в одном чате: `summary.chats` сервиса уведомлений.
public struct UnreadChat: Decodable, Sendable, Equatable {
    public var chatId: String
    public var chatType: String
    public var unread: Int
    public var firstUnreadMessageId: String?

    public init(chatId: String, chatType: String, unread: Int, firstUnreadMessageId: String? = nil) {
        self.chatId = chatId
        self.chatType = chatType
        self.unread = unread
        self.firstUnreadMessageId = firstUnreadMessageId
    }

    public var key: String { "\(chatType):\(chatId)" }
}

public struct NotificationSummary: Decodable, Sendable, Equatable {
    public var unread: Int
    public var chats: [UnreadChat]

    public init(unread: Int, chats: [UnreadChat]) {
        self.unread = unread
        self.chats = chats
    }
}

/// Событие потока уведомлений: всё, кроме heartbeat, означает «перечитай сводку».
public enum NotificationStreamEvent: Sendable, Equatable {
    case heartbeat
    case changed(kind: String)

    public static func decode(_ data: String) -> NotificationStreamEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let kind = object["kind"] as? String
        else { return nil }
        return kind == "heartbeat" ? .heartbeat : .changed(kind: kind)
    }
}

public protocol ChatAPI: Sendable {
    func rooms(_ kind: ChatKind, page: Int) async throws -> [ChatSummary]
    func snapshot(_ kind: ChatKind, roomId: String) async throws -> ChatSnapshot
    func history(_ kind: ChatKind, roomId: String, page: Int) async throws -> MessagePage
    func send(_ kind: ChatKind, message: OutgoingMessage) async throws -> String
    func delete(messageId: String) async throws
    func textToken(_ kind: ChatKind, userId: String, roomId: String) async throws -> String
    func notificationSummary() async throws -> NotificationSummary
    func markRead(messageIds: [String]) async throws
    func notificationEvents() -> AsyncThrowingStream<NotificationStreamEvent, any Error>
}

public struct RemoteChatAPI: ChatAPI {
    public static let roomPageSize = 20

    private let main: HTTPClient
    private let notifications: HTTPClient
    private let eventStream: any EventStreamTransport

    public init(main: HTTPClient, notifications: HTTPClient, eventStream: any EventStreamTransport) {
        self.main = main
        self.notifications = notifications
        self.eventStream = eventStream
    }

    public func rooms(_ kind: ChatKind, page: Int) async throws -> [ChatSummary] {
        switch kind {
        case .p2p:
            try await main.getDecoded("/api/p2p-room/get-all-by-jwt-pageable?page=\(page)", as: [P2PRoomDTO].self).map(\.summary)
        case .group:
            try await main.getDecoded("/api/group-room/get-all-by-jwt-pageable?page=\(page)", as: [GroupRoomDTO].self).map(\.summary)
        }
    }

    public func snapshot(_ kind: ChatKind, roomId: String) async throws -> ChatSnapshot {
        try await main.getDecoded("/api/\(kind.pathPrefix)/get/\(Self.path(roomId))")
    }

    public func history(_ kind: ChatKind, roomId: String, page: Int) async throws -> MessagePage {
        try await main.getDecoded("/api/\(kind.pathPrefix)/message/get-for-room/\(Self.path(roomId))?page=\(page)")
    }

    public func send(_ kind: ChatKind, message: OutgoingMessage) async throws -> String {
        let response = try await main.post("/api/\(kind.pathPrefix)/message/create", json: message)
        try HTTPClient.requireSuccess(response)
        // Сервис отдаёт идентификатор строкой или объектом `{id}`.
        if let object = try? JSONDecoder().decode(IdResponse.self, from: response.body) { return object.id }
        if let string = try? JSONDecoder().decode(String.self, from: response.body) { return string }
        let raw = String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        guard !raw.isEmpty else { throw APIError.decoding("пустой идентификатор сообщения") }
        return raw
    }

    public func delete(messageId: String) async throws {
        try HTTPClient.requireSuccess(try await main.send(method: "POST", path: "/api/chat-message/delete?messageId=\(Self.query(messageId))", body: nil))
    }

    public func textToken(_ kind: ChatKind, userId: String, roomId: String) async throws -> String {
        try await main.postDecoded("/api/\(kind.pathPrefix)/get-text-token", json: TokenRequest(userId: userId, roomId: roomId), as: TokenResponse.self)
            .openviduConnectionUri
    }

    public func notificationSummary() async throws -> NotificationSummary {
        try await notifications.getDecoded("/api/notifications/summary")
    }

    public func markRead(messageIds: [String]) async throws {
        try HTTPClient.requireSuccess(try await notifications.post("/api/notifications/messages/read", json: ReadRequest(messageIds: messageIds)))
    }

    public func notificationEvents() -> AsyncThrowingStream<NotificationStreamEvent, any Error> {
        let client = notifications
        let transport = eventStream
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let token = await client.accessToken() else { throw APIError.unauthorized }
                    // Поток уведомлений авторизуется заголовком, а не параметром.
                    var request = URLRequest(url: HTTPClient.join(client.baseURL, "/api/notifications/stream"))
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    for try await event in transport.events(for: request) {
                        if let decoded = NotificationStreamEvent.decode(event.data) {
                            continuation.yield(decoded)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func path(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    static func query(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? value
    }
}

extension ChatKind {
    var pathPrefix: String {
        switch self {
        case .p2p: "p2p-room"
        case .group: "group-room"
        }
    }
}

private struct IdResponse: Decodable {
    let id: String
}

private struct TokenRequest: Encodable, Sendable {
    let userId: String
    let roomId: String
}

private struct TokenResponse: Decodable {
    let openviduConnectionUri: String
}

private struct ReadRequest: Encodable, Sendable {
    let messageIds: [String]
}
