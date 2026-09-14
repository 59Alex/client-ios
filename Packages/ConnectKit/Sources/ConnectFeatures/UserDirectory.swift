import ConnectCore
import Foundation
import Observation

/// Кэш карточек пользователей по `userId` для имён и аватаров в звонках и списках.
@MainActor
@Observable
public final class UserDirectory {
    public private(set) var cards: [String: Contact] = [:]

    private let repository: any ContactsRepository
    private var loading: Set<String> = []

    public init(repository: any ContactsRepository) {
        self.repository = repository
    }

    public func remember(_ contacts: [Contact]) {
        for contact in contacts { cards[contact.userId] = contact }
    }

    public func name(of userId: String) -> String? {
        cards[userId]?.displayName
    }

    /// Подгружает неизвестных пользователей; повторные запросы не уходят.
    public func load(_ userIds: [String]) async {
        let missing = Set(userIds).subtracting(cards.keys).subtracting(loading)
        guard !missing.isEmpty else { return }
        loading.formUnion(missing)
        defer { loading.subtract(missing) }
        await withTaskGroup(of: Contact?.self) { group in
            for userId in missing {
                let repository = repository
                group.addTask { try? await repository.profile(userId: userId) }
            }
            for await contact in group {
                if let contact { cards[contact.userId] = contact }
            }
        }
    }
}
