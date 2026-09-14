import Foundation

public enum CallTrackKind: Sendable, Equatable {
    case audio
    case video
}

/// События медиакомнаты, уже без типов LiveKit.
public enum CallRoomEvent: Sendable, Equatable {
    case trackPublished(participant: String, trackId: String, name: String, kind: CallTrackKind)
    case trackUnpublished(participant: String, trackId: String)
    /// Дорожка подписана: видео уже можно отрисовать.
    case trackSubscribed(trackId: String)
    case participantLeft(participant: String)
    case data(topic: String, payload: Data)
    case localSpeakingChanged(Bool)
    case reconnecting
    case reconnected
    /// Комната закрыта. `networkLoss` — соединение потеряно, а не завершено сервером или нами.
    case disconnected(networkLoss: Bool)
}

/// Комната LiveKit только для сигналов: текстовые сессии чатов не публикуют дорожек.
@MainActor
public protocol SignalRoom: AnyObject {
    var events: AsyncStream<CallRoomEvent> { get }
    func connect(url: URL, token: String) async throws
    func send(_ packet: Data, topic: String) async throws
    func disconnect() async
}

/// Медиакомната личного звонка. Приложение реализует её на LiveKit Swift SDK,
/// тесты — фейком, поэтому логика звонка не зависит от WebRTC.
@MainActor
public protocol CallRoom: SignalRoom {
    /// Публикует микрофон одной аудиодорожкой с именем по протоколу Connect.
    func publishMicrophone(trackName: String, muted: Bool) async throws
    func setMicrophoneMuted(_ muted: Bool) async throws
    func setSpeakerOutput(_ enabled: Bool)
    /// Видеодорожка SDK для отрисовки; модели звонка её не разбирают.
    func remoteVideoTrack(trackId: String) -> AnyObject?
}

/// Удалённый «поток» OpenVidu: дорожки участника с одним ключом `k`.
public struct RemoteCallStream: Sendable, Equatable {
    public var participant: String
    public var key: String
    public var clientData: CallClientData?
    public var hasAudio: Bool
    public var hasVideo: Bool
    public var createdAtMilliseconds: Int64 = 0
    /// Видеодорожка потока, когда он объявлен.
    public var videoTrackId: String?
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
                hasVideo: name.hasVideo,
                createdAtMilliseconds: name.createdAtMilliseconds
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
            entry.stream.videoTrackId = entry.tracks.first { $0.value == .video }?.key
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

/// Завершённый звонок для сообщения-итога в чате.
public struct CallSummaryReport: Sendable, Equatable {
    public var isGroup: Bool
    /// Личный чат или группа, где был звонок.
    public var roomId: String
    public var durationSeconds: Int
    public var startedAt: Date

    public init(isGroup: Bool, roomId: String, durationSeconds: Int, startedAt: Date) {
        self.isGroup = isGroup
        self.roomId = roomId
        self.durationSeconds = durationSeconds
        self.startedAt = startedAt
    }
}

/// Трансляция участника: камера или экран (`ShareRenderInfo` веб-клиента).
public struct RemoteShare: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case camera = "WEB_CAMERA"
        case screen = "SHARE_DISPLAY"
    }

    public var userId: String
    public var username: String?
    public var kind: Kind
    public var trackId: String
    public var createdAtMilliseconds: Int64
    /// Видео получено; до этого на месте трансляции индикатор загрузки.
    public var isReady = false
    fileprivate var streamKey: String

    /// Одна трансляция на пользователя и вид, как `${userId}-${shareType}` на вебе.
    public var id: String { "\(userId)-\(kind.rawValue)" }
}

/// Трансляции комнаты: у пользователя остаётся только самая новая камера и самый новый экран,
/// потому что веб при подключении новых участников перевыпускает поток.
public struct RemoteShares: Sendable, Equatable {
    public private(set) var items: [RemoteShare] = []

    public init() {}

    /// Возвращает `true`, если список изменился.
    @discardableResult
    public mutating func apply(_ change: RemoteStreamTracker.Change, me: String) -> Bool {
        switch change {
        case let .added(stream):
            guard stream.hasVideo, let trackId = stream.videoTrackId, let data = stream.clientData, data.userId != me else { return false }
            let kind: RemoteShare.Kind = data.shareType == RemoteShare.Kind.screen.rawValue ? .screen : .camera
            let share = RemoteShare(userId: data.userId, username: data.username, kind: kind, trackId: trackId, createdAtMilliseconds: stream.createdAtMilliseconds, streamKey: stream.participant + ":" + stream.key)
            if let index = items.firstIndex(where: { $0.id == share.id }) {
                guard items[index].createdAtMilliseconds <= share.createdAtMilliseconds else { return false }
                items[index] = share
            } else {
                items.append(share)
            }
            return true
        case let .removed(stream):
            let key = stream.participant + ":" + stream.key
            let before = items.count
            items.removeAll { $0.streamKey == key }
            return items.count != before
        }
    }

    public mutating func removeAll() {
        items.removeAll()
    }

    public mutating func markSubscribed(trackId: String) {
        for index in items.indices where items[index].trackId == trackId {
            items[index].isReady = true
        }
    }
}
