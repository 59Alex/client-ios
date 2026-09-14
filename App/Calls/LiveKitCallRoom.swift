import ConnectCalls
import Foundation
import LiveKit

/// Медиакомната личного звонка на LiveKit Swift SDK поверх OpenVidu 3.
/// Переводит события SDK в `CallRoomEvent`; протокол Connect живёт в `ConnectCalls`.
@MainActor
final class LiveKitCallRoom: CallRoom {
    let events: AsyncStream<CallRoomEvent>

    private let continuation: AsyncStream<CallRoomEvent>.Continuation
    private let observer: RoomObserver
    private let room: Room
    private var microphone: LocalAudioTrack?

    init() {
        let (events, continuation) = AsyncStream<CallRoomEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        observer = RoomObserver(continuation: continuation)
        room = Room(delegate: observer)
    }

    func connect(url: URL, token: String) async throws {
        // Сигналы крупнее data-пакета веб-клиент шлёт текстовым потоком в том же топике.
        let continuation = continuation
        try await room.registerTextStreamHandler(for: CallProtocol.signalTopic) { reader, _ in
            let text = try await reader.readAll()
            continuation.yield(.data(topic: CallProtocol.signalTopic, payload: Data(text.utf8)))
        }
        try await room.connect(url: url.absoluteString, token: token, connectOptions: ConnectOptions(autoSubscribe: true))

        // Собеседник мог войти раньше нас: его дорожки объявляются так же, как новые.
        for participant in room.remoteParticipants.values {
            for publication in participant.trackPublications.values {
                observer.published(publication, by: participant)
            }
        }
    }

    func publishMicrophone(trackName: String, muted: Bool) async throws {
        let track = LocalAudioTrack.createTrack(name: trackName, options: AudioCaptureOptions())
        let publication = try await room.localParticipant.publish(audioTrack: track, options: AudioPublishOptions(name: trackName))
        microphone = track
        if muted {
            try await publication.mute()
        }
    }

    func setMicrophoneMuted(_ muted: Bool) async throws {
        guard let microphone else { return }
        if muted {
            try await microphone.mute()
        } else {
            try await microphone.unmute()
        }
    }

    func setSpeakerOutput(_ enabled: Bool) {
        AudioManager.shared.isSpeakerOutputPreferred = enabled
    }

    func remoteVideoTrack(trackId: String) -> AnyObject? {
        for participant in room.remoteParticipants.values {
            if let publication = participant.trackPublications.values.first(where: { $0.sid.stringValue == trackId }) {
                return publication.track as? VideoTrack
            }
        }
        return nil
    }

    func send(_ packet: Data, topic: String) async throws {
        if packet.count <= CallProtocol.maxDataPacketBytes {
            try await room.localParticipant.publish(data: packet, options: DataPublishOptions(topic: topic, reliable: true))
        } else {
            try await room.localParticipant.sendText(String(decoding: packet, as: UTF8.self), for: topic)
        }
    }

    func disconnect() async {
        microphone = nil
        await room.disconnect()
        continuation.finish()
    }
}

/// Делегат SDK вызывается не на главном потоке, поэтому только пересылает события в поток.
private final class RoomObserver: NSObject, RoomDelegate, Sendable {
    private let continuation: AsyncStream<CallRoomEvent>.Continuation

    init(continuation: AsyncStream<CallRoomEvent>.Continuation) {
        self.continuation = continuation
    }

    func published(_ publication: TrackPublication, by participant: Participant) {
        continuation.yield(.trackPublished(
            participant: participant.identity?.stringValue ?? "",
            trackId: publication.sid.stringValue,
            name: publication.name,
            kind: publication.kind == .video ? .video : .audio
        ))
    }

    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        published(publication, by: participant)
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        continuation.yield(.trackSubscribed(trackId: publication.sid.stringValue))
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        continuation.yield(.trackUnpublished(participant: participant.identity?.stringValue ?? "", trackId: publication.sid.stringValue))
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        continuation.yield(.participantLeft(participant: participant.identity?.stringValue ?? ""))
    }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        continuation.yield(.data(topic: topic, payload: data))
    }

    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        continuation.yield(.localSpeakingChanged(participants.contains { $0 is LocalParticipant }))
    }

    func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        continuation.yield(.reconnecting)
    }

    func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        continuation.yield(.reconnected)
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        continuation.yield(.disconnected(networkLoss: error != nil))
    }
}
