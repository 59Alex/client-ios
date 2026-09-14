import ConnectCore
import ConnectNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Смена статуса пользователя из `connect-status-service`.
public struct PresenceUpdate: Sendable, Equatable {
    public let userId: String
    public let status: UserStatus

    public init(userId: String, status: UserStatus) {
        self.userId = userId
        self.status = status
    }

    /// Кадр `data: {"userId","status"}`; остальное отбрасывается, как в `statusEvents.ts`.
    public static func decode(_ data: String) -> PresenceUpdate? {
        guard let object = try? JSONDecoder().decode(Frame.self, from: Data(data.utf8)),
              let status = UserStatus(rawValue: object.status) else { return nil }
        return PresenceUpdate(userId: object.userId, status: status)
    }

    private struct Frame: Decodable {
        let userId: String
        let status: String
    }
}

public protocol PresenceAPI: Sendable {
    /// Текущие статусы: `POST /api/status/snapshot` со списком id.
    func snapshot(userIds: [String]) async throws -> [PresenceUpdate]
    /// Живые изменения: `POST /api/status/events` (SSE) с тем же списком.
    func events(userIds: [String]) -> AsyncThrowingStream<PresenceUpdate, any Error>
}

public struct RemotePresenceAPI: PresenceAPI {
    private let client: HTTPClient
    private let eventStream: any EventStreamTransport

    public init(client: HTTPClient, eventStream: any EventStreamTransport) {
        self.client = client
        self.eventStream = eventStream
    }

    public func snapshot(userIds: [String]) async throws -> [PresenceUpdate] {
        let frames: [SnapshotItem] = try HTTPClient.decode(try await client.post("/api/status/snapshot", json: userIds))
        return frames.compactMap { item in UserStatus(rawValue: item.status).map { PresenceUpdate(userId: item.userId, status: $0) } }
    }

    public func events(userIds: [String]) -> AsyncThrowingStream<PresenceUpdate, any Error> {
        let client = client
        let transport = eventStream
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let token = await client.accessToken() else { throw APIError.unauthorized }
                    var request = URLRequest(url: HTTPClient.join(client.baseURL, "/api/status/events"))
                    request.httpMethod = "POST"
                    request.httpBody = try JSONEncoder().encode(userIds)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    for try await event in transport.events(for: request) {
                        if let update = PresenceUpdate.decode(event.data) { continuation.yield(update) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct SnapshotItem: Decodable {
        let userId: String
        let status: String
    }
}

/// Порядок списка контактов (`presence.ts`, ключ `connect.contacts.sort.v1`).
public enum ContactSort: String, Sendable, CaseIterable, Identifiable {
    case lastSeen
    case name

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lastSeen: "По времени захода"
        case .name: "По имени"
        }
    }
}
