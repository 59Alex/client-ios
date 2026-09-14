import ConnectNetworking
import ConnectChat
import ConnectRooms
import Foundation

/// Комнаты, календарь и каналы-ленты в памяти для тестов и офлайн-стаба.
public actor FakeRoomsAPI: RoomsAPI {
    public private(set) var roomCards: [RoomCard]
    public private(set) var roomDetails: [String: RoomDetails]
    public private(set) var roles: [String: MemberRole]
    public private(set) var roomEvents: [String: [RoomEvent]]
    public private(set) var joinedCodes: [String] = []
    public private(set) var feedCards: [PostFeedCard]
    public private(set) var feedRoles: [String: MemberRole]
    public private(set) var feedPosts: [String: [FeedPost]]
    public private(set) var eventRequests: [(from: Date, to: Date)] = []
    private var counter = 0

    public init(
        rooms: [RoomDetails] = [],
        roles: [String: MemberRole] = [:],
        events: [String: [RoomEvent]] = [:],
        feeds: [PostFeedCard] = [],
        feedRoles: [String: MemberRole] = [:],
        posts: [String: [FeedPost]] = [:],
        feedMembers: [String: FeedMembers] = [:],
        comments: [String: [PostComment]] = [:]
    ) {
        membersByFeed = feedMembers
        commentsByPost = comments
        roomCards = rooms.map { RoomCard(id: $0.id, name: $0.name, textChannelIds: $0.channels.filter { $0.kind == .text }.map(\.id)) }
        roomDetails = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0) })
        self.roles = roles
        roomEvents = events
        feedCards = feeds
        self.feedRoles = feedRoles
        feedPosts = posts
    }

    public func rooms() async throws -> [RoomCard] { roomCards }

    public func room(id: String) async throws -> RoomDetails {
        guard let details = roomDetails[id] else { throw URLError(.fileDoesNotExist) }
        return details
    }

    public func role(roomId: String) async throws -> MemberRole? { roles[roomId] }

    public func createRoom(name: String, creatorUserId: String) async throws {
        counter += 1
        let room = RoomDetails(id: "room-new-\(counter)", name: name, channels: [])
        roomDetails[room.id] = room
        roomCards.append(RoomCard(id: room.id, name: name))
        roles[room.id] = .admin
    }

    public func createChannel(roomId: String, name: String, kind: RoomChannel.Kind, creatorUserId: String) async throws -> RoomChannel {
        guard roles[roomId]?.canManage == true else { throw URLError(.userAuthenticationRequired) }
        counter += 1
        let channel = RoomChannel(id: "channel-new-\(counter)", name: name, kind: kind)
        roomDetails[roomId]?.channels.append(channel)
        return channel
    }

    public func joinRoom(code: String, userId: String) async throws {
        joinedCodes.append(code)
    }

    public func events(roomId: String, from: Date, to: Date) async throws -> [RoomEvent] {
        eventRequests.append((from, to))
        return (roomEvents[roomId] ?? []).filter { $0.startsAt >= from && $0.startsAt < to }
    }

    public func createEvent(roomId: String, event: RoomEvent) async throws {
        counter += 1
        var stored = event
        stored.id = "event-\(counter)"
        roomEvents[roomId, default: []].append(stored)
    }

    public func feeds(userId: String) async throws -> [PostFeedCard] { feedCards }

    public func createFeed(name: String, userId: String) async throws {
        counter += 1
        let id = "feed-new-\(counter)"
        feedCards.append(PostFeedCard(id: id, name: name))
        feedRoles[id] = .admin
    }

    public func deleteFeed(id: String) async throws {
        feedCards.removeAll { $0.id == id }
    }

    public func feedRole(feedId: String) async throws -> MemberRole? { feedRoles[feedId] }

    public func feedPrivileges(feedId: String, userId: String) async throws -> FeedPrivileges { privilegesByFeed[feedId] ?? FeedPrivileges() }

    public func posts(feedId: String, page: Int) async throws -> [FeedPost] {
        let newestFirst = (feedPosts[feedId] ?? []).sorted { $0.createdAtMilliseconds > $1.createdAtMilliseconds }
        let start = page * RemoteRoomsAPI.feedPageSize
        guard start < newestFirst.count else { return [] }
        return Array(newestFirst[start..<min(newestFirst.count, start + RemoteRoomsAPI.feedPageSize)])
    }

    public func createPost(feedId: String, userId: String, text: String, timestamp: Int64, attachments: [ChatAttachment]) async throws -> FeedPost {
        counter += 1
        let post = FeedPost(id: "post-new-\(counter)", text: text, createdAtMilliseconds: timestamp, userId: userId, username: userId, attachments: attachments)
        feedPosts[feedId, default: []].append(post)
        return post
    }

    public func setSubscribed(_ subscribed: Bool, feedId: String, userId: String) async throws {
        feedRoles[feedId] = subscribed ? .subscriber : nil
    }

    public private(set) var moderationLog: [String] = []
    public private(set) var viewedPosts: [String] = []
    public private(set) var commentsByPost: [String: [PostComment]] = [:]
    public var membersByFeed: [String: FeedMembers] = [:]
    public var privilegesByFeed: [String: FeedPrivileges] = [:]
    public var joinStatus: Int?

    public func setMembers(_ members: FeedMembers, feedId: String) { membersByFeed[feedId] = members }
    public func setPrivileges(_ privileges: FeedPrivileges, feedId: String) { privilegesByFeed[feedId] = privileges }
    public func setJoinStatus(_ status: Int?) { joinStatus = status }
    public func setComments(_ comments: [PostComment], postId: String) { commentsByPost[postId] = comments }

    public func addModerator(feedId: String, userId: String, privileges: FeedPrivileges) async throws {
        moderationLog.append("moderator+:\(userId):\(privileges.canBanUsers)")
        var members = membersByFeed[feedId] ?? FeedMembers()
        if let member = members.subscribers.first(where: { $0.userId == userId }) { members.moderators.append(member) }
        membersByFeed[feedId] = members
    }

    public func removeModerator(feedId: String, userId: String) async throws {
        moderationLog.append("moderator-:\(userId)")
        membersByFeed[feedId]?.moderators.removeAll { $0.userId == userId }
    }

    public func setBanned(_ banned: Bool, feedId: String, userId: String) async throws {
        moderationLog.append("\(banned ? "ban" : "unban"):\(userId)")
        var members = membersByFeed[feedId] ?? FeedMembers()
        if banned {
            let member = (members.subscribers + members.moderators).first { $0.userId == userId } ?? .init(userId: userId, username: userId)
            members.bannedUsers.append(member)
        } else {
            members.bannedUsers.removeAll { $0.userId == userId }
        }
        membersByFeed[feedId] = members
    }

    public func markPostViewed(postId: String) async throws { viewedPosts.append(postId) }

    public func comments(postId: String) async throws -> [PostComment] { commentsByPost[postId] ?? [] }

    public func createComment(postId: String, userId: String, text: String, timestamp: Int64) async throws -> PostComment {
        counter += 1
        let comment = PostComment(id: "comment-new-\(counter)", postId: postId, text: text, createdAtMilliseconds: timestamp, userId: userId, username: userId)
        commentsByPost[postId, default: []].append(comment)
        return comment
    }

    public func deleteComment(id: String) async throws {
        for key in commentsByPost.keys { commentsByPost[key]?.removeAll { $0.id == id } }
    }

    public func addSubscriber(feedId: String, userId: String) async throws -> PostFeedCard? {
        if let joinStatus { throw APIError.http(statusCode: joinStatus, body: nil) }
        moderationLog.append("subscriber+:\(userId)")
        membersByFeed[feedId, default: FeedMembers()].subscribers.append(.init(userId: userId, username: userId))
        if feedCards.first(where: { $0.id == feedId }) == nil { feedCards.append(PostFeedCard(id: feedId, name: "Канал по ссылке")) }
        return feedCards.first { $0.id == feedId }
    }

    public func feedMembers(feedId: String) async throws -> FeedMembers {
        if let members = membersByFeed[feedId] { return members }
        return FeedMembers(admin: .init(userId: "owner", username: "owner"), subscribers: [.init(userId: "me", username: "me")])
    }
}
