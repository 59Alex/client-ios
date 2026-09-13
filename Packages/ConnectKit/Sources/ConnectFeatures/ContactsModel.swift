import ConnectCore
import ConnectNetworking
import Foundation
import Observation

public protocol ContactsRepository: Sendable {
    func contacts(of userId: String) async throws -> [Contact]
    /// Поиск по логину или телефону; `nil`, если никого нет.
    func search(_ query: ContactQuery) async throws -> Contact?
    func addContact(userId: String, contactUserId: String) async throws
    func removeContact(contactUserId: String) async throws
    func profile(userId: String) async throws -> Contact
    /// Комната личного чата, созданная при необходимости (`create-by-username`).
    func openChat(myUsername: String, companionUsername: String) async throws -> String
    func isBlocked(userId: String, contactUserId: String) async throws -> Bool
    func setBlocked(_ blocked: Bool, userId: String, contactUserId: String) async throws
}

/// Запрос поиска контакта, нормализованный как в `contactSearch.ts`.
public enum ContactQuery: Sendable, Equatable {
    case login(String)
    case phone(String)

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let phoneCharacters = CharacterSet(charactersIn: "0123456789 ()+-")
        if trimmed.contains(where: \.isNumber), trimmed.unicodeScalars.allSatisfy(phoneCharacters.contains) {
            guard let phone = Self.formatPhone(trimmed) else { return nil }
            self = .phone(phone)
        } else {
            let login = String(trimmed.drop { $0 == "@" })
            guard !login.isEmpty else { return nil }
            self = .login("@" + login)
        }
    }

    /// `8…` и `7…` → `+7 (999) 123-45-67`; иначе к десяти цифрам добавляется 7.
    public static func formatPhone(_ raw: String) -> String? {
        var digits = raw.filter(\.isNumber)
        if digits.hasPrefix("8") {
            digits = "7" + digits.dropFirst().prefix(10)
        } else if digits.hasPrefix("7") {
            digits = String(digits.prefix(11))
        } else {
            digits = "7" + digits.prefix(10)
        }
        guard digits.count == 11 else { return nil }
        let chars = Array(digits)
        func slice(_ from: Int, _ to: Int) -> String { String(chars[from..<to]) }
        return "+7 (\(slice(1, 4))) \(slice(4, 7))-\(slice(7, 9))-\(slice(9, 11))"
    }
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

    public func search(_ query: ContactQuery) async throws -> Contact? {
        let path = switch query {
        case let .login(login): "/api/user-card/search-by-login/\(Self.pathComponent(login))"
        case let .phone(phone): "/api/user-card/search-by-phone/\(Self.pathComponent(phone))"
        }
        let response = try await client.get(path)
        if response.statusCode == 404 { return nil }
        return try HTTPClient.decode(response, as: Contact.self)
    }

    public func addContact(userId: String, contactUserId: String) async throws {
        try HTTPClient.requireSuccess(try await client.post("/api/user-card/add-contact", json: AddContactRequest(userId: userId, contactUserId: contactUserId)))
    }

    public func removeContact(contactUserId: String) async throws {
        try HTTPClient.requireSuccess(try await client.send(method: "DELETE", path: "/api/user-card/contacts/\(Self.pathComponent(contactUserId))", body: nil))
    }

    public func profile(userId: String) async throws -> Contact {
        try await client.getDecoded("/api/user-card/get-fast-info-by-user-id/\(Self.pathComponent(userId))")
    }

    public func openChat(myUsername: String, companionUsername: String) async throws -> String {
        try await client.postDecoded("/api/p2p-room/create-by-username", json: CreateByUsername(creator: myUsername, companion: companionUsername), as: IdResponse.self).id
    }

    public func isBlocked(userId: String, contactUserId: String) async throws -> Bool {
        let room = try await client.get("/api/p2p-room/get-by-users/\(Self.pathComponent(userId))/\(Self.pathComponent(contactUserId))")
        if room.statusCode == 404 { return false }
        let roomId = try HTTPClient.decode(room, as: IdResponse.self).id
        let snapshot = try await client.get("/api/p2p-room/get/\(Self.pathComponent(roomId))")
        if snapshot.statusCode == 404 { return false }
        return try HTTPClient.decode(snapshot, as: BanState.self).chatPartnerBanned ?? false
    }

    public func setBlocked(_ blocked: Bool, userId: String, contactUserId: String) async throws {
        let roomId = try await roomId(userId: userId, peerUserId: contactUserId)
        let response = blocked
            ? try await client.send(method: "PUT", path: "/api/p2p-room/ban/add/\(Self.pathComponent(roomId))", body: nil)
            : try await client.send(method: "DELETE", path: "/api/p2p-room/ban/remove/\(Self.pathComponent(roomId))", body: nil)
        try HTTPClient.requireSuccess(response)
    }

    private func roomId(userId: String, peerUserId: String) async throws -> String {
        let response = try await client.get("/api/p2p-room/get-by-users/\(Self.pathComponent(userId))/\(Self.pathComponent(peerUserId))")
        if response.statusCode != 404 {
            return try HTTPClient.decode(response, as: IdResponse.self).id
        }
        return try await client.postDecoded("/api/p2p-room/create", json: CreateRoom(creator: .init(userId: userId), companion: .init(userId: peerUserId)), as: IdResponse.self).id
    }

    static func pathComponent(_ value: String) -> String {
        // Как encodeURIComponent: кодируются `@`, `+`, пробел и `/`.
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")) ?? value
    }
}

private struct AddContactRequest: Encodable, Sendable {
    let userId: String
    let contactUserId: String
}

private struct CreateByUsername: Encodable, Sendable {
    let creator: String
    let companion: String
}

private struct CreateRoom: Encodable, Sendable {
    struct Member: Encodable, Sendable {
        let userId: String
    }

    let creator: Member
    let companion: Member
}

private struct IdResponse: Decodable {
    let id: String
}

private struct BanState: Decodable {
    let chatPartnerBanned: Bool?
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
    public var searchText = ""
    public private(set) var searchResult: SearchResult = .idle

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

    public enum SearchResult: Equatable {
        case idle
        case searching
        case found(Contact)
        case notFound
        case failed(String)
    }

    public func search() async {
        guard let query = ContactQuery(searchText) else {
            searchResult = .idle
            return
        }
        searchResult = .searching
        do {
            searchResult = try await repository.search(query).map(SearchResult.found) ?? .notFound
        } catch is CancellationError {
            return
        } catch {
            searchResult = .failed("Не удалось выполнить поиск")
        }
    }

    public func isContact(_ contact: Contact) -> Bool {
        contact.userId == userId || loadedContacts.contains { $0.userId == contact.userId }
    }

    /// Добавляет найденного пользователя; себя добавить нельзя.
    public func add(_ contact: Contact) async -> Bool {
        guard contact.userId != userId, !isContact(contact) else { return false }
        do {
            try await repository.addContact(userId: userId, contactUserId: contact.userId)
            state = .loaded(Self.sorted(loadedContacts + [contact]))
            searchText = ""
            searchResult = .idle
            return true
        } catch {
            return false
        }
    }

    public func remove(_ contact: Contact) async -> Bool {
        do {
            try await repository.removeContact(contactUserId: contact.userId)
            state = .loaded(loadedContacts.filter { $0.userId != contact.userId })
            return true
        } catch {
            return false
        }
    }

    /// Комната личного чата с контактом для «Написать».
    public func chatRoomId(with contact: Contact, myUsername: String) async throws -> String {
        try await repository.openChat(myUsername: myUsername, companionUsername: contact.handle)
    }

    public func profile(of contact: Contact) async -> Contact {
        (try? await repository.profile(userId: contact.userId)) ?? contact
    }

    public func isBlocked(_ contact: Contact) async -> Bool {
        (try? await repository.isBlocked(userId: userId, contactUserId: contact.userId)) ?? false
    }

    public func setBlocked(_ blocked: Bool, contact: Contact) async -> Bool {
        do {
            try await repository.setBlocked(blocked, userId: userId, contactUserId: contact.userId)
            return true
        } catch {
            return false
        }
    }

    private var loadedContacts: [Contact] {
        if case let .loaded(contacts) = state { return contacts }
        return []
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
