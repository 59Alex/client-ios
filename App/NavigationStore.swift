import Foundation

/// Хранилище последнего места в приложении; запись своя у каждого пользователя.
@MainActor
struct NavigationStore {
    static let keyPrefix = "connect.lastLocation.v1"

    let defaults: UserDefaults

    func load(userId: String) -> AppNavigation.Snapshot? {
        guard let data = defaults.data(forKey: key(userId)) else { return nil }
        // Старая или испорченная запись просто не восстанавливается.
        return try? JSONDecoder().decode(AppNavigation.Snapshot.self, from: data)
    }

    func save(_ snapshot: AppNavigation.Snapshot, userId: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key(userId))
    }

    func clear(userId: String) {
        defaults.removeObject(forKey: key(userId))
    }

    private func key(_ userId: String) -> String { "\(Self.keyPrefix).\(userId)" }
}
