import ConnectCore
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectCalls

@MainActor
@Suite("Личный звонок")
struct P2PCallModelTests {
    let me = CallParticipant(userId: "me", name: "Я", username: "@me")
    let peer = Contact(userId: "peer", name: "Иван", username: "ivan", status: .online)
    let api: FakeP2PCallAPI
    var rooms: [FakeCallRoom] = []
    let fixedNow = Date(timeIntervalSince1970: 1_757_750_000)

    init() {
        api = FakeP2PCallAPI(contacts: [peer])
    }

    private func makeModel(microphoneAllowed: Bool = true, roomSetup: (@MainActor (FakeCallRoom) -> Void)? = nil) -> (P2PCallModel, RoomBox) {
        let box = RoomBox()
        let now = fixedNow
        let model = P2PCallModel(
            me: me,
            api: api,
            rtcUrl: URL(string: "wss://rtc.cnnect.ru/livekit")!,
            makeRoom: {
                let room = FakeCallRoom()
                roomSetup?(room)
                box.rooms.append(room)
                return room
            },
            sessionId: { "session-1" },
            requestMicrophone: { microphoneAllowed },
            now: { now },
            sleep: { _ in await Task.yield() }
        )
        return (model, box)
    }

    /// Даёт задаче событий комнаты обработать отправленное событие.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test("исходящий звонок: создать, войти в комнату, дождаться собеседника")
    func outgoingCall() async throws {
        let (model, box) = makeModel()
        await model.call(peer)

        #expect(model.phase == .ringing)
        #expect(await api.createdCalls.map(\.callee) == ["peer"])
        let room = try #require(box.rooms.last)
        #expect(room.token == "token-room-me-peer")
        #expect(room.connectedUrl?.absoluteString == "wss://rtc.cnnect.ru/livekit")

        let rawTrackName = try #require(room.publishedTrackName)
        let trackName = try #require(TrackName.decode(rawTrackName))
        #expect(trackName.hasAudio && !trackName.hasVideo)
        #expect(CallClientData.decode(trackName.clientData) == CallClientData(userId: "me", username: "@me", sessionId: "session-1"))
        #expect(room.sentPackets.map(\.type) == ["mute", "speakerOff"])

        let started = Date(timeIntervalSince1970: 1_757_749_999)
        await api.setStoredCallTime(started)
        room.emitRemoteAudio(userId: "peer")
        await settle()

        #expect(model.phase == .active(startedAt: started))
        #expect(model.statusText == "Вызов активен")
    }

    @Test("камера собеседника появляется трансляцией, её снятие не завершает звонок")
    func remoteCamera() async throws {
        let (model, box) = makeModel()
        await model.call(peer)
        let room = try #require(box.rooms.last)
        room.emitRemoteAudio(userId: "peer")
        room.emitRemoteShare(userId: "peer")
        await settle()

        let share = try #require(model.shares.items.first)
        #expect(share.kind == .camera)
        #expect(model.videoTrack(for: share) as? String == "TR_share_video")
        #expect(!share.isReady)
        room.emit(.trackSubscribed(trackId: "TR_share_video"))
        await settle()
        #expect(model.shares.items.first?.isReady == true)

        room.emit(.trackUnpublished(participant: "share#1", trackId: "TR_share_video"))
        await settle()
        #expect(model.shares.items.isEmpty)
        #expect(model.phase != .idle)
    }

    @Test("своя камера: отдельное подключение с данными трансляции, завершение звонка её закрывает")
    func ownCamera() async throws {
        let (model, box) = makeModel()
        await model.call(peer)
        let voiceRoom = try #require(box.rooms.last)
        voiceRoom.emitRemoteAudio(userId: "peer")
        await settle()

        await model.toggleCamera()
        #expect(model.camera.isOn)
        #expect(box.rooms.count == 2)
        let cameraRoom = try #require(box.rooms.last)
        let rawCameraName = try #require(cameraRoom.publishedCameraName)
        let name = try #require(TrackName.decode(rawCameraName))
        #expect(!name.hasAudio && name.hasVideo)
        let data = try #require(CallClientData.decode(name.clientData))
        #expect(data.userId == "me")
        #expect(data.streamType == "SHARE")
        #expect(data.shareType == "WEB_CAMERA")
        #expect(name.clientData.contains("clientData"))
        #expect(model.camera.localTrack != nil)

        await model.hangUp()
        #expect(!model.camera.isActive)
        #expect(cameraRoom.isDisconnected)
    }

    @Test("камеру нельзя включить без комнаты звонка; ошибка публикации показывается")
    func cameraFailures() async throws {
        let (idle, idleBox) = makeModel()
        await idle.toggleCamera()
        #expect(!idle.camera.isActive)
        #expect(idleBox.rooms.isEmpty)

        let share = CameraShare(makeRoom: {
            let room = FakeCallRoom()
            room.failCamera = true
            return room
        }, rtcUrl: URL(string: "wss://x")!)
        #expect(await share.start(token: { "t" }) { _ in "{}" } == false)
        #expect(share.state == .failed("Не удалось включить камеру"))
    }

    @Test("собеседник снял аудиопоток — звонок завершается и удаляется")
    func remoteHangUp() async throws {
        let (model, box) = makeModel()
        await model.call(peer)
        let room = try #require(box.rooms.last)
        room.emitRemoteAudio(userId: "peer")
        await settle()

        room.emit(.trackUnpublished(participant: "peer#1", trackId: "TR_peer_audio"))
        await settle()

        #expect(model.phase == .idle)
        #expect(await api.deletedCallIds == ["call-1"])
        #expect(room.isDisconnected)
    }

    @Test("свой поток с другого устройства не считается собеседником")
    func ignoresOwnStream() async throws {
        let (model, box) = makeModel()
        await model.call(peer)
        try #require(box.rooms.last).emitRemoteAudio(userId: "me", participant: "me#2")
        await settle()
        #expect(model.phase == .ringing)
    }

    @Test("409 на создание показывает «Занят» и не входит в комнату")
    func busy() async {
        await api.setBusy(true)
        let (model, box) = makeModel()
        await model.call(peer)

        #expect(model.phase == .failed("Занят"))
        #expect(box.rooms.isEmpty)

        await model.hangUp()
        #expect(model.phase == .idle)
    }

    @Test("без доступа к микрофону звонок не создаётся")
    func microphoneDenied() async {
        let (model, _) = makeModel(microphoneAllowed: false)
        await model.call(peer)

        guard case .failed = model.phase else {
            Issue.record("ожидалась ошибка, получено \(model.phase)")
            return
        }
        #expect(await api.createdCalls.isEmpty)
    }

    @Test("сбой подключения повторяется и затем удаляет звонок")
    func connectFailure() async {
        struct Failure: Error {}
        let (model, box) = makeModel { $0.connectError = Failure() }
        await model.call(peer)

        #expect(box.rooms.count == P2PCallModel.connectAttempts)
        #expect(model.phase == .failed("Не удалось подключиться к звонку"))
        #expect(await api.deletedCallIds == ["call-1"])
    }

    @Test("положить трубку: DELETE и выход из комнаты")
    func hangUp() async throws {
        let (model, box) = makeModel()
        await model.call(peer)
        await model.hangUp()

        #expect(model.phase == .idle)
        #expect(await api.deletedCallIds == ["call-1"])
        #expect(try #require(box.rooms.last).isDisconnected)
    }

    @Test("выключение микрофона глушит дорожку и отправляет сигнал")
    func mute() async throws {
        let (model, box) = makeModel()
        await model.call(peer)
        let room = try #require(box.rooms.last)

        await model.toggleMute()

        #expect(model.isMuted)
        #expect(room.microphoneMuted == true)
        let last = try #require(room.sentPackets.last)
        #expect(CallSignal(packet: last) == .microphoneMuted(userId: "me", muted: true))
    }

    @Test("сигналы собеседника обновляют индикаторы, свои пропускаются")
    func remoteSignals() async throws {
        let (model, box) = makeModel()
        await model.call(peer)
        let room = try #require(box.rooms.last)

        room.emit(.data(topic: "ov-signal", payload: CallSignal.speaking(userId: "peer", speaking: true).packet(client: "").encoded()))
        await settle()
        #expect(model.isRemoteSpeaking)

        room.emit(.data(topic: "ov-signal", payload: CallSignal.microphoneMuted(userId: "peer", muted: true).packet(client: "").encoded()))
        room.emit(.data(topic: "ov-signal", payload: CallSignal.microphoneMuted(userId: "me", muted: false).packet(client: "").encoded()))
        await settle()
        #expect(model.isRemoteMuted)
        #expect(!model.isRemoteSpeaking)
    }

    @Test("речь пользователя уходит сигналом speak")
    func localSpeaking() async throws {
        let (model, box) = makeModel()
        await model.call(peer)
        let room = try #require(box.rooms.last)

        room.emit(.localSpeakingChanged(true))
        await settle()
        #expect(CallSignal(packet: try #require(room.sentPackets.last)) == .speaking(userId: "me", speaking: true))
    }

    @Test("входящий звонок: показать, принять, записать время и войти")
    func incomingAccept() async throws {
        let (model, box) = makeModel()
        await model.handle(.call(callId: "in-1", callerUserId: "peer", calleeUserId: "me"))

        #expect(model.phase == .incoming)
        #expect(model.peer?.name == "Иван")
        #expect(model.direction == .incoming)

        await model.accept()
        #expect(await api.callTimes["in-1"] == fixedNow)
        let room = try #require(box.rooms.last)
        #expect(model.phase == .ringing)

        room.emitRemoteAudio(userId: "peer")
        await settle()
        #expect(model.phase == .active(startedAt: fixedNow))

        await model.hangUp()
        #expect(await api.deletedCallIds == ["in-1"])
    }

    @Test("отклонённый вызов удаляется и не показывается повторно сразу")
    func incomingDecline() async {
        let (model, _) = makeModel()
        await model.handle(.call(callId: "in-1", callerUserId: "peer", calleeUserId: "me"))
        await model.decline()

        #expect(model.phase == .idle)
        #expect(await api.deletedCallIds == ["in-1"])

        await model.handle(.call(callId: "in-1", callerUserId: "peer", calleeUserId: "me"))
        #expect(model.phase == .idle)
    }

    @Test("отмена вызывающим закрывает входящий без повторного DELETE")
    func incomingCancelled() async {
        let (model, _) = makeModel()
        await model.handle(.call(callId: "in-1", callerUserId: "peer", calleeUserId: "me"))
        await model.handle(.cancel(callId: "in-1", callerUserId: "peer", calleeUserId: "me"))

        #expect(model.phase == .idle)
        #expect(await api.deletedCallIds.isEmpty)
    }

    @Test("отказ собеседника завершает исходящий")
    func outgoingDeclined() async {
        let (model, _) = makeModel()
        await model.call(peer)
        await model.handle(.cancel(callId: "call-1", callerUserId: "me", calleeUserId: "peer"))
        #expect(model.phase == .idle)
    }

    @Test("второй входящий во время разговора отклоняется автоматически")
    func busyWhileInCall() async {
        let (model, _) = makeModel()
        await model.call(peer)
        await model.handle(.call(callId: "other", callerUserId: "someone", calleeUserId: "me"))

        #expect(model.phase == .ringing)
        #expect(await api.deletedCallIds == ["other"])
    }

    @Test("вызов без идентификатора дополняется из outbox")
    func incomingWithoutId() async {
        await api.setPendingIncoming(.call(callId: "found", callerUserId: "peer", calleeUserId: "me"))
        let (model, _) = makeModel()
        await model.handle(.call(callId: nil, callerUserId: "peer", calleeUserId: "me"))
        #expect(model.phase == .incoming)

        await model.decline()
        #expect(await api.deletedCallIds == ["found"])
    }

    @Test("переподключение сохраняет время начала")
    func reconnect() async throws {
        let (model, box) = makeModel()
        await model.handle(.call(callId: "in-1", callerUserId: "peer", calleeUserId: "me"))
        await model.accept()
        let room = try #require(box.rooms.last)
        room.emitRemoteAudio(userId: "peer")
        await settle()

        room.emit(.reconnecting)
        await settle()
        #expect(model.phase == .reconnecting(startedAt: fixedNow))
        #expect(model.statusText == "Переподключение...")

        room.emit(.reconnected)
        await settle()
        #expect(model.phase == .active(startedAt: fixedNow))
    }
}

@MainActor
final class RoomBox {
    var rooms: [FakeCallRoom] = []
}
