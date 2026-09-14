import Foundation
import Observation

/// Участник голосовой комнаты с индикаторами из сигналов.
public struct VoiceParticipant: Sendable, Equatable, Identifiable {
    public var userId: String
    public var username: String?
    public var isSpeaking = false
    public var isMuted = false
    public var isSpeakerOff = false

    public var id: String { userId }

    public init(userId: String, username: String? = nil, isSpeaking: Bool = false, isMuted: Bool = false, isSpeakerOff: Bool = false) {
        self.userId = userId
        self.username = username
        self.isSpeaking = isSpeaking
        self.isMuted = isMuted
        self.isSpeakerOff = isSpeakerOff
    }

    /// Подпись плитки как в `GroupCallModal.tsx`.
    public var stateText: String {
        if isMuted { return "Микрофон выключен" }
        if isSpeaking { return "Говорит" }
        return "В звонке"
    }
}

/// Голосовая комната LiveKit для группового звонка и голосового канала: микрофон одной дорожкой,
/// сигналы `mute`/`speakerOff`/`speak`, голосовые потоки участников.
@MainActor
@Observable
public final class VoiceRoomSession {
    public private(set) var participants: [VoiceParticipant] = []
    public private(set) var isMuted: Bool
    public private(set) var isSpeakerOff = false
    public private(set) var isConnected = false
    /// Камеры и экраны участников.
    public private(set) var shares = RemoteShares()

    private let me: String
    private let clientData: String
    private let room: any CallRoom
    private var tracker = RemoteStreamTracker()
    private var voiceStreams: [String: String] = [:]
    private var localSpeaking = false
    private let now: @Sendable () -> Date

    /// `clientData` — строка, которая попадёт в имя дорожки и в поле `client` сигналов.
    public init(me: String, clientData: String, room: any CallRoom, muted: Bool = false, now: @escaping @Sendable () -> Date = Date.init) {
        self.me = me
        self.clientData = clientData
        self.room = room
        isMuted = muted
        self.now = now
    }

    public var events: AsyncStream<CallRoomEvent> { room.events }

    public func videoTrack(for share: RemoteShare) -> AnyObject? {
        room.remoteVideoTrack(trackId: share.trackId)
    }

    public func connect(url: URL, token: String) async throws {
        try await room.connect(url: url, token: token)
        let name = TrackName(
            key: UUID().uuidString.lowercased(),
            clientData: clientData,
            createdAtMilliseconds: Int64(now().timeIntervalSince1970 * 1000),
            hasAudio: true,
            hasVideo: false
        )
        try await room.publishMicrophone(trackName: name.encoded(), muted: isMuted)
        isConnected = true
        await send(.microphoneMuted(userId: me, muted: isMuted))
        await send(.speakerOff(userId: me, muted: isSpeakerOff))
    }

    /// Возвращает `true`, когда комната закрылась.
    @discardableResult
    public func handle(_ event: CallRoomEvent) async -> Bool {
        for change in tracker.handle(event) {
            shares.apply(change, me: me)
            switch change {
            case let .added(stream):
                guard stream.hasAudio, !stream.hasVideo, let userId = stream.clientData?.userId, userId != me else { continue }
                voiceStreams[stream.participant + ":" + stream.key] = userId
                upsert(userId) { $0.username = $0.username ?? stream.clientData?.username }
            case let .removed(stream):
                guard let userId = voiceStreams.removeValue(forKey: stream.participant + ":" + stream.key) else { continue }
                if !voiceStreams.values.contains(userId) {
                    participants.removeAll { $0.userId == userId }
                }
            }
        }
        switch event {
        case let .data(topic, payload):
            guard topic == CallProtocol.signalTopic, let packet = SignalPacket.decode(payload), let signal = CallSignal(packet: packet), signal.userId != me else { return false }
            // Автор сигнала должен совпадать с клиентскими данными отправителя (`meetingIdentity.ts`).
            if let author = CallClientData.decode(packet.client)?.userId, author != signal.userId { return false }
            switch signal {
            case let .microphoneMuted(userId, muted):
                upsert(userId) {
                    $0.isMuted = muted
                    if muted { $0.isSpeaking = false }
                }
            case let .speakerOff(userId, muted):
                upsert(userId) { $0.isSpeakerOff = muted }
            case let .speaking(userId, speaking):
                upsert(userId) { $0.isSpeaking = speaking && !$0.isMuted }
            }
        case let .localSpeakingChanged(speaking):
            await updateLocalSpeaking(speaking && !isMuted)
        case let .trackSubscribed(trackId):
            shares.markSubscribed(trackId: trackId)
        case .disconnected:
            isConnected = false
            shares.removeAll()
            return true
        default:
            break
        }
        return false
    }

    public func setMuted(_ muted: Bool) async {
        isMuted = muted
        try? await room.setMicrophoneMuted(muted)
        if muted { await updateLocalSpeaking(false) }
        await send(.microphoneMuted(userId: me, muted: muted))
    }

    public func setSpeakerOff(_ off: Bool) async {
        isSpeakerOff = off
        await send(.speakerOff(userId: me, muted: off))
    }

    public func disconnect() async {
        isConnected = false
        await room.disconnect()
    }

    private func updateLocalSpeaking(_ speaking: Bool) async {
        guard localSpeaking != speaking else { return }
        localSpeaking = speaking
        await send(.speaking(userId: me, speaking: speaking))
    }

    private func send(_ signal: CallSignal) async {
        try? await room.send(signal.packet(client: clientData).encoded(), topic: CallProtocol.signalTopic)
    }

    /// Сигнал может прийти раньше потока: участник заводится по первому упоминанию.
    private func upsert(_ userId: String, _ change: (inout VoiceParticipant) -> Void) {
        if let index = participants.firstIndex(where: { $0.userId == userId }) {
            change(&participants[index])
        } else {
            var participant = VoiceParticipant(userId: userId)
            change(&participant)
            participants.append(participant)
        }
    }
}

/// Клиентские данные голосового канала комнаты: JSON-строка без обёртки `clientData`.
public struct RoomVoiceClientData: Encodable, Sendable {
    public var streamType = "VOICE"
    public var userId: String
    public var username: String
    public var micMute: Bool
    public var speakerOff: Bool
    public var micVolume: Int

    public init(userId: String, username: String, micMute: Bool, speakerOff: Bool, micVolume: Int = 100) {
        self.userId = userId
        self.username = username
        self.micMute = micMute
        self.speakerOff = speakerOff
        self.micVolume = micVolume
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
