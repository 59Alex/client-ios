import ConnectChat
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

    private func merge(_ incoming: [FeedPost]) {
        var byId = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for post in incoming { byId[post.id] = post }
        posts = byId.values.sorted { ($0.createdAtMilliseconds, $0.id) < ($1.createdAtMilliseconds, $1.id) }
    }
}
