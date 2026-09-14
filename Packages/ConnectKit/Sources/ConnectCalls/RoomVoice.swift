import ConnectNetworking
import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Участник голосового канала по данным events-channel (`RoomParticipantEvent`).
public struct ChannelParticipantEvent: Decodable, Sendable, Equatable {
    public enum Kind: String, Decodable, Sendable {
        case connect = "CONNECT"
        case disconnect = "DISCONNECT"
        case mute = "MUTE"
        case speakerOff = "SPEAKER_OFF"
        case streamOn = "STREAM_ON"
    }

    public var userId: String
    public var channelId: String
    public var muted: Bool
    public var speakerOff: Bool
    public var streamOn: Bool
    public var kind: Kind

    public init(userId: String, channelId: String, muted: Bool = false, speakerOff: Bool = false, streamOn: Bool = false, kind: Kind) {
        self.userId = userId
        self.channelId = channelId
        self.muted = muted
        self.speakerOff = speakerOff
        self.streamOn = streamOn
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case userId, channelId, muted, speakerOff, streamOn, type }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        channelId = try container.decode(String.self, forKey: .channelId)
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        speakerOff = try container.decodeIfPresent(Bool.self, forKey: .speakerOff) ?? false
        streamOn = try container.decodeIfPresent(Bool.self, forKey: .streamOn) ?? false
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .type)) ?? .connect
    }
}

/// Кто сидит в голосовых каналах: слияние снимка и событий как в `useRoomParticipantEvents.ts`.
public struct ChannelPresence: Sendable, Equatable {
    public private(set) var byKey: [String: ChannelParticipantEvent] = [:]

    public init() {}

    public mutating func apply(_ event: ChannelParticipantEvent) {
        let key = "\(event.channelId):\(event.userId)"
        switch event.kind {
        case .disconnect:
            byKey[key] = nil
        case .mute:
            var current = byKey[key] ?? event
            current.muted = event.muted
            current.kind = .mute
            byKey[key] = current
        case .speakerOff:
            var current = byKey[key] ?? event
            current.speakerOff = event.speakerOff
            byKey[key] = current
        case .streamOn:
            var current = byKey[key] ?? event
            current.streamOn = event.streamOn
            byKey[key] = current
        case .connect:
            byKey[key] = event
        }
    }

    public func participants(in channelId: String) -> [ChannelParticipantEvent] {
        byKey.values.filter { $0.channelId == channelId }.sorted { $0.userId < $1.userId }
    }
}

public protocol RoomVoiceAPI: Sendable {
    func token(userId: String, channelId: String) async throws -> String
    func joinChannel(channelId: String, userId: String, muted: Bool, speakerOff: Bool, sessionId: String?) async throws
    func setMuted(_ muted: Bool, channelId: String, userId: String, sessionId: String?) async throws
    func setSpeakerOff(_ off: Bool, channelId: String, userId: String, sessionId: String?) async throws
    func leaveChannel(channelId: String, userId: String, sessionId: String?) async throws
    func connectedParticipants(channelIds: [String]) async throws -> [ChannelParticipantEvent]
    func participantEvents(channelIds: [String], subscriber: String) -> AsyncThrowingStream<ChannelParticipantEvent, any Error>
}

public struct RemoteRoomVoiceAPI: RoomVoiceAPI {
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

    public func token(userId: String, channelId: String) async throws -> String {
        try await main.postDecoded("/api/connection/get-token", json: ChannelTokenBody(userId: userId, channelId: channelId), as: TokenBody.self).openviduConnectionUri
    }

    public func joinChannel(channelId: String, userId: String, muted: Bool, speakerOff: Bool, sessionId: String?) async throws {
        let body = ParticipantBody(channelId: channelId, userId: userId, muted: muted, speakerOff: speakerOff, sessionId: sessionId)
        try HTTPClient.requireSuccess(try await events.post("/api/roomparticipant/create", json: body, headers: ["X-Idempotence-Id": body.idempotenceId]))
    }

    public func setMuted(_ muted: Bool, channelId: String, userId: String, sessionId: String?) async throws {
        let body = ParticipantBody(channelId: channelId, userId: userId, muted: muted, sessionId: sessionId)
        try HTTPClient.requireSuccess(try await events.send(method: "PUT", path: "/api/roomparticipant/muted", body: JSONEncoder().encode(body), headers: ["X-Idempotence-Id": body.idempotenceId]))
    }

    public func setSpeakerOff(_ off: Bool, channelId: String, userId: String, sessionId: String?) async throws {
        let body = ParticipantBody(channelId: channelId, userId: userId, speakerOff: off, sessionId: sessionId)
        try HTTPClient.requireSuccess(try await events.send(method: "PUT", path: "/api/roomparticipant/speakeroff", body: JSONEncoder().encode(body), headers: ["X-Idempotence-Id": body.idempotenceId]))
    }

    public func leaveChannel(channelId: String, userId: String, sessionId: String?) async throws {
        let body = ParticipantBody(channelId: channelId, userId: userId, sessionId: sessionId)
        try HTTPClient.requireSuccess(try await events.delete("/api/roomparticipant/delete", json: body, headers: ["X-Idempotence-Id": body.idempotenceId]))
    }

    public func connectedParticipants(channelIds: [String]) async throws -> [ChannelParticipantEvent] {
        guard !channelIds.isEmpty else { return [] }
        let query = channelIds.map { "channelId=\(Self.path($0))" }.joined(separator: "&")
        return try await outbox.getDecoded("/api/roomparticipant/getconnected?\(query)")
    }

    public func participantEvents(channelIds: [String], subscriber: String) -> AsyncThrowingStream<ChannelParticipantEvent, any Error> {
        let events = events
        let transport = eventStream
        let query = channelIds.map { "channelId=\(Self.path($0))" }.joined(separator: "&")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let token = await events.accessToken() else { throw APIError.unauthorized }
                    let url = HTTPClient.join(events.baseURL, "/api/event/room-participant/events?\(query)&userId=\(Self.path(subscriber))&access_token=\(Self.path(token))")
                    for try await event in transport.events(for: URLRequest(url: url)) {
                        if let decoded = try? JSONDecoder().decode(ChannelParticipantEvent.self, from: Data(event.data.utf8)) {
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
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? value
    }
}

private struct ChannelTokenBody: Encodable, Sendable {
    let userId: String
    let channelId: String
}

private struct TokenBody: Decodable {
    let openviduConnectionUri: String
}

private struct ParticipantBody: Encodable, Sendable {
    let channelId: String
    let userId: String
    var muted: Bool?
    var speakerOff: Bool?
    let sessionId: String?
    var eventId = UUID().uuidString.lowercased()
    var idempotenceId = UUID().uuidString.lowercased()

    init(channelId: String, userId: String, muted: Bool? = nil, speakerOff: Bool? = nil, sessionId: String?) {
        self.channelId = channelId
        self.userId = userId
        self.muted = muted
        self.speakerOff = speakerOff
        self.sessionId = sessionId
    }
}

/// Голосовой канал комнаты (`useRoomVoiceSession.ts`): микрофон публикуется до `/create`,
/// иначе другие клиенты через 5 с сочтут участника зависшим и удалят его.
@MainActor
@Observable
public final class RoomVoiceModel {
    public enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case active
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var channelId: String?
    public private(set) var channelName = ""
    public private(set) var session: VoiceRoomSession?
    public private(set) var presence = ChannelPresence()

    private let me: CallParticipant
    private let api: any RoomVoiceAPI
    private let rtcUrl: URL
    private let makeRoom: @MainActor () -> any CallRoom
    private let sessionId: @Sendable () async -> String?
    private let requestMicrophone: @MainActor () async -> Bool
    private var generation = 0
    private var roomEvents: Task<Void, Never>?

    public init(
        me: CallParticipant,
        api: any RoomVoiceAPI,
        rtcUrl: URL,
        makeRoom: @escaping @MainActor () -> any CallRoom,
        sessionId: @escaping @Sendable () async -> String?,
        requestMicrophone: @escaping @MainActor () async -> Bool
    ) {
        self.me = me
        self.api = api
        self.rtcUrl = rtcUrl
        self.makeRoom = makeRoom
        self.sessionId = sessionId
        self.requestMicrophone = requestMicrophone
    }

    public var isInCall: Bool { phase != .idle }

    /// Участники каналов комнаты с живыми обновлениями, пока задача не отменена.
    public func watch(channelIds: [String]) async {
        guard !channelIds.isEmpty else { return }
        if let snapshot = try? await api.connectedParticipants(channelIds: channelIds) {
            var fresh = ChannelPresence()
            snapshot.forEach { fresh.apply($0) }
            presence = fresh
        }
        while !Task.isCancelled {
            do {
                for try await event in api.participantEvents(channelIds: channelIds, subscriber: "room-sidebar-observer:\(me.userId)") {
                    presence.apply(event)
                }
            } catch {}
            try? await Task.sleep(for: .seconds(2))
        }
    }

    public func join(channelId: String, name: String) async {
        guard phase == .idle || isFailed else { return }
        reset()
        let generation = generation
        self.channelId = channelId
        channelName = name
        phase = .connecting
        guard await requestMicrophone() else {
            phase = .failed("Разрешите доступ к микрофону, чтобы войти в голосовой канал")
            return
        }
        let session = await sessionId()
        do {
            let token = try await api.token(userId: me.userId, channelId: channelId)
            guard generation == self.generation else { return }
            let clientData = RoomVoiceClientData(userId: me.userId, username: me.username, micMute: false, speakerOff: false).encoded()
            let voice = VoiceRoomSession(me: me.userId, clientData: clientData, room: makeRoom())
            self.session = voice
            listen(voice, generation: generation)
            try await voice.connect(url: rtcUrl, token: token)
            try await api.joinChannel(channelId: channelId, userId: me.userId, muted: voice.isMuted, speakerOff: voice.isSpeakerOff, sessionId: session)
            guard generation == self.generation else { return }
            presence.apply(ChannelParticipantEvent(userId: me.userId, channelId: channelId, kind: .connect))
            phase = .active
        } catch {
            guard generation == self.generation else { return }
            let voice = self.session
            reset()
            await voice?.disconnect()
            self.channelId = channelId
            phase = .failed("Не удалось подключиться к голосовому каналу")
        }
    }

    public func leave() async {
        guard let channelId else {
            reset()
            return
        }
        if phase == .active || phase == .connecting {
            try? await api.leaveChannel(channelId: channelId, userId: me.userId, sessionId: await sessionId())
            presence.apply(ChannelParticipantEvent(userId: me.userId, channelId: channelId, kind: .disconnect))
        }
        let voice = session
        reset()
        await voice?.disconnect()
    }

    public func toggleMute() async {
        guard let session, let channelId else { return }
        let muted = !session.isMuted
        await session.setMuted(muted)
        try? await api.setMuted(muted, channelId: channelId, userId: me.userId, sessionId: await sessionId())
    }

    public func toggleSpeakerOff() async {
        guard let session, let channelId else { return }
        let off = !session.isSpeakerOff
        await session.setSpeakerOff(off)
        try? await api.setSpeakerOff(off, channelId: channelId, userId: me.userId, sessionId: await sessionId())
    }

    private func listen(_ voice: VoiceRoomSession, generation: Int) {
        roomEvents?.cancel()
        let events = voice.events
        roomEvents = Task { [weak self] in
            for await event in events {
                guard let self, generation == self.generation else { return }
                if await voice.handle(event) {
                    await self.leave()
                    return
                }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func reset() {
        generation += 1
        roomEvents?.cancel()
        roomEvents = nil
        session = nil
        phase = .idle
        channelId = nil
        channelName = ""
    }
}
