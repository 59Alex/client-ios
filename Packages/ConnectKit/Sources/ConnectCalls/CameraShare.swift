import Foundation
import Observation

/// Своя камера в звонке (`startShare("camera")` веб-клиента): отдельное подключение к той же комнате
/// с клиентскими данными `SHARE`/`WEB_CAMERA` и одной видеодорожкой `{k,c,t,a:false,v:true}`.
/// Выключение снимает дорожку и закрывает подключение, а не глушит камеру.
@MainActor
@Observable
public final class CameraShare {
    public enum State: Sendable, Equatable {
        case off
        case starting
        case on
        case failed(String)
    }

    public private(set) var state: State = .off
    public private(set) var streamId: String?

    private let makeRoom: @MainActor () -> any CallRoom
    private let rtcUrl: URL
    private let now: @Sendable () -> Date
    private var room: (any CallRoom)?
    private var generation = 0

    public init(makeRoom: @escaping @MainActor () -> any CallRoom, rtcUrl: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.makeRoom = makeRoom
        self.rtcUrl = rtcUrl
        self.now = now
    }

    public var isOn: Bool { state == .on }
    public var isActive: Bool { state == .on || state == .starting }

    /// `token` выдаёт новое подключение к комнате звонка, `clientData` строит данные по `streamId`.
    @discardableResult
    public func start(token: @escaping @MainActor () async throws -> String, clientData: (String) -> String) async -> Bool {
        guard !isActive else { return false }
        generation += 1
        let current = generation
        state = .starting
        let id = UUID().uuidString.lowercased()
        let data = clientData(id)
        do {
            let room = makeRoom()
            self.room = room
            try await room.connect(url: rtcUrl, token: try await token())
            guard current == generation else {
                await room.disconnect()
                return false
            }
            let name = TrackName(key: UUID().uuidString.lowercased(), clientData: data, createdAtMilliseconds: Int64(now().timeIntervalSince1970 * 1000), hasAudio: false, hasVideo: true)
            try await room.publishCamera(trackName: name.encoded())
            guard current == generation else { return false }
            streamId = id
            state = .on
            return true
        } catch {
            guard current == generation else { return false }
            await room?.disconnect()
            room = nil
            state = .failed("Не удалось включить камеру")
            return false
        }
    }

    public func stop() async {
        generation += 1
        let closing = room
        room = nil
        streamId = nil
        state = .off
        await closing?.disconnect()
    }

    /// Своя видеодорожка для предпросмотра.
    public var localTrack: AnyObject? { room?.localCameraTrack() }

    public func switchCamera() async {
        try? await room?.switchCamera()
    }
}
