import ConnectNetworking
import Foundation
import Observation

/// Синхронизация оформления как `AppearanceSync` веб-клиента: один запрос за раз,
/// правки во время запроса копятся, на 409 запись перечитывается (до двух раз).
@MainActor
@Observable
public final class AppearanceModel {
    public enum State: Equatable, Sendable {
        case loading, ready, saving, error
    }

    public private(set) var draft: AppearancePreferences {
        didSet { if draft != oldValue { colors = ThemeColors(draft) } }
    }
    public private(set) var state: State = .loading
    /// Пересчитываются только при смене черновика: цвета читаются в каждом `body`.
    public private(set) var colors: ThemeColors

    private let api: any AppearanceAPI
    private let store: any AppearanceStore
    private var deviceId: String?
    private var saved: AppearanceSettings?
    private var pending: [Field: AppearancePreferences] = [:]
    private var isBusy = false
    private var initial: AppearancePreferences

    public init(api: any AppearanceAPI, store: any AppearanceStore) {
        self.api = api
        self.store = store
        let stored = store.load() ?? .standard
        initial = stored
        draft = stored
        colors = ThemeColors(stored)
    }

    /// Вход пользователя: запись устройства читается с сервера и отправляются накопленные правки.
    public func start(deviceId: String?) async {
        self.deviceId = deviceId
        saved = nil
        await flush()
    }

    /// Выход: локальный черновик остаётся, серверная запись забывается.
    public func stop() {
        saved = nil
        pending = [:]
        deviceId = nil
        initial = draft
        state = .loading
    }

    public func change(_ next: AppearancePreferences) {
        for field in Field.allCases where !field.equal(next, draft) {
            pending[field] = next
        }
        publish(.saving)
        Task { await flush() }
    }

    public func selectTheme(_ theme: AppearanceTheme) {
        change(draft.selecting(theme))
    }

    public func reset() {
        change(.standard)
    }

    public func flush() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if saved == nil { saved = try await api.appearance(deviceId: deviceId) }
            var conflicts = 0
            while !pending.isEmpty, let base = saved {
                let patch = pending
                var body = base.preferences
                for (field, source) in patch { field.copy(from: source, to: &body) }
                publish(.saving)
                do {
                    saved = try await api.updateAppearance(AppearanceSettings(preferences: body, revision: base.revision), deviceId: deviceId)
                } catch APIError.http(statusCode: 409, _) where conflicts < 2 {
                    conflicts += 1
                    saved = try await api.appearance(deviceId: deviceId)
                    continue
                }
                for (field, source) in patch where pending[field].map({ field.equal($0, source) }) == true {
                    pending[field] = nil
                }
            }
            publish(.ready)
        } catch {
            publish(.error)
        }
    }

    private func publish(_ state: State) {
        var next = saved?.preferences ?? initial
        for (field, source) in pending { field.copy(from: source, to: &next) }
        if next != draft { draft = next }
        store.save(next)
        self.state = state
    }

    enum Field: CaseIterable, Hashable {
        case theme, background, desktopBackground, accentColor, pressColor, chatBackground, ownMessageColor, otherMessageColor, messageNameColor, roomNameColor, reducedMotion

        func copy(from source: AppearancePreferences, to target: inout AppearancePreferences) {
            switch self {
            case .theme: target.theme = source.theme
            case .background: target.background = source.background
            case .desktopBackground: target.desktopBackground = source.desktopBackground
            case .accentColor: target.accentColor = source.accentColor
            case .pressColor: target.pressColor = source.pressColor
            case .chatBackground: target.chatBackground = source.chatBackground
            case .ownMessageColor: target.ownMessageColor = source.ownMessageColor
            case .otherMessageColor: target.otherMessageColor = source.otherMessageColor
            case .messageNameColor: target.messageNameColor = source.messageNameColor
            case .roomNameColor: target.roomNameColor = source.roomNameColor
            case .reducedMotion: target.reducedMotion = source.reducedMotion
            }
        }

        func equal(_ a: AppearancePreferences, _ b: AppearancePreferences) -> Bool {
            var copy = b
            self.copy(from: a, to: &copy)
            return copy == b
        }
    }
}
