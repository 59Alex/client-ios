import ConnectCore
import ConnectFeatures
import ConnectFiles
import Foundation

/// Файлы в памяти: загрузка сохраняет данные, пакетное скачивание отдаёт известные адреса.
public actor FakeFileAPI: FileAPI {
    public private(set) var stored: [String: Data]
    public private(set) var downloadRequests: [[String]] = []
    public private(set) var deletedUrls: [String] = []
    public var failUpload = false
    private var counter = 0

    public init(files: [String: Data] = [:]) {
        stored = files
    }

    public func setFailUpload(_ value: Bool) { failUpload = value }

    public func download(urls: [String]) async throws -> [String: DownloadedFile] {
        downloadRequests.append(urls)
        var result: [String: DownloadedFile] = [:]
        for url in urls {
            if let data = stored[url] {
                result[url] = DownloadedFile(urlS3: url, contentType: "application/octet-stream", data: data)
            }
        }
        return result
    }

    public func upload(data: Data, filename: String, mimeType: String, bucket: FileBucket, key: String, userId: String, username: String) async throws -> UploadedFile {
        if failUpload { throw URLError(.notConnectedToInternet) }
        counter += 1
        let parts = UploadedFile.split(filename: filename)
        let url = "\(bucket.rawValue)/\(key)/\(counter)\(parts.extension)"
        stored[url] = data
        return UploadedFile(urlS3: url, name: parts.name, extension: parts.extension)
    }

    public func delete(urls: [String]) async throws {
        deletedUrls.append(contentsOf: urls)
        urls.forEach { stored[$0] = nil }
    }
}

/// Контакты в памяти для тестов и офлайн-стаба.
public actor FakeContactsRepository: ContactsRepository {
    public private(set) var contactsByUser: [String: [Contact]]
    public private(set) var directory: [Contact]
    public private(set) var blocked: Set<String> = []
    public private(set) var openedChats: [String] = []

    public init(contacts: [String: [Contact]] = [:], directory: [Contact] = []) {
        contactsByUser = contacts
        self.directory = directory
    }

    public func contacts(of userId: String) async throws -> [Contact] {
        contactsByUser[userId] ?? []
    }

    public func search(_ query: ContactQuery) async throws -> Contact? {
        switch query {
        case let .login(login):
            let normalized = login.drop { $0 == "@" }.lowercased()
            return directory.first { $0.username.drop { $0 == "@" }.lowercased() == normalized }
        case .phone:
            return nil
        }
    }

    public func addContact(userId: String, contactUserId: String) async throws {
        guard let contact = directory.first(where: { $0.userId == contactUserId }) else { return }
        contactsByUser[userId, default: []].append(contact)
    }

    public func removeContact(contactUserId: String) async throws {
        for key in contactsByUser.keys {
            contactsByUser[key]?.removeAll { $0.userId == contactUserId }
        }
    }

    public func profile(userId: String) async throws -> Contact {
        guard let contact = directory.first(where: { $0.userId == userId }) else { throw URLError(.fileDoesNotExist) }
        return contact
    }

    public func openChat(myUsername: String, companionUsername: String) async throws -> String {
        openedChats.append(companionUsername)
        return "room-\(companionUsername.drop { $0 == "@" })"
    }

    public func isBlocked(userId: String, contactUserId: String) async throws -> Bool {
        blocked.contains(contactUserId)
    }

    public func setBlocked(_ value: Bool, userId: String, contactUserId: String) async throws {
        if value { blocked.insert(contactUserId) } else { blocked.remove(contactUserId) }
    }
}

/// Статусы пользователей в памяти: снимок и управляемый живой поток.
public actor FakePresenceAPI: PresenceAPI {
    public var snapshotValue: [PresenceUpdate]
    public private(set) var subscriptions: [[String]] = []
    private var continuations: [AsyncThrowingStream<PresenceUpdate, any Error>.Continuation] = []

    public init(snapshot: [PresenceUpdate] = []) {
        snapshotValue = snapshot
    }

    public func snapshot(userIds: [String]) async throws -> [PresenceUpdate] {
        snapshotValue.filter { userIds.contains($0.userId) }
    }

    public nonisolated func events(userIds: [String]) -> AsyncThrowingStream<PresenceUpdate, any Error> {
        let (stream, continuation) = AsyncThrowingStream<PresenceUpdate, any Error>.makeStream()
        Task { await self.register(userIds, continuation) }
        return stream
    }

    public func push(_ update: PresenceUpdate) {
        continuations.forEach { $0.yield(update) }
    }

    public func hasSubscriber() -> Bool { !continuations.isEmpty }

    private func register(_ userIds: [String], _ continuation: AsyncThrowingStream<PresenceUpdate, any Error>.Continuation) {
        subscriptions.append(userIds)
        continuations.append(continuation)
    }
}
