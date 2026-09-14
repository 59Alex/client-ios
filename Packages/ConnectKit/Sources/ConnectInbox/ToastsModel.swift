import Foundation
import Observation

/// Всплывающие уведомления (`NotificationCenter.tsx`): до трёх, новые сверху.
/// Первая загрузка не показывает тостов; при открытом центре уведомлений очередь очищается.
@MainActor
@Observable
public final class ToastsModel {
    public static let maxVisible = 3
    public static let displayDuration: Duration = .seconds(5)

    public private(set) var toasts: [InboxNotification] = []
    /// Центр уведомлений открыт: тосты не показываются.
    public var isSuppressed = false {
        didSet { if isSuppressed { toasts = [] } }
    }

    private let api: any InboxAPI
    private var known: Set<Int64> = []
    private var initialized = false

    public init(api: any InboxAPI) {
        self.api = api
    }

    /// Перечитывает первую страницу после события потока; новые непросмотренные строки становятся тостами.
    public func refresh() async {
        guard let page = try? await api.notifications(before: nil, limit: NotificationCenterModel.pageSize) else { return }
        ingest(page)
    }

    func ingest(_ page: [InboxNotification]) {
        let fresh = page.filter { !known.contains($0.id) }
        known.formUnion(page.map(\.id))
        defer { initialized = true }
        guard initialized, !isSuppressed else { return }
        let shown = fresh.filter { $0.viewedAt == nil && $0.messageReadAt == nil }.sorted { $0.id > $1.id }
        guard !shown.isEmpty else { return }
        toasts = Array((shown + toasts).prefix(Self.maxVisible))
    }

    /// Автоскрытие: только локально.
    public func hide(_ id: Int64) {
        toasts.removeAll { $0.id == id }
    }

    /// Крестик, свайп или переход: уведомление снимается и на сервере.
    public func dismiss(_ id: Int64) async {
        hide(id)
        try? await api.dismiss(ids: [id])
    }

    public static func title(_ notification: InboxNotification) -> String {
        notification.chatType == .roomEvent ? "Событие комнаты" : "Новое сообщение"
    }

    public static func text(_ notification: InboxNotification) -> String {
        let body = notification.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = body.isEmpty ? "Вложение" : body
        guard let startsAt = notification.eventStartsAt else { return base }
        let formatted = startsAt.formatted(.dateTime.day().month(.wide).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "ru_RU")))
        return "\(base) · \(formatted)"
    }
}
