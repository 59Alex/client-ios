import ConnectChat
import ConnectCore
import ConnectNetworking
import Foundation

public enum MemberRole: String, Decodable, Sendable, Equatable {
    case admin = "ADMIN"
    case moderator = "MODERATOR"
    case subscriber = "SUBSCRIBER"
    case banned = "BANNED"

    public var canManage: Bool { self == .admin || self == .moderator }
}

/// Карточка комнаты в списке (`get-all-cards-by-jwt`).
public struct RoomCard: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var avatarKey: String?
    public var textChannelIds: [String]

    public init(id: String, name: String, avatarKey: String? = nil, textChannelIds: [String] = []) {
        self.id = id
        self.name = name
        self.avatarKey = avatarKey
        self.textChannelIds = textChannelIds
    }

    enum CodingKeys: String, CodingKey { case id, name, avatarUrl, textChannelIds }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        avatarKey = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
        textChannelIds = (try? container.decodeIfPresent([String].self, forKey: .textChannelIds)) ?? []
    }
}

public struct RoomChannel: Decodable, Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case text = "TEXT"
        case voice = "VOICE"
    }

    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, name, type }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = (try? container.decode(Kind.self, forKey: .type)) ?? .text
    }
}

/// Комната: каналы в порядке сервиса, участники (`GET /api/room/get/{id}`).
public struct RoomDetails: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var channels: [RoomChannel]
    public var members: [Contact]

    public init(id: String, name: String, channels: [RoomChannel], members: [Contact] = []) {
        self.id = id
        self.name = name
        self.channels = channels
        self.members = members
    }

    enum CodingKeys: String, CodingKey { case id, name, channels, roomMembers }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        channels = (try? container.decodeIfPresent([RoomChannel].self, forKey: .channels)) ?? []
        members = (try? container.decodeIfPresent([Contact].self, forKey: .roomMembers)) ?? []
    }
}

/// Событие календаря комнаты.
public struct RoomEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var startsAt: Date
    public var notificationTimes: [Date]

    public init(id: String, title: String, description: String = "", startsAt: Date, notificationTimes: [Date] = []) {
        self.id = id
        self.title = title
        self.description = description
        self.startsAt = startsAt
        self.notificationTimes = notificationTimes
    }

    enum CodingKeys: String, CodingKey { case id, title, description, startsAt, notificationTimes }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        guard let starts = RoomDates.parse(try container.decode(String.self, forKey: .startsAt)) else {
            throw DecodingError.dataCorruptedError(forKey: .startsAt, in: container, debugDescription: "неверная дата")
        }
        startsAt = starts
        notificationTimes = ((try? container.decodeIfPresent([String].self, forKey: .notificationTimes)) ?? []).compactMap(RoomDates.parse)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(RoomDates.format(startsAt), forKey: .startsAt)
        try container.encode(notificationTimes.map(RoomDates.format), forKey: .notificationTimes)
    }
}

/// Канал-лента в списке подписок.
public struct PostFeedCard: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var lastPost: String?
    public var lastPostAtMilliseconds: Int64?
    public var avatarKey: String?

    public init(id: String, name: String, lastPost: String? = nil, lastPostAtMilliseconds: Int64? = nil) {
        self.id = id
        self.name = name
        self.lastPost = lastPost
        self.lastPostAtMilliseconds = lastPostAtMilliseconds
    }

    enum CodingKeys: String, CodingKey { case postFeedId, name, lastPostMessage, lastPostDateTimeTimestamp, avatarUrl }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .postFeedId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        lastPost = try container.decodeIfPresent(String.self, forKey: .lastPostMessage)
        lastPostAtMilliseconds = (try? container.decodeIfPresent(Int64.self, forKey: .lastPostDateTimeTimestamp))
            ?? (try? container.decodeIfPresent(Double.self, forKey: .lastPostDateTimeTimestamp)).map { Int64($0) }
        avatarKey = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
    }
}

public struct FeedPost: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var createdAtMilliseconds: Int64
    public var userId: String?
    public var username: String
    public var attachments: [ChatAttachment]
    public var uniqueViewsCount: Int?
    public var commentsCount: Int?

    public init(id: String, text: String, createdAtMilliseconds: Int64, userId: String? = nil, username: String, attachments: [ChatAttachment] = [], uniqueViewsCount: Int? = nil, commentsCount: Int? = nil) {
        self.uniqueViewsCount = uniqueViewsCount
        self.commentsCount = commentsCount
        self.id = id
        self.text = text
        self.createdAtMilliseconds = createdAtMilliseconds
        self.userId = userId
        self.username = username
        self.attachments = attachments
    }

    public var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(createdAtMilliseconds) / 1000) }

    enum CodingKeys: String, CodingKey { case id, message, dateTimeCreateTimestamp, userId, username, attachedFiles, uniqueViewsCount, commentsCount }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        createdAtMilliseconds = (try? container.decodeIfPresent(Int64.self, forKey: .dateTimeCreateTimestamp))
            ?? (try? container.decodeIfPresent(Double.self, forKey: .dateTimeCreateTimestamp)).map { Int64($0) }
            ?? 0
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        attachments = (try? container.decodeIfPresent([ChatAttachment].self, forKey: .attachedFiles)) ?? []
        uniqueViewsCount = try? container.decodeIfPresent(Int.self, forKey: .uniqueViewsCount)
        commentsCount = try? container.decodeIfPresent(Int.self, forKey: .commentsCount)
    }
}

/// Права модератора канала-ленты.
public struct FeedPrivileges: Codable, Sendable, Equatable {
    public var canCreatePosts: Bool
    public var canBanUsers: Bool
    public var canAssignModerators: Bool
    public var canUnbanUsers: Bool
    public var canDeletePosts: Bool
    public var canManageComments: Bool

    public init(canCreatePosts: Bool = false, canBanUsers: Bool = false, canAssignModerators: Bool = false, canUnbanUsers: Bool = false, canDeletePosts: Bool = false, canManageComments: Bool = false) {
        self.canCreatePosts = canCreatePosts
        self.canBanUsers = canBanUsers
        self.canAssignModerators = canAssignModerators
        self.canUnbanUsers = canUnbanUsers
        self.canDeletePosts = canDeletePosts
        self.canManageComments = canManageComments
    }

    enum CodingKeys: String, CodingKey { case canCreatePosts, canBanUsers, canAssignModerators, canUnbanUsers, canDeletePosts, canManageComments }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canCreatePosts = try container.decodeIfPresent(Bool.self, forKey: .canCreatePosts) ?? false
        canBanUsers = try container.decodeIfPresent(Bool.self, forKey: .canBanUsers) ?? false
        canAssignModerators = try container.decodeIfPresent(Bool.self, forKey: .canAssignModerators) ?? false
        canUnbanUsers = try container.decodeIfPresent(Bool.self, forKey: .canUnbanUsers) ?? false
        canDeletePosts = try container.decodeIfPresent(Bool.self, forKey: .canDeletePosts) ?? false
        canManageComments = try container.decodeIfPresent(Bool.self, forKey: .canManageComments) ?? false
    }
}

public struct FeedMembers: Decodable, Sendable, Equatable {
    public struct Member: Decodable, Sendable, Equatable, Identifiable {
        public var userId: String
        public var username: String
        public var id: String { userId }

        public init(userId: String, username: String) {
            self.userId = userId
            self.username = username
        }
    }

    public var admin: Member?
    public var moderators: [Member]
    public var subscribers: [Member]
    public var bannedUsers: [Member]

    public init(admin: Member? = nil, moderators: [Member] = [], subscribers: [Member] = [], bannedUsers: [Member] = []) {
        self.admin = admin
        self.moderators = moderators
        self.subscribers = subscribers
        self.bannedUsers = bannedUsers
    }

    enum CodingKeys: String, CodingKey { case admin, moderators, subscribers, bannedUsers }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        admin = try? container.decodeIfPresent(Member.self, forKey: .admin)
        moderators = (try? container.decodeIfPresent([Member].self, forKey: .moderators)) ?? []
        subscribers = (try? container.decodeIfPresent([Member].self, forKey: .subscribers)) ?? []
        bannedUsers = (try? container.decodeIfPresent([Member].self, forKey: .bannedUsers)) ?? []
    }
}

public protocol RoomsAPI: Sendable {
    func rooms() async throws -> [RoomCard]
    func room(id: String) async throws -> RoomDetails
    func role(roomId: String) async throws -> MemberRole?
    func createRoom(name: String, creatorUserId: String) async throws
    func createChannel(roomId: String, name: String, kind: RoomChannel.Kind, creatorUserId: String) async throws -> RoomChannel
    func joinRoom(code: String, userId: String) async throws
    func events(roomId: String, from: Date, to: Date) async throws -> [RoomEvent]
    func createEvent(roomId: String, event: RoomEvent) async throws

    func feeds(userId: String) async throws -> [PostFeedCard]
    func createFeed(name: String, userId: String) async throws
    func deleteFeed(id: String) async throws
    /// `nil` — пользователь не подписан.
    func feedRole(feedId: String) async throws -> MemberRole?
    func feedPrivileges(feedId: String, userId: String) async throws -> FeedPrivileges
    func posts(feedId: String, page: Int) async throws -> [FeedPost]
    func createPost(feedId: String, userId: String, text: String, timestamp: Int64, attachments: [ChatAttachment]) async throws -> FeedPost
    func setSubscribed(_ subscribed: Bool, feedId: String, userId: String) async throws
    func feedMembers(feedId: String) async throws -> FeedMembers
    /// Модератор с правами (`PUT /api/post-feed/moderator/add`).
    func addModerator(feedId: String, userId: String, privileges: FeedPrivileges) async throws
    func removeModerator(feedId: String, userId: String) async throws
    func setBanned(_ banned: Bool, feedId: String, userId: String) async throws
    /// Отметка просмотра поста: `POST /api/post-feed/post/{id}/view`.
    func markPostViewed(postId: String) async throws
    func comments(postId: String) async throws -> [PostComment]
    func createComment(postId: String, userId: String, text: String, timestamp: Int64) async throws -> PostComment
    func deleteComment(id: String) async throws
    /// Подписка по ссылке-приглашению или добавление контакта: `PUT /api/post-feed/subscriber/add`.
    func addSubscriber(feedId: String, userId: String) async throws -> PostFeedCard?
}

public struct RemoteRoomsAPI: RoomsAPI {
    public static let feedPageSize = 20

    private let main: HTTPClient

    public init(main: HTTPClient) {
        self.main = main
    }

    public func rooms() async throws -> [RoomCard] {
        try await main.getDecoded("/api/room/get-all-cards-by-jwt")
    }

    public func room(id: String) async throws -> RoomDetails {
        try await main.getDecoded("/api/room/get/\(Self.path(id))")
    }

    public func role(roomId: String) async throws -> MemberRole? {
        let response = try await main.get("/api/room/\(Self.path(roomId))/role")
        if response.statusCode == 404 { return nil }
        return try? HTTPClient.decode(response, as: MemberRole.self)
    }

    public func createRoom(name: String, creatorUserId: String) async throws {
        try HTTPClient.requireSuccess(try await main.post("/api/room/create", json: CreateRoomBody(name: name, creator: .init(userId: creatorUserId))))
    }

    public func createChannel(roomId: String, name: String, kind: RoomChannel.Kind, creatorUserId: String) async throws -> RoomChannel {
        try await main.postDecoded("/api/channel/create", json: CreateChannelBody(name: name, type: kind, creator: .init(userId: creatorUserId), room: .init(id: roomId)), as: RoomChannel.self)
    }

    public func joinRoom(code: String, userId: String) async throws {
        try HTTPClient.requireSuccess(try await main.send(method: "PUT", path: "/api/room/invite-user", body: JSONEncoder().encode(JoinRoomBody(roomCode: code, userId: userId))))
    }

    public func events(roomId: String, from: Date, to: Date) async throws -> [RoomEvent] {
        try await main.getDecoded("/api/room/\(Self.path(roomId))/events?from=\(Self.query(RoomDates.format(from)))&to=\(Self.query(RoomDates.format(to)))")
    }

    public func createEvent(roomId: String, event: RoomEvent) async throws {
        try HTTPClient.requireSuccess(try await main.post("/api/room/\(Self.path(roomId))/events", json: event))
    }

    public func feeds(userId: String) async throws -> [PostFeedCard] {
        try await main.getDecoded("/api/post-feed/subscriber/\(Self.path(userId))")
    }

    public func createFeed(name: String, userId: String) async throws {
        try HTTPClient.requireSuccess(try await main.post("/api/post-feed/create", json: CreateFeedBody(name: name, userId: userId)))
    }

    public func deleteFeed(id: String) async throws {
        try HTTPClient.requireSuccess(try await main.send(method: "DELETE", path: "/api/post-feed/\(Self.path(id))", body: nil))
    }

    public func feedRole(feedId: String) async throws -> MemberRole? {
        let response = try await main.get("/api/post-feed/\(Self.path(feedId))/role")
        if response.statusCode == 404 { return nil }
        return try HTTPClient.decode(response, as: MemberRole.self)
    }

    public func feedPrivileges(feedId: String, userId: String) async throws -> FeedPrivileges {
        try await main.getDecoded("/api/post-feed-privilege/\(Self.path(feedId))/moderator/\(Self.path(userId))")
    }

    public func posts(feedId: String, page: Int) async throws -> [FeedPost] {
        try await main.getDecoded("/api/post-feed/\(Self.path(feedId))/posts?page=\(page)")
    }

    public func createPost(feedId: String, userId: String, text: String, timestamp: Int64, attachments: [ChatAttachment]) async throws -> FeedPost {
        try await main.postDecoded("/api/post-feed/post/create", json: CreatePostBody(postFeedId: feedId, userId: userId, message: text, dateTimeCreateTimestamp: timestamp, attachedFiles: attachments), as: FeedPost.self)
    }

    public func setSubscribed(_ subscribed: Bool, feedId: String, userId: String) async throws {
        let path = subscribed ? "/api/post-feed/subscriber/add" : "/api/post-feed/subscriber/remove"
        try HTTPClient.requireSuccess(try await main.send(method: "PUT", path: path, body: JSONEncoder().encode(FeedUserBody(postFeedId: feedId, userId: userId))))
    }

    public func feedMembers(feedId: String) async throws -> FeedMembers {
        try await main.getDecoded("/api/post-feed/\(Self.path(feedId))/members")
    }

    public func addModerator(feedId: String, userId: String, privileges: FeedPrivileges) async throws {
        let body = ModeratorBody(postFeedId: feedId, userId: userId, privileges: privileges)
        try HTTPClient.requireSuccess(try await main.send(method: "PUT", path: "/api/post-feed/moderator/add", body: JSONEncoder().encode(body)))
    }

    public func removeModerator(feedId: String, userId: String) async throws {
        try HTTPClient.requireSuccess(try await main.send(method: "PUT", path: "/api/post-feed/moderator/remove", body: JSONEncoder().encode(FeedUserBody(postFeedId: feedId, userId: userId))))
    }

    public func setBanned(_ banned: Bool, feedId: String, userId: String) async throws {
        let path = banned ? "/api/post-feed/ban/add" : "/api/post-feed/ban/remove"
        try HTTPClient.requireSuccess(try await main.send(method: "PUT", path: path, body: JSONEncoder().encode(FeedUserBody(postFeedId: feedId, userId: userId))))
    }

    public func markPostViewed(postId: String) async throws {
        try HTTPClient.requireSuccess(try await main.send(method: "POST", path: "/api/post-feed/post/\(Self.path(postId))/view", body: nil))
    }

    public func comments(postId: String) async throws -> [PostComment] {
        try await main.getDecoded("/api/post-feed/post/\(Self.path(postId))/comments?page=0")
    }

    public func createComment(postId: String, userId: String, text: String, timestamp: Int64) async throws -> PostComment {
        try await main.postDecoded("/api/post-feed/post/\(Self.path(postId))/comment/create", json: CommentBody(userId: userId, message: text, dateTimeCreateTimestamp: timestamp), as: PostComment.self)
    }

    public func deleteComment(id: String) async throws {
        try HTTPClient.requireSuccess(try await main.send(method: "DELETE", path: "/api/post-feed/comment/\(Self.path(id))", body: nil))
    }

    public func addSubscriber(feedId: String, userId: String) async throws -> PostFeedCard? {
        let response = try await main.send(method: "PUT", path: "/api/post-feed/subscriber/add", body: JSONEncoder().encode(FeedUserBody(postFeedId: feedId, userId: userId)))
        try HTTPClient.requireSuccess(response)
        return try? JSONDecoder().decode(PostFeedCard.self, from: response.body)
    }

    static func path(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? value
    }

    static func query(_ value: String) -> String {
        path(value)
    }
}

/// Даты календаря: ISO 8601 UTC с миллисекундами, как `toISOString()`.
public enum RoomDates {
    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    public static func parse(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// Ссылки-приглашения веб-клиента: `/invite/<base64(roomId)>` и `/post-feed-invite/<base64(feedId)>`.
public enum InviteLinks {
    /// Код канала: `base64(feedId)`, в том числе в URL-safe варианте; принимается только UUID.
    public static func feedId(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let code: String
        if let range = trimmed.range(of: "/post-feed-invite/") {
            code = trimmed[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        } else if !trimmed.contains("/") {
            code = trimmed
        } else {
            return nil
        }
        var base64 = (code.removingPercentEncoding ?? code).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf8), UUID(uuidString: decoded) != nil else { return nil }
        return decoded
    }

    public static func feedURL(origin: URL, feedId: String) -> URL {
        origin.appendingPathComponent("post-feed-invite").appendingPathComponent(Data(feedId.utf8).base64EncodedString())
    }

    public static func roomURL(origin: URL, roomId: String) -> URL {
        origin.appendingPathComponent("invite").appendingPathComponent(Data(roomId.utf8).base64EncodedString())
    }

    /// Код комнаты из ссылки или из самого кода; сервису он уходит как есть, без декодирования.
    public static func roomCode(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: "/invite/") {
            let code = trimmed[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            return code.removingPercentEncoding ?? code
        }
        return trimmed.contains("/") ? nil : trimmed
    }
}

private struct CreateRoomBody: Encodable, Sendable {
    struct Creator: Encodable, Sendable { let userId: String }
    let name: String
    let creator: Creator
}

private struct CreateChannelBody: Encodable, Sendable {
    struct Creator: Encodable, Sendable { let userId: String }
    struct Room: Encodable, Sendable { let id: String }
    let name: String
    let type: RoomChannel.Kind
    let creator: Creator
    let room: Room
}

private struct JoinRoomBody: Encodable, Sendable {
    let roomCode: String
    let userId: String
}

private struct CreateFeedBody: Encodable, Sendable {
    let name: String
    let userId: String
}

private struct CreatePostBody: Encodable, Sendable {
    let postFeedId: String
    let userId: String
    let message: String
    let dateTimeCreateTimestamp: Int64
    let attachedFiles: [ChatAttachment]
}

private struct FeedUserBody: Encodable, Sendable {
    let postFeedId: String
    let userId: String
}

/// Комментарий к посту канала.
public struct PostComment: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var postId: String?
    public var text: String
    public var createdAtMilliseconds: Int64
    public var userId: String?
    public var username: String

    public init(id: String, postId: String? = nil, text: String, createdAtMilliseconds: Int64, userId: String?, username: String) {
        self.id = id
        self.postId = postId
        self.text = text
        self.createdAtMilliseconds = createdAtMilliseconds
        self.userId = userId
        self.username = username
    }

    public var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(createdAtMilliseconds) / 1000) }

    enum CodingKeys: String, CodingKey { case id, postId, message, dateTimeCreateTimestamp, userId, username }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .id) {
            id = string
        } else {
            id = String(try container.decode(Int64.self, forKey: .id))
        }
        postId = try? container.decodeIfPresent(String.self, forKey: .postId)
        text = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? ""
        createdAtMilliseconds = (try? container.decodeIfPresent(Int64.self, forKey: .dateTimeCreateTimestamp))
            ?? (try? container.decodeIfPresent(Double.self, forKey: .dateTimeCreateTimestamp)).map { Int64($0) }
            ?? 0
        userId = try? container.decodeIfPresent(String.self, forKey: .userId)
        username = (try? container.decodeIfPresent(String.self, forKey: .username)) ?? ""
    }
}

private struct ModeratorBody: Encodable, Sendable {
    let postFeedId: String
    let userId: String
    let privileges: FeedPrivileges

    enum CodingKeys: String, CodingKey { case postFeedId, userId }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(postFeedId, forKey: .postFeedId)
        try container.encode(userId, forKey: .userId)
        try privileges.encode(to: encoder)
    }
}

private struct CommentBody: Encodable, Sendable {
    let userId: String
    let message: String
    let dateTimeCreateTimestamp: Int64
}
