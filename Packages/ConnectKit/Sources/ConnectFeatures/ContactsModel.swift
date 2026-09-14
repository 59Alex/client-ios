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
    /// Личный чат по id пользователей: `nil`, если его ещё нет.
    func existingChat(userId: String, peerUserId: String) async throws -> String?
    /// `POST /api/p2p-room/create` по id пользователей.
    func createChat(userId: String, peerUserId: String) async throws -> String
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

    public func existingChat(userId: String, peerUserId: String) async throws -> String? {
        let response = try await client.get("/api/p2p-room/get-by-users/\(Self.pathComponent(userId))/\(Self.pathComponent(peerUserId))")
        if response.statusCode == 404 { return nil }
        return try HTTPClient.decode(response, as: IdResponse.self).id
    }

    public func createChat(userId: String, peerUserId: String) async throws -> String {
        try await client.postDecoded("/api/p2p-room/create", json: CreateByUserIds(creator: .init(userId: userId), companion: .init(userId: peerUserId)), as: IdResponse.self).id
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
    public var sort: ContactSort = .lastSeen {
        didSet { if sort != oldValue, case let .loaded(contacts) = state { state = .loaded(Self.sorted(contacts, by: sort)) } }
    }

    private let userId: String
    private let repository: any ContactsRepository
    private let now: @Sendable () -> Date
    /// Скрытые в карточке профили не получают статус из снимка.
    private var hiddenInCard: Set<String> = []

    public init(userId: String, repository: any ContactsRepository, now: @escaping @Sendable () -> Date = { Date() }) {
        self.userId = userId
        self.repository = repository
        self.now = now
    }

    /// Id контактов для подписки на статусы, без себя, по порядку.
    public var presenceUserIds: [String] {
        Array(Set(loadedContacts.map(\.userId)).subtracting([userId])).sorted()
    }

    public func load() async {
        if case .loaded = state {} else { state = .loading }
        do {
            let fetched = try await repository.contacts(of: userId)
            hiddenInCard = Set(fetched.filter { $0.status == .hidden }.map(\.userId))
            let live = Dictionary(loadedContacts.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
            // Живой статус новее карточки: перечитанный список его не откатывает.
            let merged = fetched.map { contact in
                guard let known = live[contact.userId], liveUserIds.contains(contact.userId) else { return contact }
                var updated = contact
                updated.status = known.status
                updated.lastSeenAt = known.lastSeenAt ?? contact.lastSeenAt
                return updated
            }
            state = .loaded(Self.sorted(merged, by: sort))
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
            state = .loaded(Self.sorted(loadedContacts + [contact], by: sort))
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

    /// Пользователи, получившие живой кадр: снимок их больше не перезаписывает.
    private var liveUserIds: Set<String> = []

    /// Статусы контактов: снимок и живой поток с переподключением через 1,5 с, пока задача не отменена.
    public func watchPresence(api: any PresenceAPI, retryDelay: Duration = .milliseconds(1500)) async {
        let userIds = presenceUserIds
        guard !userIds.isEmpty else { return }
        while !Task.isCancelled {
            liveUserIds = []
            let snapshot = Task { try await api.snapshot(userIds: userIds) }
            let snapshotApplier = Task { @MainActor in
                guard let updates = try? await snapshot.value else { return }
                for update in updates where !self.liveUserIds.contains(update.userId) && !self.hiddenInCard.contains(update.userId) {
                    self.apply(update)
                }
            }
            do {
                for try await update in api.events(userIds: userIds) {
                    liveUserIds.insert(update.userId)
                    apply(update)
                }
            } catch {
                // Переподключение ниже.
            }
            snapshotApplier.cancel()
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                return
            }
        }
    }

    /// Уход из сети при открытом приложении даёт «был(а) только что» (`useLiveLastSeen.ts`).
    public func apply(_ update: PresenceUpdate) {
        guard case var .loaded(contacts) = state, let index = contacts.firstIndex(where: { $0.userId == update.userId }) else { return }
        let previous = contacts[index].status
        guard previous != update.status else { return }
        contacts[index].status = update.status
        if previous == .online, update.status == .offline {
            contacts[index].lastSeenAt = now()
        }
        state = .loaded(Self.sorted(contacts, by: sort))
    }

    public static func sorted(_ contacts: [Contact], by sort: ContactSort = .lastSeen) -> [Contact] {
        switch sort {
        case .name:
            return contacts.sorted { sortName($0).compare(sortName($1), locale: russian) == .orderedAscending }
        case .lastSeen:
            return contacts.sorted { lhs, rhs in
                let lhsRank = rank(lhs)
                let rhsRank = rank(rhs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhsRank == 1, let l = lhs.lastSeenAt, let r = rhs.lastSeenAt, l != r { return l > r }
                return sortName(lhs).compare(sortName(rhs), locale: russian) == .orderedAscending
            }
        }
    }

    private static let russian = Locale(identifier: "ru_RU")

    /// В сети, затем с известным временем визита, затем скрытые и неизвестные.
    private static func rank(_ contact: Contact) -> Int {
        if contact.status == .online { return 0 }
        if contact.status == .offline, contact.lastSeenAt != nil { return 1 }
        return 2
    }

    /// Имя без пробелов по краям, иначе логин без «@», в нижнем регистре.
    static func sortName(_ contact: Contact) -> String {
        let name = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? String(contact.username.drop { $0 == "@" }) : name).lowercased()
    }
}

private struct CreateByUserIds: Encodable, Sendable {
    struct Member: Encodable, Sendable { let userId: String }
    let creator: Member
    let companion: Member
}

/// Итог поиска знакомых из телефонной книги (`contactSync.ts`).
public struct PhoneBookSyncResult: Sendable, Equatable {
    public var scanned: Int
    public var matched: Int
    public var created: Int
    public var failed: Int
    /// Новые личные чаты: в списке у них приветствие «С вами в connect!», пока чат не открыт.
    public var createdRoomIds: [String]

    public var message: String {
        if created > 0 { return "Добавили чатов: \(created)" }
        return matched > 0 ? "Все знакомые уже в чатах" : "Знакомых из контактов пока нет"
    }
}

public enum PhoneBookSync {
    public static let limit = 500
    public static let concurrency = 4
    public static let greeting = "С вами в connect!"

    /// Номера в виде поиска Connect, без повторов, не больше 500.
    public static func normalize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for number in raw {
            guard result.count < limit, case let .phone(phone)? = ContactQuery(number), seen.insert(phone).inserted else { continue }
            result.append(phone)
        }
        return result
    }

    /// Ищет владельцев номеров и заводит личные чаты с теми, с кем чата ещё нет. Номера никуда не сохраняются.
    public static func run(numbers raw: [String], me: String, repository: any ContactsRepository) async -> PhoneBookSyncResult {
        let numbers = normalize(raw)
        guard !numbers.isEmpty else { return PhoneBookSyncResult(scanned: 0, matched: 0, created: 0, failed: 0, createdRoomIds: []) }

        let found: [Contact??] = await concurrentMap(numbers) { phone in
            do { return .some(try await repository.search(.phone(phone))) } catch { return .none }
        }
        var failed = found.filter { $0 == nil }.count
        var partners: [String] = []
        for case let .some(contact?) in found where contact.userId != me && !partners.contains(contact.userId) {
            partners.append(contact.userId)
        }

        let created: [String?] = await concurrentMap(partners) { partner in
            do {
                if try await repository.existingChat(userId: me, peerUserId: partner) != nil { return nil }
                return try await repository.createChat(userId: me, peerUserId: partner)
            } catch {
                return "failed"
            }
        }
        failed += created.filter { $0 == "failed" }.count
        let roomIds = created.compactMap { $0 }.filter { $0 != "failed" }
        return PhoneBookSyncResult(scanned: numbers.count, matched: partners.count, created: roomIds.count, failed: failed, createdRoomIds: roomIds)
    }

    static func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], _ transform: @escaping @Sendable (T) async -> R) async -> [R] {
        var results = [R?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, R).self) { group in
            var next = 0
            func add() {
                guard next < items.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await transform(items[index])) }
            }
            for _ in 0..<min(concurrency, items.count) { add() }
            while let (index, value) = await group.next() {
                results[index] = value
                add()
            }
        }
        return results.compactMap { $0 }
    }
}
