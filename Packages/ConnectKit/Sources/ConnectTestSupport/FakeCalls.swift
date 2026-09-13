import ConnectCalls
import ConnectCore
import Foundation

/// Комната без WebRTC: записывает действия и отдаёт события, заданные тестом.
@MainActor
public final class FakeCallRoom: CallRoom {
    public let events: AsyncStream<CallRoomEvent>
    private let continuation: AsyncStream<CallRoomEvent>.Continuation

    public private(set) var connectedUrl: URL?
    public private(set) var token: String?
    public private(set) var publishedTrackName: String?
    public private(set) var microphoneMuted: Bool?
    public private(set) var speakerOutput: Bool?
    public private(set) var sentPackets: [SignalPacket] = []
    public private(set) var isDisconnected = false
    public var connectError: (any Error)?
    /// Вызывается после публикации микрофона — например, чтобы «впустить» собеседника.
    public var onPublish: (@MainActor (FakeCallRoom) -> Void)?

    public init() {
        (events, continuation) = AsyncStream<CallRoomEvent>.makeStream()
    }

    public func connect(url: URL, token: String) async throws {
        if let connectError { throw connectError }
        connectedUrl = url
        self.token = token
    }

    public func publishMicrophone(trackName: String, muted: Bool) async throws {
        publishedTrackName = trackName
        microphoneMuted = muted
        onPublish?(self)
    }

    public func setMicrophoneMuted(_ muted: Bool) async throws {
        microphoneMuted = muted
    }

    public func setSpeakerOutput(_ enabled: Bool) {
        speakerOutput = enabled
    }

    public func send(_ packet: Data, topic: String) async throws {
        if let decoded = SignalPacket.decode(packet) {
            sentPackets.append(decoded)
        }
    }

    public func disconnect() async {
        isDisconnected = true
        continuation.finish()
    }

    public func emit(_ event: CallRoomEvent) {
        continuation.yield(event)
    }

    /// Собеседник публикует аудиопоток по протоколу Connect.
    public func emitRemoteAudio(userId: String, participant: String = "peer#1", trackId: String = "TR_peer_audio", key: String = "peer-stream") {
        let name = TrackName(
            key: key,
            clientData: CallClientData(userId: userId, username: nil, sessionId: nil).encoded(),
            createdAtMilliseconds: 0,
            hasAudio: true,
            hasVideo: false
        )
        emit(.trackPublished(participant: participant, trackId: trackId, name: name.encoded(), kind: .audio))
    }
}

/// API звонков в памяти для тестов и офлайн-стаба приложения.
public actor FakeP2PCallAPI: P2PCallAPI {
    public private(set) var createdCalls: [(caller: String, callee: String)] = []
    public private(set) var deletedCallIds: [String] = []
    public private(set) var callTimes: [String: Date] = [:]
    public var busy = false
    public var nextCallId = "call-1"
    public var storedCallTime: Date?
    public var pendingIncoming: P2PCallEvent?
    public var contacts: [String: Contact] = [:]

    private var eventContinuations: [AsyncThrowingStream<P2PCallEvent, any Error>.Continuation] = []

    public init(contacts: [Contact] = []) {
        self.contacts = Dictionary(uniqueKeysWithValues: contacts.map { ($0.userId, $0) })
    }

    public func setBusy(_ value: Bool) { busy = value }
    public func setStoredCallTime(_ value: Date?) { storedCallTime = value }
    public func setPendingIncoming(_ value: P2PCallEvent?) { pendingIncoming = value }

    public func roomId(userId: String, peerUserId: String) async throws -> String {
        "room-\([userId, peerUserId].sorted().joined(separator: "-"))"
    }

    public func connectionToken(userId: String, roomId: String) async throws -> String {
        "token-\(roomId)"
    }

    public func createCall(callerUserId: String, calleeUserId: String, sessionId: String?) async throws -> String {
        if busy { throw P2PCallAPIError.busy }
        createdCalls.append((callerUserId, calleeUserId))
        return nextCallId
    }

    public func deleteCall(callerUserId: String, calleeUserId: String, callId: String, sessionId: String?) async throws {
        deletedCallIds.append(callId)
    }

    public func setCallTime(callId: String, time: Date, sessionId: String?) async throws {
        callTimes[callId] = time
    }

    public func callTime(callId: String) async throws -> Date? {
        storedCallTime
    }

    public func incomingCall(calleeUserId: String) async throws -> P2PCallEvent? {
        pendingIncoming
    }

    public func contact(userId: String) async throws -> Contact {
        contacts[userId] ?? Contact(userId: userId, name: "", username: userId)
    }

    public nonisolated func events(userId: String) -> AsyncThrowingStream<P2PCallEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<P2PCallEvent, any Error>.makeStream()
        Task { await self.register(continuation) }
        return stream
    }

    public func push(_ event: P2PCallEvent) {
        for continuation in eventContinuations {
            continuation.yield(event)
        }
    }

    private func register(_ continuation: AsyncThrowingStream<P2PCallEvent, any Error>.Continuation) {
        eventContinuations.append(continuation)
    }
}
