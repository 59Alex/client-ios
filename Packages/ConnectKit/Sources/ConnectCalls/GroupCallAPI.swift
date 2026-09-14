import ConnectNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Событие групповых звонков: общий поток пользователя и поток конкретного звонка.
public struct GroupCallEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case call = "CALL"
        case cancel = "CANCEL"
        case finish = "FINISH"
        case join = "JOIN"
        case hangup = "HANGUP"
    }

    public var kind: Kind
    public var groupCallId: String
    public var callerUserId: String?
    public var calleeUserId: String?
    public var participantUserId: String?
    public var groupChatId: String?

    public init(kind: Kind, groupCallId: String, callerUserId: String? = nil, calleeUserId: String? = nil, participantUserId: String? = nil, groupChatId: String? = nil) {
        self.kind = kind
        self.groupCallId = groupCallId
        self.callerUserId = callerUserId
        self.calleeUserId = calleeUserId
        self.participantUserId = participantUserId
        self.groupChatId = groupChatId
    }

    public static func decode(_ data: String) -> GroupCallEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
            let kind = (object["type"] as? String).flatMap(Kind.init(rawValue:)),
            let callId = object["groupCallId"] as? String ?? object["group_call_id"] as? String
        else { return nil }
        func string(_ keys: String...) -> String? { keys.lazy.compactMap { object[$0] as? String }.first }
        return GroupCallEvent(
            kind: kind,
            groupCallId: callId,
            callerUserId: string("callerUserId", "caller_user_id"),
            calleeUserId: string("calleeUserId", "callee_user_id"),
            participantUserId: string("participantUserId", "participant_user_id"),
            groupChatId: string("groupChatId", "group_chat_id")
        )
    }
}

/// Групповой звонок из outbox: состав участников и вызванных.
public struct GroupCallRecord: Sendable, Equatable {
    public struct Callee: Sendable, Equatable {
        public var userId: String
        public var canceled: Bool

        public init(userId: String, canceled: Bool) {
            self.userId = userId
            self.canceled = canceled
        }
    }

    public var id: String
    public var callerUserId: String
    public var groupChatId: String
    public var name: String
    public var startedAt: Date?
    public var participantUserIds: [String]
    public var participantSessions: [(userId: String, sessionId: String?)]
    public var callees: [Callee]

    public static func == (lhs: GroupCallRecord, rhs: GroupCallRecord) -> Bool {
        lhs.id == rhs.id && lhs.participantUserIds == rhs.participantUserIds && lhs.callees == rhs.callees && lhs.name == rhs.name
    }

    public init(id: String, callerUserId: String, groupChatId: String, name: String = "", startedAt: Date? = nil, participants: [(userId: String, sessionId: String?)] = [], callees: [Callee] = []) {
        self.id = id
        self.callerUserId = callerUserId
        self.groupChatId = groupChatId
        self.name = name
        self.startedAt = startedAt
        participantSessions = participants
        var seen = Set<String>()
        participantUserIds = participants.map(\.userId).filter { seen.insert($0).inserted }
        self.callees = callees
    }

    /// Разбор с синонимами полей (`types/calls/group.ts`).
    public static func decode(_ any: Any) -> GroupCallRecord? {
        guard let object = any as? [String: Any] else { return nil }
        func string(_ keys: String...) -> String? { keys.lazy.compactMap { object[$0] as? String }.first }
        guard
            let id = string("id", "groupCallId", "group_call_id"),
            let caller = string("callerUserId", "caller_user_id"),
            let chat = string("groupChatId", "group_chat_id")
        else { return nil }

        let rawParticipants = ["participants", "groupCallParticipants", "group_call_participants"].lazy.compactMap { object[$0] as? [Any] }.first ?? []
        let participants: [(userId: String, sessionId: String?)] = rawParticipants.compactMap { item in
            if let id = item as? String { return (id, nil) }
            guard let entry = item as? [String: Any] else { return nil }
            guard let userId = (entry["participantUserId"] ?? entry["userId"] ?? entry["user_id"] ?? entry["participant_user_id"]) as? String else { return nil }
            return (userId, (entry["sessionId"] ?? entry["session_id"]) as? String)
        }
        let rawCallees = ["callees", "groupCallCallee", "group_call_callee", "callee"].lazy.compactMap { object[$0] as? [Any] }.first ?? []
        let callees: [Callee] = rawCallees.compactMap { item in
            if let id = item as? String { return Callee(userId: id, canceled: false) }
            guard let entry = item as? [String: Any], let userId = (entry["calleeUserId"] ?? entry["callee_user_id"] ?? entry["userId"]) as? String else { return nil }
            return Callee(userId: userId, canceled: entry["canceled"] as? Bool ?? false)
        }
        var startedAt: Date?
        if let number = object["timestamp"] as? NSNumber {
            startedAt = Date(timeIntervalSince1970: number.doubleValue / 1000)
        } else if let text = object["timestamp"] as? String, let number = Double(text) {
            startedAt = Date(timeIntervalSince1970: number / 1000)
        }
        return GroupCallRecord(id: id, callerUserId: caller, groupChatId: chat, name: string("name") ?? "", startedAt: startedAt, participants: participants, callees: callees)
    }

    public func pendingCallees(excluding me: String) -> [String] {
        callees.filter { !$0.canceled && $0.userId != me }.map(\.userId)
    }

    public func declinedCallees(excluding me: String) -> [String] {
        callees.filter { $0.canceled && $0.userId != me }.map(\.userId)
    }
}

public protocol GroupCallAPI: Sendable {
    func createCall(callerUserId: String, groupChatId: String, name: String, calleeUserIds: [String], sessionId: String?) async throws -> String
    func join(callId: String, userId: String, sessionId: String?) async throws
    func leave(callId: String, userId: String, sessionId: String?) async throws
    func deleteCall(callId: String, sessionId: String?) async throws
    func decline(callId: String, userId: String, sessionId: String?) async throws
    func call(id: String) async throws -> GroupCallRecord?
    func incomingCall(calleeUserId: String) async throws -> GroupCallRecord?
    func activeCall(groupChatId: String) async throws -> GroupCallRecord?
    func token(userId: String, groupChatId: String, callId: String) async throws -> String
    func events(userId: String) -> AsyncThrowingStream<GroupCallEvent, any Error>
    func callEvents(callId: String) -> AsyncThrowingStream<GroupCallEvent, any Error>
}

/// Ошибка групповых звонков: 409 на создание или вход — пользователь уже в другом звонке.
public enum GroupCallAPIError: Error, Sendable, Equatable {
    case busy
    case missingCallId
}

public struct RemoteGroupCallAPI: GroupCallAPI {
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

    public func createCall(callerUserId: String, groupChatId: String, name: String, calleeUserIds: [String], sessionId: String?) async throws -> String {
        let body = CreateGroupCall(callerUserId: callerUserId, groupChatId: groupChatId, name: name, calleeUserIds: calleeUserIds, timestamp: Int64(Date().timeIntervalSince1970 * 1000), sessionId: sessionId)
        let response = try await events.post("/api/groupcall/create", json: body, headers: ["X-Idempotence-Id": body.idempotenceId])
        if response.statusCode == 409 { throw GroupCallAPIError.busy }
        try HTTPClient.requireSuccess(response)
        guard let id = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["id"] as? String else {
            throw GroupCallAPIError.missingCallId
        }
        return id
    }

    public func join(callId: String, userId: String, sessionId: String?) async throws {
        let body = ParticipantCommand(groupCallId: callId, participantUserId: userId, sessionId: sessionId)
        let response = try await events.post("/api/groupcall/join", json: body, headers: ["X-Idempotence-Id": body.idempotenceId])
        if response.statusCode == 409 { throw GroupCallAPIError.busy }
        try HTTPClient.requireSuccess(response)
    }

    public func leave(callId: String, userId: String, sessionId: String?) async throws {
        let body = ParticipantCommand(groupCallId: callId, participantUserId: userId, sessionId: sessionId)
        try HTTPClient.requireSuccess(try await events.post("/api/groupcall/disconnect/participant", json: body, headers: ["X-Idempotence-Id": body.idempotenceId]))
    }

    public func deleteCall(callId: String, sessionId: String?) async throws {
        let body = CallCommand(groupCallId: callId, sessionId: sessionId)
        try HTTPClient.requireSuccess(try await events.delete("/api/groupcall/delete", json: body, headers: ["X-Idempotence-Id": body.idempotenceId]))
    }

    public func decline(callId: String, userId: String, sessionId: String?) async throws {
        let body = CalleeCommand(groupCallId: callId, calleeUserId: userId, sessionId: sessionId)
        try HTTPClient.requireSuccess(try await events.delete("/api/groupcall/delete/callee", json: body, headers: ["X-Idempotence-Id": body.idempotenceId]))
    }

    public func call(id: String) async throws -> GroupCallRecord? {
        try await record(outbox.get("/api/groupcall/\(Self.path(id))"))
    }

    public func incomingCall(calleeUserId: String) async throws -> GroupCallRecord? {
        try await record(outbox.get("/api/groupcall/find/by/callee?callee_id=\(Self.path(calleeUserId))"))
    }

    public func activeCall(groupChatId: String) async throws -> GroupCallRecord? {
        try await record(outbox.get("/api/groupcall/find/by/group/chat?group_chat_id=\(Self.path(groupChatId))"))
    }

    public func token(userId: String, groupChatId: String, callId: String) async throws -> String {
        let scoped = try await main.post("/api/group-room/get-token", json: GroupTokenRequest(userId: userId, roomId: groupChatId, groupCallId: callId))
        // Старые сервисы не знают groupCallId: веб повторяет запрос без него только на 404.
        let response = scoped.statusCode == 404
            ? try await main.post("/api/group-room/get-token", json: GroupTokenRequest(userId: userId, roomId: groupChatId, groupCallId: nil))
            : scoped
        return try HTTPClient.decode(response, as: TokenBody.self).openviduConnectionUri
    }

    public func events(userId: String) -> AsyncThrowingStream<GroupCallEvent, any Error> {
        stream(path: "/api/event/group-call/events?userId=\(Self.path(userId))")
    }

    public func callEvents(callId: String) -> AsyncThrowingStream<GroupCallEvent, any Error> {
        stream(path: "/api/event/group-call/events/by-call?groupCallId=\(Self.path(callId))")
    }

    private func record(_ response: HTTPResponse) throws -> GroupCallRecord? {
        if response.statusCode == 404 { return nil }
        try HTTPClient.requireSuccess(response)
        guard let json = try? JSONSerialization.jsonObject(with: response.body) else { return nil }
        if let array = json as? [Any] { return array.first.flatMap(GroupCallRecord.decode) }
        return GroupCallRecord.decode(json)
    }

    private func stream(path: String) -> AsyncThrowingStream<GroupCallEvent, any Error> {
        let events = events
        let transport = eventStream
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let token = await events.accessToken() else { throw APIError.unauthorized }
                    let url = HTTPClient.join(events.baseURL, "\(path)&access_token=\(Self.path(token))")
                    for try await event in transport.events(for: URLRequest(url: url)) {
                        if let decoded = GroupCallEvent.decode(event.data) { continuation.yield(decoded) }
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
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? value
    }
}

private struct CreateGroupCall: Encodable, Sendable {
    let callerUserId: String
    let groupChatId: String
    let name: String
    let calleeUserIds: [String]
    let timestamp: Int64
    let sessionId: String?
    var eventId = UUID().uuidString.lowercased()
    var idempotenceId = UUID().uuidString.lowercased()
}

private struct ParticipantCommand: Encodable, Sendable {
    let groupCallId: String
    let participantUserId: String
    let sessionId: String?
    var eventId = UUID().uuidString.lowercased()
    var idempotenceId = UUID().uuidString.lowercased()
}

private struct CallCommand: Encodable, Sendable {
    let groupCallId: String
    let sessionId: String?
    var eventId = UUID().uuidString.lowercased()
    var idempotenceId = UUID().uuidString.lowercased()
}

private struct CalleeCommand: Encodable, Sendable {
    let groupCallId: String
    let calleeUserId: String
    let sessionId: String?
    var eventId = UUID().uuidString.lowercased()
    var idempotenceId = UUID().uuidString.lowercased()
}

private struct GroupTokenRequest: Encodable, Sendable {
    let userId: String
    let roomId: String
    let groupCallId: String?
}

private struct TokenBody: Decodable {
    let openviduConnectionUri: String
}
