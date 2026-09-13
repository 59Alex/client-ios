import Foundation

public enum CallTrackKind: Sendable, Equatable {
    case audio
    case video
}

/// События медиакомнаты, уже без типов LiveKit.
public enum CallRoomEvent: Sendable, Equatable {
    case trackPublished(participant: String, trackId: String, name: String, kind: CallTrackKind)
    case trackUnpublished(participant: String, trackId: String)
    case participantLeft(participant: String)
    case data(topic: String, payload: Data)
    case localSpeakingChanged(Bool)
    case reconnecting
    case reconnected
    /// Комната закрыта. `networkLoss` — соединение потеряно, а не завершено сервером или нами.
    case disconnected(networkLoss: Bool)
}

/// Медиакомната личного звонка. Приложение реализует её на LiveKit Swift SDK,
/// тесты — фейком, поэтому логика звонка не зависит от WebRTC.
@MainActor
public protocol CallRoom: AnyObject {
    var events: AsyncStream<CallRoomEvent> { get }
    func connect(url: URL, token: String) async throws
    /// Публикует микрофон одной аудиодорожкой с именем по протоколу Connect.
    func publishMicrophone(trackName: String, muted: Bool) async throws
    func setMicrophoneMuted(_ muted: Bool) async throws
    func setSpeakerOutput(_ enabled: Bool)
    func send(_ packet: Data, topic: String) async throws
    func disconnect() async
}

/// Удалённый «поток» OpenVidu: дорожки участника с одним ключом `k`.
public struct RemoteCallStream: Sendable, Equatable {
    public var participant: String
    public var key: String
    public var clientData: CallClientData?
    public var hasAudio: Bool
    public var hasVideo: Bool
}

/// Собирает дорожки в потоки так же, как фасад веб-клиента: поток объявляется, когда
/// опубликованы все ожидаемые виды дорожек, и пропадает вместе с последней дорожкой.
public struct RemoteStreamTracker: Sendable {
    public enum Change: Sendable, Equatable {
        case added(RemoteCallStream)
        case removed(RemoteCallStream)
    }

    private struct Entry: Sendable {
        var stream: RemoteCallStream
        var tracks: [String: CallTrackKind]
        var announced: Bool
    }

    private var entries: [String: Entry] = [:]
    private var entryByTrack: [String: String] = [:]

    public init() {}

    public mutating func handle(_ event: CallRoomEvent) -> [Change] {
        switch event {
        case let .trackPublished(participant, trackId, rawName, kind):
            return published(participant: participant, trackId: trackId, rawName: rawName, kind: kind)
        case let .trackUnpublished(_, trackId):
            return unpublished(trackId: trackId)
        case let .participantLeft(participant):
            let ids = entryByTrack.filter { entries[$0.value]?.stream.participant == participant }.map(\.key)
            return ids.flatMap { unpublished(trackId: $0) }
        case .disconnected:
            let removed = entries.values.filter(\.announced).map { Change.removed($0.stream) }
            entries.removeAll()
            entryByTrack.removeAll()
            return removed
        default:
            return []
        }
    }

    private mutating func published(participant: String, trackId: String, rawName: String, kind: CallTrackKind) -> [Change] {
        guard entryByTrack[trackId] == nil, let name = TrackName.decode(rawName) else { return [] }
        let streamId = "\(participant):\(name.key)"
        var entry = entries[streamId] ?? Entry(
            stream: RemoteCallStream(
                participant: participant,
                key: name.key,
                clientData: CallClientData.decode(name.clientData),
                hasAudio: name.hasAudio,
                hasVideo: name.hasVideo
            ),
            tracks: [:],
            announced: false
        )
        entry.tracks[trackId] = kind
        entryByTrack[trackId] = streamId

        var changes: [Change] = []
        let hasAudio = entry.tracks.values.contains(.audio)
        let hasVideo = entry.tracks.values.contains(.video)
        if !entry.announced, hasAudio == entry.stream.hasAudio, hasVideo == entry.stream.hasVideo {
            entry.announced = true
            changes.append(.added(entry.stream))
        }
        entries[streamId] = entry
        return changes
    }

    private mutating func unpublished(trackId: String) -> [Change] {
        guard let streamId = entryByTrack.removeValue(forKey: trackId), var entry = entries[streamId] else { return [] }
        entry.tracks[trackId] = nil
        guard entry.tracks.isEmpty else {
            entries[streamId] = entry
            return []
        }
        entries[streamId] = nil
        return entry.announced ? [.removed(entry.stream)] : []
    }
}
