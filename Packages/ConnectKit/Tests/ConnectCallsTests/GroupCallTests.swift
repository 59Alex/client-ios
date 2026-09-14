import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectCalls

@MainActor
@Suite("Групповые звонки и голосовые каналы")
struct GroupCallTests {
    let me = CallParticipant(userId: "me", name: "Я", username: "@me")

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private func makeGroupModel(api: FakeGroupCallAPI, rooms: GroupRoomBox) -> GroupCallModel {
        GroupCallModel(
            me: me,
            api: api,
            rtcUrl: URL(string: "wss://rtc.cnnect.ru/livekit")!,
            makeRoom: {
                let room = FakeCallRoom()
                rooms.rooms.append(room)
                return room
            },
            sessionId: { "session-1" },
            requestMicrophone: { true },
            now: { Date(timeIntervalSince1970: 1_757_800_000) },
            sleep: { _ in await Task.yield() }
        )
    }

    private func remoteAudio(_ room: FakeCallRoom, userId: String, wrapped: Bool = true) {
        let clientData = wrapped
            ? CallClientData(userId: userId, username: userId, sessionId: nil).encoded()
            : RoomVoiceClientData(userId: userId, username: userId, micMute: false, speakerOff: false).encoded()
        let name = TrackName(key: "k-\(userId)", clientData: clientData, createdAtMilliseconds: 1, hasAudio: true, hasVideo: false)
        room.emit(.trackPublished(participant: "\(userId)#1", trackId: "TR_\(userId)", name: name.encoded(), kind: .audio))
    }

    @Test("события групповых звонков разбираются с синонимами полей")
    func decodesEvents() throws {
        #expect(GroupCallEvent.decode(#"{"groupCallId":"g","callerUserId":"a","callee_user_id":"b","group_chat_id":"c","type":"CALL"}"#)
            == GroupCallEvent(kind: .call, groupCallId: "g", callerUserId: "a", calleeUserId: "b", groupChatId: "c"))
        #expect(GroupCallEvent.decode(#"{"groupCallId":"g","type":"WHAT"}"#) == nil)

        let json = #"{"id":"g","callerUserId":"a","groupChatId":"c","name":"Команда","timestamp":"1757839200000","groupCallParticipants":[{"participantUserId":"a","sessionId":"s"},"b",{"user_id":"a"}],"callees":[{"calleeUserId":"me","canceled":false},{"calleeUserId":"x","canceled":true}]}"#
        let record = try #require(GroupCallRecord.decode(try JSONSerialization.jsonObject(with: Data(json.utf8))))
        #expect(record.participantUserIds == ["a", "b"])
        #expect(record.pendingCallees(excluding: "other") == ["me"])
        #expect(record.declinedCallees(excluding: "me") == ["x"])
        #expect(record.startedAt == Date(timeIntervalSince1970: 1_757_839_200))
    }

    @Test("звонок в группу: создание с участниками, вход в комнату, собеседник и сигналы")
    func startCall() async throws {
        let api = FakeGroupCallAPI()
        let rooms = GroupRoomBox()
        let model = makeGroupModel(api: api, rooms: rooms)

        await model.start(groupChatId: "chat", name: "Команда", memberUserIds: ["me", "u2", "u3"])

        #expect(model.phase == .active(startedAt: Date(timeIntervalSince1970: 1_757_800_000)))
        #expect(await api.created.first?.callees == ["u2", "u3"])
        #expect(model.pendingUserIds == ["u2", "u3"])
        let room = try #require(rooms.rooms.first)
        #expect(room.token == "group-token-group-call-1")
        let rawName = try #require(room.publishedTrackName)
        let name = try #require(TrackName.decode(rawName))
        #expect(CallClientData.decode(name.clientData)?.sessionId == "session-1")
        #expect(room.sentPackets.map(\.type) == ["mute", "speakerOff"])

        remoteAudio(room, userId: "u2")
        room.emit(.data(topic: "ov-signal", payload: CallSignal.speaking(userId: "u2", speaking: true).packet(client: CallClientData(userId: "u2", username: nil, sessionId: nil).encoded()).encoded()))
        await settle()
        #expect(model.participants.first { $0.userId == "u2" }?.isSpeaking == true)

        // Сигнал с чужой подписью не меняет состояние.
        room.emit(.data(topic: "ov-signal", payload: CallSignal.microphoneMuted(userId: "u2", muted: true).packet(client: CallClientData(userId: "u3", username: nil, sessionId: nil).encoded()).encoded()))
        await settle()
        #expect(model.participants.first { $0.userId == "u2" }?.isMuted == false)

        await model.hangUp()
        #expect(model.phase == .idle)
        #expect(await api.left == ["group-call-1"])
        #expect(room.isDisconnected)
    }

    @Test("хост без собеседников удаляет звонок, все отказались — звонок закрывается")
    func abandonedCall() async throws {
        let api = FakeGroupCallAPI()
        let rooms = GroupRoomBox()
        let model = makeGroupModel(api: api, rooms: rooms)
        await model.start(groupChatId: "chat", name: "Команда", memberUserIds: ["u2"])
        await settle()
        #expect(await api.hasCallSubscriber("group-call-1"))

        await api.pushCallEvent(GroupCallEvent(kind: .cancel, groupCallId: "group-call-1", calleeUserId: "u2"))
        await settle()

        #expect(model.phase == .idle)
        #expect(await api.deleted == ["group-call-1"])
    }

    @Test("занят: 409 на создание")
    func busy() async {
        let api = FakeGroupCallAPI()
        await api.setBusy(true)
        let model = makeGroupModel(api: api, rooms: GroupRoomBox())
        await model.start(groupChatId: "chat", name: "Команда", memberUserIds: ["u2"])
        #expect(model.phase == .failed("Занят"))
    }

    @Test("входящий: показ, принятие с повтором при 409 и отказ")
    func incoming() async throws {
        let record = GroupCallRecord(id: "g1", callerUserId: "u2", groupChatId: "chat", name: "Команда", participants: [("u2", "s2")], callees: [.init(userId: "me", canceled: false)])
        let api = FakeGroupCallAPI(records: [record])
        await api.setJoinConflicts(1)
        let rooms = GroupRoomBox()
        let model = makeGroupModel(api: api, rooms: rooms)

        await model.handle(GroupCallEvent(kind: .call, groupCallId: "g1", callerUserId: "u2", calleeUserId: "me", groupChatId: "chat"))
        #expect(model.phase == .incoming)
        #expect(model.title == "Команда")
        #expect(model.participants.map(\.userId) == ["u2"])

        await model.accept()
        #expect(await api.joined == ["g1"])
        #expect(await api.left == ["g1"])
        #expect(rooms.rooms.first?.token == "group-token-g1")
        guard case .active = model.phase else {
            Issue.record("звонок не активен: \(model.phase)")
            return
        }

        let other = makeGroupModel(api: FakeGroupCallAPI(records: [record]), rooms: GroupRoomBox())
        await other.handle(GroupCallEvent(kind: .call, groupCallId: "g1", callerUserId: "u2", calleeUserId: "me"))
        await other.decline()
        #expect(other.phase == .idle)
    }

    @Test("второй входящий во время звонка отклоняется автоматически")
    func autoDecline() async {
        let first = GroupCallRecord(id: "g1", callerUserId: "u2", groupChatId: "a", callees: [.init(userId: "me", canceled: false)])
        let second = GroupCallRecord(id: "g2", callerUserId: "u3", groupChatId: "b", callees: [.init(userId: "me", canceled: false)])
        let api = FakeGroupCallAPI(records: [first, second])
        let model = makeGroupModel(api: api, rooms: GroupRoomBox())
        await model.handle(GroupCallEvent(kind: .call, groupCallId: "g1", callerUserId: "u2", calleeUserId: "me"))
        await model.handle(GroupCallEvent(kind: .call, groupCallId: "g2", callerUserId: "u3", calleeUserId: "me"))
        #expect(model.callId == "g1")
        #expect(await api.declined == ["g2"])
    }

    @Test("«Позвонить снова»: занятый звонок в группу повторяется с теми же участниками")
    func groupCallAgain() async {
        let api = FakeGroupCallAPI()
        await api.setBusy(true)
        let model = GroupCallModel(me: CallParticipant(userId: "me", name: "Я", username: "@me"), api: api, rtcUrl: URL(string: "wss://x")!, makeRoom: { FakeCallRoom() }, sessionId: { nil }, requestMicrophone: { true }, sleep: { _ in await Task.yield() })

        await model.start(groupChatId: "g1", name: "Группа", memberUserIds: ["me", "u2"])
        #expect(model.phase == .failed("Занят"))
        #expect(model.canCallAgain)

        await api.setBusy(false)
        await model.callAgain()
        #expect(await api.created.map(\.chat) == ["g1"])
        #expect(await api.created.first?.callees == ["u2"])
        #expect(!model.canCallAgain)
    }

    @Test("голосовой канал: микрофон до /create, клиентские данные без обёртки, управление и выход")
    func roomVoice() async throws {
        let api = FakeRoomVoiceAPI()
        let rooms = GroupRoomBox()
        let model = RoomVoiceModel(
            me: me,
            api: api,
            rtcUrl: URL(string: "wss://rtc.cnnect.ru/livekit")!,
            makeRoom: {
                let room = FakeCallRoom()
                rooms.rooms.append(room)
                return room
            },
            sessionId: { "session-1" },
            requestMicrophone: { true }
        )

        await model.join(channelId: "voice-1", name: "Голосовой")
        #expect(model.phase == .active)
        #expect(await api.calls == ["token", "create"])
        let room = try #require(rooms.rooms.first)
        #expect(room.publishedTrackName != nil)
        let rawName = try #require(room.publishedTrackName)
        let name = try #require(TrackName.decode(rawName))
        let clientData = try #require(JSONSerialization.jsonObject(with: Data(name.clientData.utf8)) as? [String: Any])
        #expect(clientData["streamType"] as? String == "VOICE")
        #expect(clientData["clientData"] == nil)
        #expect(model.presence.participants(in: "voice-1").map(\.userId) == ["me"])

        remoteAudio(room, userId: "u2", wrapped: false)
        await settle()
        #expect(model.session?.participants.map(\.userId) == ["u2"])

        await model.toggleMute()
        await model.toggleSpeakerOff()
        #expect(model.session?.isMuted == true)
        #expect(await api.calls.suffix(2) == ["muted:true", "speakeroff:true"])

        await model.leave()
        #expect(model.phase == .idle)
        #expect(await api.calls.last == "delete")
        #expect(room.isDisconnected)
    }

    @Test("камера в голосовом канале: отдельное подключение, streamon и publish_stream; выход её закрывает")
    func roomVoiceCamera() async throws {
        let api = FakeRoomVoiceAPI()
        let rooms = GroupRoomBox()
        let model = RoomVoiceModel(
            me: me,
            api: api,
            rtcUrl: URL(string: "wss://rtc.cnnect.ru/livekit")!,
            makeRoom: {
                let room = FakeCallRoom()
                rooms.rooms.append(room)
                return room
            },
            sessionId: { "session-1" },
            requestMicrophone: { true }
        )
        await model.join(channelId: "voice-1", name: "Голосовой")
        await model.toggleCamera()

        #expect(model.camera.isOn)
        #expect(rooms.rooms.count == 2)
        let voiceRoom = try #require(rooms.rooms.first)
        let cameraRoom = try #require(rooms.rooms.last)
        let rawCameraName = try #require(cameraRoom.publishedCameraName)
        let name = try #require(TrackName.decode(rawCameraName))
        #expect(!name.hasAudio && name.hasVideo)
        let clientData = try #require(JSONSerialization.jsonObject(with: Data(name.clientData.utf8)) as? [String: Any])
        #expect(clientData["streamType"] as? String == "SHARE")
        #expect(clientData["shareType"] as? String == "WEB_CAMERA")
        #expect(clientData["streamId"] as? String == model.camera.streamId)
        #expect(clientData["clientData"] == nil)
        #expect(await api.calls.contains("streamon:true"))
        let announce = try #require(voiceRoom.sentPackets.last)
        #expect(announce.type == "publish_stream")
        #expect(announce.data.contains(#""streamId":"\#(model.camera.streamId ?? "")""#))

        await model.toggleCamera()
        #expect(!model.camera.isActive)
        #expect(cameraRoom.isDisconnected)
        #expect(await api.calls.last == "streamon:false")
    }

    @Test("присутствие в голосовых каналах: снимок и слияние событий")
    func presence() {
        var presence = ChannelPresence()
        presence.apply(ChannelParticipantEvent(userId: "u1", channelId: "c", muted: false, speakerOff: true, kind: .connect))
        presence.apply(ChannelParticipantEvent(userId: "u1", channelId: "c", muted: true, speakerOff: false, kind: .mute))
        #expect(presence.participants(in: "c").first?.muted == true)
        #expect(presence.participants(in: "c").first?.speakerOff == true)
        presence.apply(ChannelParticipantEvent(userId: "u1", channelId: "c", kind: .disconnect))
        #expect(presence.participants(in: "c").isEmpty)
    }
}

@MainActor
final class GroupRoomBox {
    var rooms: [FakeCallRoom] = []
}

@MainActor
@Suite("Итоги звонков")
struct CallSummaryTests {
    @Test("ответ выхода из группового звонка: число, флаг или объект")
    func lastParticipant() {
        #expect(RemoteGroupCallAPI.wasLastParticipant(Data("0".utf8)))
        #expect(!RemoteGroupCallAPI.wasLastParticipant(Data("2".utf8)))
        #expect(RemoteGroupCallAPI.wasLastParticipant(Data("true".utf8)))
        #expect(RemoteGroupCallAPI.wasLastParticipant(Data(#"{"remainingParticipants":0}"#.utf8)))
        #expect(!RemoteGroupCallAPI.wasLastParticipant(Data(#"{"lastParticipant":false}"#.utf8)))
        #expect(!RemoteGroupCallAPI.wasLastParticipant(Data()))
    }

    @Test("последний участник группового звонка сообщает итог")
    func groupSummary() async {
        let api = FakeGroupCallAPI()
        await api.setLastOnLeave(true)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let model = GroupCallModel(me: CallParticipant(userId: "me", name: "Я", username: "@me"), api: api, rtcUrl: URL(string: "wss://x")!, makeRoom: { FakeCallRoom() }, sessionId: { nil }, requestMicrophone: { true }, now: { clock.now }, sleep: { _ in await Task.yield() })
        var reports: [CallSummaryReport] = []
        model.onCallSummary = { reports.append($0) }
        await model.start(groupChatId: "chat", name: "G", memberUserIds: ["u2"])
        // Кто-то вошёл: хост не удаляет звонок, а выходит.
        for _ in 0..<200 where !(await api.hasCallSubscriber("group-call-1")) { await Task.yield() }
        await api.pushCallEvent(GroupCallEvent(kind: .join, groupCallId: "group-call-1", participantUserId: "u2"))
        for _ in 0..<40 { await Task.yield() }
        clock.now = clock.now.addingTimeInterval(95)
        await model.hangUp()
        #expect(reports.count == 1)
        #expect(reports.first?.isGroup == true)
        #expect(reports.first?.roomId == "chat")
        #expect(reports.first?.durationSeconds == 95)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
