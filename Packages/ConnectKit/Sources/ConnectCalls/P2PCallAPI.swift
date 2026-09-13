import ConnectCore
import ConnectNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum P2PCallAPIError: Error, Sendable, Equatable {
    /// 409 на создание звонка: собеседник уже разговаривает.
    case busy
    case missingCallId
}

/// Событие SSE `GET /api/event/p2p/events`.
public enum P2PCallEvent: Sendable, Equatable {
    case call(callId: String?, callerUserId: String, calleeUserId: String)
    case cancel(callId: String?, callerUserId: String, calleeUserId: String)

    public static func decode(_ data: String) -> P2PCallEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return nil }
        let callId = ["id", "p2pCallId", "p2p_call_id"].lazy.compactMap { object[$0] as? String }.first
        guard
            let caller = object["callerUserId"] as? String,
            let callee = object["calleeUserId"] as? String
        else { return nil }
        switch object["type"] as? String {
        case "CALL": return .call(callId: callId, callerUserId: caller, calleeUserId: callee)
        case "CANCEL": return .cancel(callId: callId, callerUserId: caller, calleeUserId: callee)
        default: return nil
        }
    }
}

/// Сервисы личного звонка: комнаты и токены в `connect`, команды в events-channel-service,
/// чтение в events-channel-outbox.
public protocol P2PCallAPI: Sendable {
    func roomId(userId: String, peerUserId: String) async throws -> String
    func connectionToken(userId: String, roomId: String) async throws -> String
    func createCall(callerUserId: String, calleeUserId: String, sessionId: String?) async throws -> String
    func deleteCall(callerUserId: String, calleeUserId: String, callId: String, sessionId: String?) async throws
    func setCallTime(callId: String, time: Date, sessionId: String?) async throws
    func callTime(callId: String) async throws -> Date?
    func incomingCall(calleeUserId: String) async throws -> P2PCallEvent?
    func contact(userId: String) async throws -> Contact
    func events(userId: String) -> AsyncThrowingStream<P2PCallEvent, any Error>
}

public struct RemoteP2PCallAPI: P2PCallAPI {
    private let main: HTTPClient
    private let events: HTTPClient
    private let outbox: HTTPClient
    private let eventStream: any EventStreamTransport

    public init(main: HTTPClient, events: HTTPClient, outbox: HTTPClient, eventStream: any EventStreamTransport) {
        self.main = main
        self.events = events
        self.outbox = outbox
        self.eventStream = eventStream
    }

    public func roomId(userId: String, peerUserId: String) async throws -> String {
        let response = try await main.get("/api/p2p-room/get-by-users/\(Self.path(userId))/\(Self.path(peerUserId))")
        if response.statusCode != 404 {
            return try HTTPClient.decode(response, as: IdResponse.self).id
        }
        let body = CreateRoomRequest(creator: .init(userId: userId), companion: .init(userId: peerUserId))
        return try await main.postDecoded("/api/p2p-room/create", json: body, as: IdResponse.self).id
    }

    public func connectionToken(userId: String, roomId: String) async throws -> String {
        try await main.postDecoded("/api/p2p-room/get-token", json: TokenRequest(userId: userId, roomId: roomId), as: TokenResponse.self)
            .openviduConnectionUri
    }

    public func createCall(callerUserId: String, calleeUserId: String, sessionId: String?) async throws -> String {
        let command = ChannelCommand(callerUserId: callerUserId, calleeUserId: calleeUserId, sessionId: sessionId)
        let response = try await events.post("/api/p2pcall/create", json: command, headers: command.headers)
        if response.statusCode == 409 { throw P2PCallAPIError.busy }
        guard let id = try HTTPClient.decode(response, as: OptionalIdResponse.self).id else {
            throw P2PCallAPIError.missingCallId
        }
        return id
    }

    public func deleteCall(callerUserId: String, calleeUserId: String, callId: String, sessionId: String?) async throws {
        let command = ChannelCommand(callerUserId: callerUserId, calleeUserId: calleeUserId, p2pCallId: callId, sessionId: sessionId)
        try HTTPClient.requireSuccess(try await events.delete("/api/p2pcall/delete", json: command, headers: command.headers))
    }

    public func setCallTime(callId: String, time: Date, sessionId: String?) async throws {
        let command = ChannelCommand(p2pCallId: callId, callTime: Int64(time.timeIntervalSince1970 * 1000), sessionId: sessionId)
        try HTTPClient.requireSuccess(try await events.post("/api/p2pcall/call-time", json: command, headers: command.headers))
    }

    public func callTime(callId: String) async throws -> Date? {
        let response = try await outbox.get("/api/p2pcall/call-time?p2p_call_id=\(Self.query(callId))")
        if response.statusCode == 404 { return nil }
        guard let milliseconds = try HTTPClient.decode(response, as: CallTimeResponse.self).callTime else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    public func incomingCall(calleeUserId: String) async throws -> P2PCallEvent? {
        let response = try await outbox.get("/api/p2pcall/find/by/callee?callee_id=\(Self.query(calleeUserId))")
        if response.statusCode == 404 { return nil }
        let call = try HTTPClient.decode(response, as: StoredCall.self)
        return .call(callId: call.id, callerUserId: call.callerUserId, calleeUserId: call.calleeUserId)
    }

    public func contact(userId: String) async throws -> Contact {
        try await main.getDecoded("/api/user-card/get-fast-info-by-user-id/\(Self.path(userId))")
    }

    public func events(userId: String) -> AsyncThrowingStream<P2PCallEvent, any Error> {
        let events = events
        let transport = eventStream
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // SSE авторизуется параметром access_token, как EventSource веб-клиента.
                    guard let token = await events.accessToken() else { throw APIError.unauthorized }
                    let url = HTTPClient.join(events.baseURL, "/api/event/p2p/events?userId=\(Self.query(userId))&access_token=\(Self.query(token))")
                    for try await event in transport.events(for: URLRequest(url: url)) {
                        if let decoded = P2PCallEvent.decode(event.data) {
                            continuation.yield(decoded)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func path(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    static func query(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? value
    }
}

/// Команда events-channel-service с метаданными идемпотентности (`channel_event_metadata.ts`).
struct ChannelCommand: Encodable, Sendable {
    var callerUserId: String?
    var calleeUserId: String?
    var p2pCallId: String?
    var callTime: Int64?
    var sessionId: String?
    var eventId = UUID().uuidString.lowercased()
    var idempotenceId = UUID().uuidString.lowercased()

    var headers: [String: String] { ["X-Idempotence-Id": idempotenceId] }
}

private struct IdResponse: Decodable {
    let id: String
}

private struct OptionalIdResponse: Decodable {
    let id: String?
}

private struct CreateRoomRequest: Encodable, Sendable {
    struct Member: Encodable, Sendable {
        let userId: String
    }

    let creator: Member
    let companion: Member
}

private struct TokenRequest: Encodable, Sendable {
    let userId: String
    let roomId: String
}

private struct TokenResponse: Decodable {
    let openviduConnectionUri: String
}

private struct CallTimeResponse: Decodable {
    let callTime: Double?
}

private struct StoredCall: Decodable {
    let id: String
    let callerUserId: String
    let calleeUserId: String
}
