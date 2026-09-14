import ConnectCalls
import Foundation

/// Групповые звонки в памяти для тестов и офлайн-стаба.
public actor FakeGroupCallAPI: GroupCallAPI {
    public private(set) var records: [String: GroupCallRecord]
    public private(set) var created: [(chat: String, callees: [String])] = []
    public private(set) var joined: [String] = []
    public private(set) var left: [String] = []
    public private(set) var deleted: [String] = []
    public private(set) var declined: [String] = []
    public var busy = false
    public var joinConflicts = 0
    private var counter = 0
    private var userContinuations: [AsyncThrowingStream<GroupCallEvent, any Error>.Continuation] = []
    private var callContinuations: [String: [AsyncThrowingStream<GroupCallEvent, any Error>.Continuation]] = [:]
    public var pendingIncoming: GroupCallRecord?

    public init(records: [GroupCallRecord] = [], pendingIncoming: GroupCallRecord? = nil) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        self.pendingIncoming = pendingIncoming
    }

    public func setBusy(_ value: Bool) { busy = value }
    public func setJoinConflicts(_ value: Int) { joinConflicts = value }

    public func createCall(callerUserId: String, groupChatId: String, name: String, calleeUserIds: [String], sessionId: String?) async throws -> String {
        if busy { throw GroupCallAPIError.busy }
        counter += 1
        let id = "group-call-\(counter)"
        created.append((groupChatId, calleeUserIds))
        records[id] = GroupCallRecord(id: id, callerUserId: callerUserId, groupChatId: groupChatId, name: name, participants: [(callerUserId, sessionId)], callees: calleeUserIds.map { .init(userId: $0, canceled: false) })
        return id
    }

    public func join(callId: String, userId: String, sessionId: String?) async throws {
        if joinConflicts > 0 {
            joinConflicts -= 1
            throw GroupCallAPIError.busy
        }
        joined.append(callId)
    }

    public func leave(callId: String, userId: String, sessionId: String?) async throws { left.append(callId) }
    public func deleteCall(callId: String, sessionId: String?) async throws { deleted.append(callId) }
    public func decline(callId: String, userId: String, sessionId: String?) async throws { declined.append(callId) }
    public func call(id: String) async throws -> GroupCallRecord? { records[id] }
    public func incomingCall(calleeUserId: String) async throws -> GroupCallRecord? { pendingIncoming }
    public func activeCall(groupChatId: String) async throws -> GroupCallRecord? { records.values.first { $0.groupChatId == groupChatId } }
    public func token(userId: String, groupChatId: String, callId: String) async throws -> String { "group-token-\(callId)" }

    public nonisolated func events(userId: String) -> AsyncThrowingStream<GroupCallEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<GroupCallEvent, any Error>.makeStream()
        Task { await self.registerUser(continuation) }
        return stream
    }

    public nonisolated func callEvents(callId: String) -> AsyncThrowingStream<GroupCallEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<GroupCallEvent, any Error>.makeStream()
        Task { await self.registerCall(callId, continuation) }
        return stream
    }

    public func pushCallEvent(_ event: GroupCallEvent) {
        if event.kind == .cancel, let callee = event.calleeUserId, var record = records[event.groupCallId],
           let index = record.callees.firstIndex(where: { $0.userId == callee }) {
            record.callees[index].canceled = true
            records[event.groupCallId] = record
        }
        callContinuations[event.groupCallId]?.forEach { $0.yield(event) }
    }

    public func hasCallSubscriber(_ callId: String) -> Bool { !(callContinuations[callId] ?? []).isEmpty }

    private func registerUser(_ continuation: AsyncThrowingStream<GroupCallEvent, any Error>.Continuation) {
        userContinuations.append(continuation)
    }

    private func registerCall(_ callId: String, _ continuation: AsyncThrowingStream<GroupCallEvent, any Error>.Continuation) {
        callContinuations[callId, default: []].append(continuation)
    }
}

/// Голосовые каналы в памяти.
public actor FakeRoomVoiceAPI: RoomVoiceAPI {
    public private(set) var calls: [String] = []
    public private(set) var connected: [ChannelParticipantEvent]
    private var continuations: [AsyncThrowingStream<ChannelParticipantEvent, any Error>.Continuation] = []

    public init(connected: [ChannelParticipantEvent] = []) {
        self.connected = connected
    }

    public func token(userId: String, channelId: String) async throws -> String {
        calls.append("token")
        return "voice-token-\(channelId)"
    }

    public func joinChannel(channelId: String, userId: String, muted: Bool, speakerOff: Bool, sessionId: String?) async throws {
        calls.append("create")
    }

    public func setMuted(_ muted: Bool, channelId: String, userId: String, sessionId: String?) async throws {
        calls.append("muted:\(muted)")
    }

    public func setSpeakerOff(_ off: Bool, channelId: String, userId: String, sessionId: String?) async throws {
        calls.append("speakeroff:\(off)")
    }

    public func leaveChannel(channelId: String, userId: String, sessionId: String?) async throws {
        calls.append("delete")
    }

    public func connectedParticipants(channelIds: [String]) async throws -> [ChannelParticipantEvent] {
        connected.filter { channelIds.contains($0.channelId) }
    }

    public nonisolated func participantEvents(channelIds: [String], subscriber: String) -> AsyncThrowingStream<ChannelParticipantEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ChannelParticipantEvent, any Error>.makeStream()
        Task { await self.register(continuation) }
        return stream
    }

    public func push(_ event: ChannelParticipantEvent) {
        continuations.forEach { $0.yield(event) }
    }

    private func register(_ continuation: AsyncThrowingStream<ChannelParticipantEvent, any Error>.Continuation) {
        continuations.append(continuation)
    }
}
