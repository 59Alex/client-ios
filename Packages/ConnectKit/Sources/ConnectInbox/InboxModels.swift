import Foundation
import Observation

/// Центр уведомлений: список с догрузкой, отметка просмотра, скрытие.
@MainActor
@Observable
public final class NotificationCenterModel {
    public static let pageSize = 30

    public private(set) var items: [InboxNotification] = []
    public private(set) var hasMore = false
    public private(set) var isLoading = false
    public private(set) var failed = false

    private let api: any InboxAPI
    private var viewedSent: Set<Int64> = []

    public init(api: any InboxAPI) {
        self.api = api
    }

    public var unviewedCount: Int {
        items.filter { $0.viewedAt == nil }.count
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.notifications(before: nil, limit: Self.pageSize)
            items = Self.visible(page)
            hasMore = page.count == Self.pageSize
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = items.isEmpty
        }
    }

    public func loadMore() async {
        guard hasMore, !isLoading, let last = items.last?.id else { return }
        isLoading = true
        defer { isLoading = false }
        guard let page = try? await api.notifications(before: last, limit: Self.pageSize) else { return }
        let known = Set(items.map(\.id))
        items = Self.visible(items + page.filter { !known.contains($0.id) })
        hasMore = page.count == Self.pageSize
    }

    /// Показанные уведомления отмечаются просмотренными одним запросом.
    public func markViewed(_ ids: [Int64]) async {
        var seen = Set<Int64>()
        let fresh = ids.filter { id in
            seen.insert(id).inserted && !viewedSent.contains(id) && items.contains { $0.id == id && $0.viewedAt == nil }
        }
        guard !fresh.isEmpty else { return }
        viewedSent.formUnion(fresh)
        do {
            try await api.markViewed(ids: fresh)
            let now = Date()
            for index in items.indices where fresh.contains(items[index].id) {
                items[index].viewedAt = now
            }
        } catch {
            viewedSent.subtract(fresh)
        }
    }

    public func dismiss(_ id: Int64) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: index)
        do {
            try await api.dismiss(ids: [id])
        } catch {
            items.insert(removed, at: min(index, items.count))
        }
    }

    public func dismissAll() async {
        guard let throughId = try? await api.dismissAll() else {
            await load()
            return
        }
        items.removeAll { $0.id <= throughId }
        hasMore = false
    }

    /// Уведомления о прочитанных сообщениях не показываются; новые сверху.
    static func visible(_ items: [InboxNotification]) -> [InboxNotification] {
        items.filter { $0.messageReadAt == nil }.sorted { $0.id > $1.id }
    }
}

/// Приглашения: входящие и исходящие, решения с ожиданием обработки на сервере.
@MainActor
@Observable
public final class InvitationsModel {
    public static let pageSize = 50
    /// Решение обрабатывается асинхронно: столько ждём смены статуса.
    public static let decisionTimeout: Duration = .seconds(10)

    public private(set) var invitations: [Invitation] = []
    public private(set) var pendingCount = 0
    public private(set) var processingIds: Set<String> = []
    public private(set) var message: String?

    private let me: String
    private let api: any InboxAPI
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(me: String, api: any InboxAPI, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.me = me
        self.api = api
        self.sleep = sleep
    }

    public var incoming: [Invitation] { invitations.filter { $0.recipientUserId == me } }
    public var outgoing: [Invitation] { invitations.filter { $0.senderUserId == me && $0.recipientUserId != me } }

    public func title(of invitation: Invitation) -> String {
        invitation.title(me: me)
    }

    public func load() async {
        async let list = try? api.invitations(page: 0)
        async let pending = try? api.pendingInvitations()
        if let loaded = await list {
            invitations = loaded
        }
        pendingCount = await pending ?? invitations.filter { $0.status == .pending && $0.recipientUserId == me }.count
    }

    /// Возвращает принятое приглашение, если сервис успел его обработать.
    @discardableResult
    public func decide(_ invitation: Invitation, action: Invitation.Action) async -> Invitation? {
        processingIds.insert(invitation.id)
        message = nil
        defer { processingIds.remove(invitation.id) }
        do {
            try await api.decide(invitationId: invitation.id, action: action)
        } catch {
            message = "Не удалось изменить приглашение. Оно могло быть уже отменено."
            return nil
        }

        let attempts = 10
        for attempt in 0..<attempts {
            await load()
            if let updated = invitations.first(where: { $0.id == invitation.id }), updated.status != .pending {
                return updated.status == .accepted ? updated : nil
            }
            if attempt < attempts - 1 {
                try? await sleep(.seconds(1))
            }
        }
        message = "Ответ принят в обработку. Статус обновится чуть позже."
        return nil
    }
}

/// Создание группы: название обязательно, участники из контактов, можно без них.
@MainActor
@Observable
public final class CreateGroupModel {
    public static let maxNameLength = 199

    public var name = "" {
        didSet {
            if name.count > Self.maxNameLength { name = String(name.prefix(Self.maxNameLength)) }
        }
    }
    public var meetingsAllowed = false
    public private(set) var selectedUserIds: Set<String> = []
    public private(set) var isSubmitting = false
    public private(set) var errorMessage: String?

    private let me: String
    private let api: any InboxAPI

    public init(me: String, api: any InboxAPI) {
        self.me = me
        self.api = api
    }

    public var canSubmit: Bool {
        !isSubmitting && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func toggle(_ userId: String) {
        guard userId != me else { return }
        if selectedUserIds.contains(userId) {
            selectedUserIds.remove(userId)
        } else {
            selectedUserIds.insert(userId)
        }
    }

    public func submit() async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Укажите название чата"
            return false
        }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await api.createGroup(NewGroup(name: trimmed, creatorUserId: me, memberUserIds: selectedUserIds.sorted(), meetingsAllowed: meetingsAllowed))
            return true
        } catch {
            errorMessage = "Не удалось создать группу"
            return false
        }
    }
}
