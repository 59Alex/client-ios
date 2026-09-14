import ConnectNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Сессия устройства в `connect-status-service`. Звонки привязаны к `sessionId`:
/// когда сессия умирает, events-channel-service снимает участника её звонков.
public actor StatusService {
    /// Пульс чаще, чем веб-клиент подтверждает присутствие (20 с), чтобы сессия не истекала.
    public static let pulseInterval: Duration = .seconds(15)

    /// Пульс не нужен, пока сервер подтверждал сессию через heartbeat не дольше этого времени назад.
    public static let confirmationWindow: TimeInterval = 20

    private let client: HTTPClient
    private let eventStream: (any EventStreamTransport)?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private var sessionId: String?
    private var pendingLogin: Task<String?, Never>?
    private var lastConfirmation: Date?

    public init(
        client: HTTPClient,
        eventStream: (any EventStreamTransport)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.eventStream = eventStream
        self.sleep = sleep
        self.now = now
    }

    /// Идентификатор сессии; `nil`, если статус-сервис недоступен — звонки тогда работают без неё.
    public func currentSessionId(userId: String) async -> String? {
        if let sessionId { return sessionId }
        if let pendingLogin { return await pendingLogin.value }

        let client = client
        let task = Task<String?, Never> {
            let request = SessionRequest(userId: userId, sessionId: nil)
            guard let response = try? await client.postDecoded("/api/status/login", json: request, as: SessionResponse.self) else {
                return nil
            }
            return response.sessionId
        }
        pendingLogin = task
        let result = await task.value
        pendingLogin = nil
        sessionId = result
        return result
    }

    /// Держит сессию живой, пока задача не отменена: heartbeat-поток с подтверждениями,
    /// а пульс — только когда подтверждений давно не было (`status_api.ts`). Ошибки сети не прерывают циклы.
    public func keepAlive(userId: String) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.runHeartbeat(userId: userId) }
            group.addTask { await self.runPulse(userId: userId) }
        }
    }

    private func runPulse(userId: String) async {
        while !Task.isCancelled {
            if !isRecentlyConfirmed, let sessionId = await currentSessionId(userId: userId) {
                _ = try? await client.post("/api/status/heartbeat/pulse", json: SessionRequest(userId: userId, sessionId: sessionId))
            }
            do {
                try await sleep(Self.pulseInterval)
            } catch {
                return
            }
        }
    }

    private var isRecentlyConfirmed: Bool {
        guard let lastConfirmation else { return false }
        return now().timeIntervalSince(lastConfirmation) < Self.confirmationWindow
    }

    /// `POST /api/status/heartbeat/events`: на каждый `heartbeatId` уходит `ack`, «expired» пропускается.
    private func runHeartbeat(userId: String) async {
        guard let eventStream else { return }
        while !Task.isCancelled {
            if let sessionId = await currentSessionId(userId: userId), let token = await client.accessToken() {
                var request = URLRequest(url: HTTPClient.join(client.baseURL, "/api/status/heartbeat/events"))
                request.httpMethod = "POST"
                request.httpBody = try? JSONEncoder().encode(SessionRequest(userId: userId, sessionId: sessionId))
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                do {
                    for try await event in eventStream.events(for: request) {
                        guard let heartbeat = HeartbeatEvent.decode(event.data), heartbeat.heartbeatId != "expired" else { continue }
                        let ack = HeartbeatAck(userId: userId, sessionId: sessionId, heartbeatId: heartbeat.heartbeatId)
                        guard let response = try? await client.post("/api/status/heartbeat/ack", json: ack), response.isSuccess else { continue }
                        if heartbeat.expiresAt.map({ $0 > now() }) ?? true {
                            lastConfirmation = now()
                        }
                    }
                } catch {
                    // Переподключение ниже.
                }
            }
            do {
                try await sleep(.milliseconds(1500))
            } catch {
                return
            }
        }
    }

    /// Закрывает сессию при выходе из аккаунта.
    public func logout(userId: String) async {
        guard let sessionId else { return }
        self.sessionId = nil
        _ = try? await client.post("/api/status/unlogin", json: SessionRequest(userId: userId, sessionId: sessionId))
    }
}

private struct SessionRequest: Encodable, Sendable {
    let userId: String
    let sessionId: String?
}

private struct SessionResponse: Decodable, Sendable {
    let sessionId: String?
}

struct HeartbeatEvent: Sendable, Equatable {
    let heartbeatId: String
    let expiresAt: Date?

    static func decode(_ data: String) -> HeartbeatEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let id = object["heartbeatId"] as? String, !id.isEmpty else { return nil }
        let expires = (object["expiresAt"] as? String).flatMap { value -> Date? in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        return HeartbeatEvent(heartbeatId: id, expiresAt: expires)
    }
}

private struct HeartbeatAck: Encodable, Sendable {
    let userId: String
    let sessionId: String
    let heartbeatId: String
}
