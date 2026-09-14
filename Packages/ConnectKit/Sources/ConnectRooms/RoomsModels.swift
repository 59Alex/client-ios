import ConnectChat
import ConnectNetworking
import Foundation
import Observation

/// Список комнат, создание и вход по коду приглашения.
@MainActor
@Observable
public final class RoomsModel {
    public enum State: Equatable {
        case loading
        case loaded([RoomCard])
        case failed(String)
    }

    public static let maxNameLength = 199

    public private(set) var state: State = .loading

    private let me: String
    private let api: any RoomsAPI

    public init(me: String, api: any RoomsAPI) {
        self.me = me
        self.api = api
    }

    public var rooms: [RoomCard] {
        if case let .loaded(rooms) = state { return rooms }
        return []
    }

    public func load() async {
        do {
            state = .loaded(try await api.rooms())
        } catch is CancellationError {
            return
        } catch {
            if case .loaded = state { return }
            state = .failed("Не удалось загрузить комнаты")
        }
    }

    /// Непрочитанное комнаты — сумма по её текстовым каналам.
    public func unreadCount(_ room: RoomCard, unread: UnreadModel) -> Int {
        room.textChannelIds.reduce(0) { $0 + unread.unreadCount(kind: .channel, roomId: $1) }
    }

    public func createRoom(name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Укажите название комнаты" }
        guard trimmed.count <= Self.maxNameLength else { return "Название не длиннее \(Self.maxNameLength) символов" }
        do {
            try await api.createRoom(name: trimmed, creatorUserId: me)
            await load()
            return nil
        } catch {
            return "Не удалось создать комнату"
        }
    }

    public func join(link: String) async -> String? {
        guard let code = InviteLinks.roomCode(from: link) else { return "Вставьте ссылку-приглашение" }
        do {
            try await api.joinRoom(code: code, userId: me)
            await load()
            return nil
        } catch {
            return "Не удалось войти по приглашению"
        }
    }
}

/// Открытая комната: каналы, роль, создание канала.
@MainActor
@Observable
public final class RoomModel {
    public static let maxChannelNameLength = 80

    public let roomId: String
    public private(set) var details: RoomDetails?
    public private(set) var role: MemberRole?
    public private(set) var failed = false

    private let me: String
    private let api: any RoomsAPI

    public init(roomId: String, me: String, api: any RoomsAPI) {
        self.roomId = roomId
        self.me = me
        self.api = api
    }

    public var canManage: Bool { role?.canManage ?? false }
    public var textChannels: [RoomChannel] { details?.channels.filter { $0.kind == .text } ?? [] }
    public var voiceChannels: [RoomChannel] { details?.channels.filter { $0.kind == .voice } ?? [] }

    public func load() async {
        do {
            async let details = api.room(id: roomId)
            async let role = try? api.role(roomId: roomId)
            self.details = try await details
            self.role = await role ?? nil
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = details == nil
        }
    }

    public func createChannel(name: String, kind: RoomChannel.Kind) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Укажите название канала" }
        guard trimmed.count <= Self.maxChannelNameLength else { return "Название не длиннее \(Self.maxChannelNameLength) символов" }
        do {
            let channel = try await api.createChannel(roomId: roomId, name: trimmed, kind: kind, creatorUserId: me)
            if var details {
                details.channels.removeAll { $0.id == channel.id }
                details.channels.append(channel)
                self.details = details
            }
            return nil
        } catch {
            return "Не удалось создать канал. Проверьте права"
        }
    }
}

/// Календарь комнаты: события месяца и создание события с напоминаниями (`reminderTimes.ts`).
@MainActor
@Observable
public final class RoomCalendarModel {
    public static let maxTitleLength = 160
    public static let maxDescriptionLength = 10_000
    public static let maxReminders = 4
    public static let reminderSpacing: TimeInterval = 12 * 3600

    public let roomId: String
    public private(set) var events: [RoomEvent] = []
    public private(set) var failed = false

    private let api: any RoomsAPI
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(roomId: String, api: any RoomsAPI, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = Date.init) {
        self.roomId = roomId
        self.api = api
        self.calendar = calendar
        self.now = now
    }

    /// События сетки месяца: с понедельника первой недели на 6 недель.
    public func load(month: Date) async {
        let range = Self.gridRange(for: month, calendar: calendar)
        do {
            events = try await api.events(roomId: roomId, from: range.lowerBound, to: range.upperBound)
                .sorted { ($0.startsAt, $0.id) < ($1.startsAt, $1.id) }
            failed = false
        } catch {
            failed = true
        }
    }

    public func events(on day: Date) -> [RoomEvent] {
        events.filter { calendar.isDate($0.startsAt, inSameDayAs: day) }
    }

    public func validate(title: String, description: String, startsAt: Date, reminders: [Date]) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Укажите название события" }
        if trimmed.count > Self.maxTitleLength { return "Название не длиннее \(Self.maxTitleLength) символов" }
        if description.count > Self.maxDescriptionLength { return "Описание слишком длинное" }
        if reminders.count > Self.maxReminders { return "Не больше \(Self.maxReminders) напоминаний" }
        let current = now()
        for reminder in reminders where reminder <= current || reminder > startsAt {
            return "Напоминание должно быть в будущем и не позже начала события"
        }
        let sorted = reminders.sorted()
        for (earlier, later) in zip(sorted, sorted.dropFirst()) where later.timeIntervalSince(earlier) < Self.reminderSpacing {
            return "Напоминания должны быть не чаще чем раз в 12 часов"
        }
        return nil
    }

    public func create(title: String, description: String, startsAt: Date, reminders: [Date]) async -> String? {
        if let error = validate(title: title, description: description, startsAt: startsAt, reminders: reminders) {
            return error
        }
        let event = RoomEvent(id: "", title: title.trimmingCharacters(in: .whitespacesAndNewlines), description: description, startsAt: startsAt, notificationTimes: reminders.sorted())
        do {
            try await api.createEvent(roomId: roomId, event: event)
            await load(month: startsAt)
            return nil
        } catch {
            return "Не удалось создать событие"
        }
    }

    public static func gridRange(for month: Date, calendar: Calendar) -> Range<Date> {
        var calendar = calendar
        calendar.firstWeekday = 2
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        let weekday = calendar.component(.weekday, from: startOfMonth)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: startOfMonth) ?? startOfMonth)
        let gridEnd = calendar.date(byAdding: .day, value: 42, to: gridStart) ?? gridStart
        return gridStart..<gridEnd
    }
}

/// Список каналов-лент: сортировка по последнему посту, создание.
@MainActor
@Observable
public final class FeedsModel {
    public private(set) var feeds: [PostFeedCard] = []
    public private(set) var loaded = false
    public private(set) var failed = false

    private let me: String
    private let api: any RoomsAPI

    public init(me: String, api: any RoomsAPI) {
        self.me = me
        self.api = api
    }

    public func load() async {
        do {
            feeds = try await api.feeds(userId: me).sorted { ($0.lastPostAtMilliseconds ?? 0) > ($1.lastPostAtMilliseconds ?? 0) }
            loaded = true
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = !loaded
        }
    }

    public func create(name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Укажите название канала" }
        do {
            try await api.createFeed(name: trimmed, userId: me)
            await load()
            return nil
        } catch {
            return "Не удалось создать канал"
        }
    }

    /// Подписка по ссылке `/post-feed-invite/<code>`; в ответ id канала или текст ошибки веб-клиента.
    public func join(link: String) async -> Result<String, JoinError> {
        guard let feedId = InviteLinks.feedId(from: link) else { return .failure(.broken) }
        do {
            _ = try await api.addSubscriber(feedId: feedId, userId: me)
            await load()
            return .success(feedId)
        } catch let APIError.http(statusCode, _) where statusCode == 404 {
            return .failure(.notFound)
        } catch let APIError.http(statusCode, _) where statusCode == 403 {
            return .failure(.forbidden)
        } catch {
            return .failure(.other)
        }
    }

    public enum JoinError: Error, Equatable {
        case broken, notFound, forbidden, other

        public var message: String {
            switch self {
            case .broken: "Ссылка приглашения в канал повреждена."
            case .notFound: "Канал больше не существует."
            case .forbidden: "Нет доступа к этому каналу."
            case .other: "Не удалось подписаться на канал. Попробуйте ещё раз."
            }
        }
    }
}

/// Открытый канал-лента: посты от старых к новым, догрузка старых страниц, публикация, подписка.
@MainActor
@Observable
public final class FeedModel {
    public let feedId: String
    public private(set) var role: MemberRole?
    public private(set) var privileges = FeedPrivileges()
    public private(set) var posts: [FeedPost] = []
    public private(set) var hasOlder = false
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    public var draft = ""

    private let me: ChatUser
    private let api: any RoomsAPI
    private let now: @Sendable () -> Date
    private var nextPage = 1

    public init(feedId: String, me: ChatUser, api: any RoomsAPI, now: @escaping @Sendable () -> Date = Date.init) {
        self.feedId = feedId
        self.me = me
        self.api = api
        self.now = now
    }

    public var isBanned: Bool { role == .banned }
    public var isSubscribed: Bool { role != nil && role != .banned }
    public var canPost: Bool { role == .admin || (role == .moderator && privileges.canCreatePosts) }
    public var canDelete: Bool { role == .admin }
    private var isAdmin: Bool { role == .admin }
    public var canAssignModerators: Bool { isAdmin || (role == .moderator && privileges.canAssignModerators) }
    public var canBan: Bool { isAdmin || (role == .moderator && privileges.canBanUsers) }
    public var canUnban: Bool { isAdmin || (role == .moderator && privileges.canUnbanUsers) }
    public private(set) var memberList: FeedMembers?
    public private(set) var moderationError: String?
    private var viewedPostIds: Set<String> = []
    /// Админ не может отписаться от своего канала.
    public var canUnsubscribe: Bool { role == .subscriber || role == .moderator }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            role = try await api.feedRole(feedId: feedId)
            guard !isBanned else { return }
            if role == .moderator {
                privileges = (try? await api.feedPrivileges(feedId: feedId, userId: me.userId)) ?? FeedPrivileges()
            }
            let page = try await api.posts(feedId: feedId, page: 0)
            merge(page)
            hasOlder = page.count == RemoteRoomsAPI.feedPageSize
            nextPage = 1
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Не удалось загрузить канал"
        }
    }

    /// Перечитывает первую страницу, когда в сводке появился новый пост.
    public func refresh() async {
        guard isSubscribed, let page = try? await api.posts(feedId: feedId, page: 0) else { return }
        merge(page)
    }

    public func loadOlder() async {
        guard hasOlder else { return }
        guard let page = try? await api.posts(feedId: feedId, page: nextPage) else { return }
        merge(page)
        hasOlder = page.count == RemoteRoomsAPI.feedPageSize
        nextPage += 1
    }

    public func publish(attachments: [ChatAttachment] = []) async -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canPost, !text.isEmpty || !attachments.isEmpty else { return false }
        do {
            let post = try await api.createPost(feedId: feedId, userId: me.userId, text: text, timestamp: Int64(now().timeIntervalSince1970 * 1000), attachments: attachments)
            merge([post])
            draft = ""
            return true
        } catch {
            errorMessage = "Не удалось опубликовать пост"
            return false
        }
    }

    public func setSubscribed(_ subscribed: Bool) async {
        do {
            // Модератор сначала снимает с себя права, как «Отписаться» веб-клиента.
            if !subscribed, role == .moderator {
                try await api.removeModerator(feedId: feedId, userId: me.userId)
            }
            try await api.setSubscribed(subscribed, feedId: feedId, userId: me.userId)
            await load()
        } catch {
            errorMessage = subscribed ? "Не удалось подписаться" : "Не удалось отписаться"
        }
    }

    public func deleteFeed() async -> Bool {
        guard canDelete else { return false }
        return (try? await api.deleteFeed(id: feedId)) != nil
    }

    public func members() async -> FeedMembers? {
        try? await api.feedMembers(feedId: feedId)
    }

    public func commentsModel(postId: String) -> PostCommentsModel {
        PostCommentsModel(postId: postId, me: me, api: api, now: now)
    }

    public func loadMembers() async {
        if let list = try? await api.feedMembers(feedId: feedId) { memberList = list }
    }

    /// Секции участников веб-клиента: забаненные не показываются среди модераторов и подписчиков.
    public var visibleModerators: [FeedMembers.Member] {
        guard let list = memberList else { return [] }
        let banned = Set(list.bannedUsers.map(\.userId))
        return list.moderators.filter { !banned.contains($0.userId) }
    }

    public var visibleSubscribers: [FeedMembers.Member] {
        guard let list = memberList else { return [] }
        let excluded = Set(list.bannedUsers.map(\.userId) + list.moderators.map(\.userId) + [list.admin?.userId].compactMap { $0 })
        return list.subscribers.filter { !excluded.contains($0.userId) }
    }

    public func makeModerator(_ userId: String, privileges: FeedPrivileges) async {
        guard canAssignModerators else { return }
        await moderate("Не удалось назначить модератора") { try await self.api.addModerator(feedId: self.feedId, userId: userId, privileges: privileges) }
    }

    public func removeModerator(_ userId: String) async {
        guard canAssignModerators else { return }
        await moderate("Не удалось снять модератора") { try await self.api.removeModerator(feedId: self.feedId, userId: userId) }
    }

    public func setBanned(_ banned: Bool, userId: String) async {
        guard banned ? canBan : canUnban else { return }
        await moderate(banned ? "Не удалось выдать бан" : "Не удалось разблокировать") { try await self.api.setBanned(banned, feedId: self.feedId, userId: userId) }
    }

    /// «Добавить из контактов»: контакт становится подписчиком.
    public func addSubscriber(_ userId: String) async -> Bool {
        do {
            _ = try await api.addSubscriber(feedId: feedId, userId: userId)
            await loadMembers()
            return true
        } catch {
            moderationError = "Не удалось добавить в канал"
            return false
        }
    }

    /// Просмотр поста уходит один раз за сессию и только для постов с серверным UUID.
    public func markViewed(_ postId: String) {
        guard UUID(uuidString: postId) != nil, viewedPostIds.insert(postId).inserted else { return }
        let api = api
        Task { try? await api.markPostViewed(postId: postId) }
    }

    private func moderate(_ failure: String, _ action: @escaping () async throws -> Void) async {
        do {
            try await action()
            moderationError = nil
        } catch {
            moderationError = failure
        }
        await loadMembers()
    }

    private func merge(_ incoming: [FeedPost]) {
        var byId = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for post in incoming { byId[post.id] = post }
        posts = byId.values.sorted { ($0.createdAtMilliseconds, $0.id) < ($1.createdAtMilliseconds, $1.id) }
    }
}

/// Комментарии поста (`PostCommentsThread.tsx`): список, свой комментарий, удаление только своих.
@MainActor
@Observable
public final class PostCommentsModel {
    public static let pollInterval: Duration = .seconds(4)

    public let postId: String
    public private(set) var comments: [PostComment] = []
    public private(set) var failed = false
    public var draft = ""

    private let me: ChatUser
    private let api: any RoomsAPI
    private let now: @Sendable () -> Date

    public init(postId: String, me: ChatUser, api: any RoomsAPI, now: @escaping @Sendable () -> Date = Date.init) {
        self.postId = postId
        self.me = me
        self.api = api
        self.now = now
    }

    public func isOwn(_ comment: PostComment) -> Bool { comment.userId == me.userId }

    public func load() async {
        do {
            let fresh = try await api.comments(postId: postId)
            // Оптимистичные комментарии остаются, пока сервер их не вернул.
            let local = comments.filter { pending in
                pending.id.hasPrefix("local-") && !fresh.contains { $0.text == pending.text && $0.userId == pending.userId }
            }
            comments = (fresh + local).sorted { $0.createdAtMilliseconds < $1.createdAtMilliseconds }
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = comments.isEmpty
        }
    }

    /// Опрос раз в 4 секунды, пока открыт тред.
    public func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let timestamp = Int64(now().timeIntervalSince1970 * 1000)
        let local = PostComment(id: "local-\(timestamp)", postId: postId, text: text, createdAtMilliseconds: timestamp, userId: me.userId, username: me.username)
        comments.append(local)
        draft = ""
        do {
            let created = try await api.createComment(postId: postId, userId: me.userId, text: text, timestamp: timestamp)
            if let index = comments.firstIndex(where: { $0.id == local.id }) { comments[index] = created }
        } catch {
            comments.removeAll { $0.id == local.id }
            draft = text
        }
    }

    public func delete(_ comment: PostComment) async {
        guard isOwn(comment), let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        let removed = comments.remove(at: index)
        do {
            try await api.deleteComment(id: comment.id)
        } catch {
            comments.insert(removed, at: min(index, comments.count))
        }
    }
}
