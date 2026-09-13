import ConnectNetworking
import Foundation

/// Уведомление центра уведомлений (`features/notifications/types.ts`).
public struct InboxNotification: Decodable, Sendable, Equatable, Identifiable {
    public enum ChatType: String, Decodable, Sendable {
        case p2p = "P2P"
        case group = "GROUP"
        case room = "ROOM"
        case postFeed = "POST_FEED"
        case roomEvent = "ROOM_EVENT"
        case unknown
    }

    public var id: Int64
    public var messageId: String?
    public var senderUserId: String?
    public var chatId: String?
    public var chatType: ChatType
    public var body: String?
    public var createdAt: Date?
    public var eventStartsAt: Date?
    public var roomName: String?
    public var viewedAt: Date?
    public var messageReadAt: Date?

    public init(id: Int64, messageId: String? = nil, chatId: String? = nil, chatType: ChatType, body: String? = nil, createdAt: Date? = nil, roomName: String? = nil, viewedAt: Date? = nil, messageReadAt: Date? = nil) {
        self.id = id
        self.messageId = messageId
        self.chatId = chatId
        self.chatType = chatType
        self.body = body
        self.createdAt = createdAt
        self.roomName = roomName
        self.viewedAt = viewedAt
        self.messageReadAt = messageReadAt
    }

    enum CodingKeys: String, CodingKey {
        case id, messageId, senderUserId, chatId, chatType, body, createdAt, eventStartsAt, roomName, viewedAt, messageReadAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? container.decode(Int64.self, forKey: .id) {
            id = number
        } else {
            id = Int64(try container.decode(String.self, forKey: .id)) ?? 0
        }
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        senderUserId = try container.decodeIfPresent(String.self, forKey: .senderUserId)
        chatId = try container.decodeIfPresent(String.self, forKey: .chatId)
        chatType = (try? container.decodeIfPresent(ChatType.self, forKey: .chatType)) ?? .unknown
        body = try container.decodeIfPresent(String.self, forKey: .body)
        createdAt = InboxDates.parse(try? container.decodeIfPresent(String.self, forKey: .createdAt))
        eventStartsAt = InboxDates.parse(try? container.decodeIfPresent(String.self, forKey: .eventStartsAt))
        roomName = try container.decodeIfPresent(String.self, forKey: .roomName)
        viewedAt = InboxDates.parse(try? container.decodeIfPresent(String.self, forKey: .viewedAt))
        messageReadAt = InboxDates.parse(try? container.decodeIfPresent(String.self, forKey: .messageReadAt))
    }

    /// Заголовок как в `NotificationItem.tsx`: имя отправителя веб не подставляет.
    public var title: String {
        switch chatType {
        case .roomEvent: "Событие · \((roomName?.isEmpty == false ? roomName : nil) ?? "Комната")"
        case .group: "Сообщение в группе"
        case .p2p: "Личное сообщение"
        default: "Сообщение в канале"
        }
    }

    public var bodyText: String {
        (body?.isEmpty == false ? body : nil) ?? "Вложение"
    }
}

public struct Invitation: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case room = "ROOM"
        case group = "GROUP"
        case contact = "CONTACT"
        case unknown
    }

    public enum Status: String, Decodable, Sendable {
        case pending = "PENDING"
        case accepted = "ACCEPTED"
        case declined = "DECLINED"
        case cancelled = "CANCELLED"
        case expired = "EXPIRED"
        case unknown

        public var title: String {
            switch self {
            case .pending: "Ожидает ответа"
            case .accepted: "Принято"
            case .declined: "Отклонено"
            case .cancelled: "Отменено"
            case .expired: "Истекло"
            case .unknown: ""
            }
        }
    }

    public enum Action: String, Encodable, Sendable {
        case accept = "ACCEPT"
        case decline = "DECLINE"
        case cancel = "CANCEL"
    }

    public var id: String
    public var kind: Kind
    public var targetId: String?
    public var senderUserId: String
    public var recipientUserId: String
    public var senderName: String
    public var recipientName: String
    public var targetName: String
    public var status: Status
    public var createdAt: Date?

    public init(id: String, kind: Kind, targetId: String?, senderUserId: String, recipientUserId: String, senderName: String = "", recipientName: String = "", targetName: String = "", status: Status = .pending, createdAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.targetId = targetId
        self.senderUserId = senderUserId
        self.recipientUserId = recipientUserId
        self.senderName = senderName
        self.recipientName = recipientName
        self.targetName = targetName
        self.status = status
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, type, targetId, senderUserId, recipientUserId, senderName, recipientName, targetName, status, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .type)) ?? .unknown
        targetId = try container.decodeIfPresent(String.self, forKey: .targetId)
        senderUserId = try container.decodeIfPresent(String.self, forKey: .senderUserId) ?? ""
        recipientUserId = try container.decodeIfPresent(String.self, forKey: .recipientUserId) ?? ""
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName) ?? ""
        recipientName = try container.decodeIfPresent(String.self, forKey: .recipientName) ?? ""
        targetName = try container.decodeIfPresent(String.self, forKey: .targetName) ?? ""
        status = (try? container.decodeIfPresent(Status.self, forKey: .status)) ?? .unknown
        createdAt = InboxDates.parse(try? container.decodeIfPresent(String.self, forKey: .createdAt))
    }

    /// Текст карточки `InvitationCenter.tsx`.
    public func title(me: String) -> String {
        guard kind == .contact else { return targetName }
        return recipientUserId == me ? "\(senderName) добавил(а) вас в контакты" : "Вы добавили \(recipientName) в контакты"
    }

    public var subtitle: String {
        switch kind {
        case .room: "Приглашение в комнату"
        case .group: "Приглашение в групповой чат"
        case .contact: "Добавить в ответ?"
        case .unknown: "Приглашение"
        }
    }
}

public struct NewGroup: Encodable, Sendable, Equatable {
    public struct Creator: Encodable, Sendable, Equatable {
        public var userId: String
    }

    public var name: String
    public var creator: Creator
    public var memberUserIds: [String]
    public var meetingsAllowed: Bool

    public init(name: String, creatorUserId: String, memberUserIds: [String], meetingsAllowed: Bool) {
        self.name = name
        creator = Creator(userId: creatorUserId)
        self.memberUserIds = memberUserIds
        self.meetingsAllowed = meetingsAllowed
    }
}

public protocol InboxAPI: Sendable {
    func notifications(before: Int64?, limit: Int) async throws -> [InboxNotification]
    func markViewed(ids: [Int64]) async throws
    func dismiss(ids: [Int64]) async throws
    func dismissAll() async throws -> Int64?
    func invitations(page: Int) async throws -> [Invitation]
    func pendingInvitations() async throws -> Int
    func decide(invitationId: String, action: Invitation.Action) async throws
    func invite(kind: Invitation.Kind, targetId: String, recipientUserId: String) async throws
    func createGroup(_ group: NewGroup) async throws
}

public struct RemoteInboxAPI: InboxAPI {
    private let main: HTTPClient
    private let notifications: HTTPClient

    public init(main: HTTPClient, notifications: HTTPClient) {
        self.main = main
        self.notifications = notifications
    }

    public func notifications(before: Int64?, limit: Int) async throws -> [InboxNotification] {
        let beforeQuery = before.map { "before=\($0)&" } ?? ""
        return try await notifications.getDecoded("/api/notifications?\(beforeQuery)limit=\(limit)")
    }

    public func markViewed(ids: [Int64]) async throws {
        try HTTPClient.requireSuccess(try await notifications.post("/api/notifications/viewed", json: IdsBody(ids: ids)))
    }

    public func dismiss(ids: [Int64]) async throws {
        try HTTPClient.requireSuccess(try await notifications.post("/api/notifications/dismiss", json: IdsBody(ids: ids)))
    }

    public func dismissAll() async throws -> Int64? {
        let response = try await notifications.send(method: "POST", path: "/api/notifications/dismiss-all", body: nil)
        try HTTPClient.requireSuccess(response)
        return (try? JSONDecoder().decode(DismissAllResponse.self, from: response.body))?.dismissedThroughId
    }

    public func invitations(page: Int) async throws -> [Invitation] {
        try await notifications.getDecoded("/api/notifications/invitations?page=\(page)")
    }

    public func pendingInvitations() async throws -> Int {
        try await notifications.getDecoded("/api/notifications/invitations/summary", as: PendingSummary.self).pending ?? 0
    }

    public func decide(invitationId: String, action: Invitation.Action) async throws {
        let id = invitationId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) ?? invitationId
        try HTTPClient.requireSuccess(try await main.post("/api/invitations/\(id)/decision", json: DecisionBody(action: action)))
    }

    public func invite(kind: Invitation.Kind, targetId: String, recipientUserId: String) async throws {
        try HTTPClient.requireSuccess(try await main.post("/api/invitations", json: InviteBody(type: kind, targetId: targetId, recipientUserId: recipientUserId)))
    }

    public func createGroup(_ group: NewGroup) async throws {
        try HTTPClient.requireSuccess(try await main.post("/api/group-room/create", json: group))
    }
}

enum InboxDates {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct IdsBody: Encodable, Sendable {
    let ids: [Int64]
}

private struct DismissAllResponse: Decodable {
    let dismissedThroughId: Int64?
}

private struct PendingSummary: Decodable {
    let pending: Int?
}

private struct DecisionBody: Encodable, Sendable {
    let action: Invitation.Action
}

private struct InviteBody: Encodable, Sendable {
    let type: Invitation.Kind
    let targetId: String
    let recipientUserId: String
}
