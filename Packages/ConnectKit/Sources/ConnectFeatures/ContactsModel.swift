import ConnectCore
import ConnectNetworking
import Foundation
import Observation

public protocol ContactsRepository: Sendable {
    func contacts(of userId: String) async throws -> [Contact]
}

/// Контакты из основного backend `connect` (`contacts_api.ts` веб-клиента).
public struct RemoteContactsRepository: ContactsRepository {
    private let client: HTTPClient

    public init(client: HTTPClient) {
        self.client = client
    }

    public func contacts(of userId: String) async throws -> [Contact] {
        try await client.getDecoded("/api/user-card/get-contacts/\(Self.pathComponent(userId))")
    }

    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }
}

/// Экран контактов: в сети сверху, затем по времени последнего визита, затем по имени —
/// порядок сортировки веб-клиента по умолчанию.
@MainActor
@Observable
public final class ContactsModel {
    public enum State: Equatable {
        case loading
        case loaded([Contact])
        case failed(String)
    }

    public private(set) var state: State = .loading

    private let userId: String
    private let repository: any ContactsRepository

    public init(userId: String, repository: any ContactsRepository) {
        self.userId = userId
        self.repository = repository
    }

    public func load() async {
        if case .loaded = state {} else { state = .loading }
        do {
            state = .loaded(Self.sorted(try await repository.contacts(of: userId)))
        } catch is CancellationError {
            return
        } catch {
            if case .loaded = state { return }
            state = .failed("Не удалось загрузить контакты")
        }
    }

    public static func sorted(_ contacts: [Contact]) -> [Contact] {
        contacts.sorted { lhs, rhs in
            let lhsOnline = lhs.status == .online
            let rhsOnline = rhs.status == .online
            if lhsOnline != rhsOnline { return lhsOnline }
            switch (lhs.lastSeenAt, rhs.lastSeenAt) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
    }
}
