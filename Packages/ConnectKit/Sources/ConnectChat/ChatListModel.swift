import Foundation
import Observation

/// Список личных или групповых чатов, от свежих сообщений к старым (`sortByLatestMessage.ts`).
@MainActor
@Observable
public final class ChatListModel {
    public enum State: Equatable {
        case loading
        case loaded([ChatSummary])
        case failed(String)
    }

    /// Веб перечитывает превью раз в 30 секунд и при каждом изменении сводки непрочитанного.
    public static let refreshInterval: Duration = .seconds(30)

    public let kind: ChatKind
    public private(set) var state: State = .loading

    private let api: any ChatAPI
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(kind: ChatKind, api: any ChatAPI, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.kind = kind
        self.api = api
        self.sleep = sleep
    }

    public var chats: [ChatSummary] {
        if case let .loaded(chats) = state { return chats }
        return []
    }

    public func load() async {
        do {
            var all: [ChatSummary] = []
            var page = 0
            while true {
                let items = try await api.rooms(kind, page: page)
                all.append(contentsOf: items)
                if items.count < RemoteChatAPI.roomPageSize { break }
                page += 1
            }
            state = .loaded(Self.sorted(all))
        } catch is CancellationError {
            return
        } catch {
            if case .loaded = state { return }
            state = .failed(kind == .group ? "Не удалось загрузить группы" : "Не удалось загрузить чаты")
        }
    }

    /// Периодическое обновление превью, пока задача не отменена.
    public func keepFresh() async {
        while !Task.isCancelled {
            do {
                try await sleep(Self.refreshInterval)
            } catch {
                return
            }
            await load()
        }
    }

    public static func sorted(_ chats: [ChatSummary]) -> [ChatSummary] {
        chats.enumerated().sorted { lhs, rhs in
            switch (lhs.element.preview?.createdAtMilliseconds, rhs.element.preview?.createdAtMilliseconds) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

/// Сводка непрочитанного и отметка прочтения пачками (`seenBatch.ts`).
@MainActor
@Observable
public final class UnreadModel {
    public static let readBatchDelay: Duration = .milliseconds(650)
    public static let readBatchLimit = 100

    public private(set) var summary = NotificationSummary(unread: 0, chats: [])
    /// Растёт при каждом изменении сводки: списки чатов перечитывают превью.
    public private(set) var revision = 0
    /// Растёт на каждое событие потока, кроме heartbeat: центр уведомлений и приглашения перечитываются.
    public private(set) var eventRevision = 0
    public private(set) var lastEventKind: String?

    private let api: any ChatAPI
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pendingRead: [String] = []
    private var sentRead: Set<String> = []
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false

    public init(api: any ChatAPI, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.api = api
        self.sleep = sleep
    }

    public func unreadCount(kind: ChatKind, roomId: String) -> Int {
        summary.chats.first { $0.key == "\(kind.rawValue):\(roomId)" }?.unread ?? 0
    }

    public func firstUnreadMessageId(kind: ChatKind, roomId: String) -> String? {
        summary.chats.first { $0.key == "\(kind.rawValue):\(roomId)" }?.firstUnreadMessageId
    }

    public func unreadCount(kind: ChatKind) -> Int {
        summary.chats.filter { $0.chatType == kind.rawValue }.reduce(0) { $0 + $1.unread }
    }

    public func refresh() async {
        guard let latest = try? await api.notificationSummary() else { return }
        if latest != summary {
            summary = latest
            revision += 1
        }
    }

    /// Живой поток уведомлений с переподключением (1,5 с × 2, не больше 15 с).
    public func run() async {
        var delay = 1.5
        while !Task.isCancelled {
            await refresh()
            do {
                for try await event in api.notificationEvents() {
                    delay = 1.5
                    if case let .changed(kind) = event {
                        lastEventKind = kind
                        eventRevision += 1
                        await refresh()
                    }
                }
            } catch {
                // Переподключение ниже.
            }
            do {
                try await sleep(.milliseconds(Int(delay * 1000)))
            } catch {
                return
            }
            delay = min(delay * 2, 15)
        }
    }

    /// Ставит прочитанные сообщения в очередь; запрос уходит пачкой после паузы.
    public func markRead(_ messageIds: [String]) {
        let fresh = messageIds.filter { Self.isServerId($0) && !sentRead.contains($0) && !pendingRead.contains($0) }
        guard !fresh.isEmpty else { return }
        pendingRead.append(contentsOf: fresh)
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(Self.readBatchDelay)
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    public func flush() async {
        // Один запрос за раз: отложенная и явная отправка не дублируют пачку.
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        var delay = 2.0
        while !pendingRead.isEmpty {
            let batch = Array(pendingRead.prefix(Self.readBatchLimit))
            pendingRead.removeFirst(batch.count)
            sentRead.formUnion(batch)
            do {
                try await api.markRead(messageIds: batch)
                delay = 2
            } catch {
                sentRead.subtract(batch)
                pendingRead.insert(contentsOf: batch, at: 0)
                do {
                    try await sleep(.milliseconds(Int(delay * 1000)))
                } catch {
                    return
                }
                delay = min(delay * 2, 30)
            }
        }
        try? await sleep(.milliseconds(200))
        await refresh()
    }

    /// Прочтение отмечается только для сохранённых на сервере сообщений (UUID из 36 символов).
    static func isServerId(_ id: String) -> Bool {
        id.count == 36 && UUID(uuidString: id) != nil
    }
}
