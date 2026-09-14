import Foundation
import Testing
@testable import ConnectCalls

@Suite("Протокол комнаты, совместимый с веб-клиентом")
struct CallProtocolTests {
    @Test("имя дорожки кодируется короткими ключами k/c/t/a/v")
    func trackNameEncoding() throws {
        let name = TrackName(key: "k-1", clientData: "cd", createdAtMilliseconds: 1_757_750_000_000, hasAudio: true, hasVideo: false)
        let object = try #require(JSONSerialization.jsonObject(with: Data(name.encoded().utf8)) as? [String: Any])

        #expect(object["k"] as? String == "k-1")
        #expect(object["c"] as? String == "cd")
        #expect((object["t"] as? NSNumber)?.int64Value == 1_757_750_000_000)
        #expect(object["a"] as? Bool == true)
        #expect(object["v"] as? Bool == false)
        #expect(TrackName.decode(name.encoded()) == name)
    }

    @Test("дорожки не из протокола Connect игнорируются", arguments: ["microphone", "{\"c\":\"x\"}", ""])
    func foreignTrackNames(raw: String) {
        #expect(TrackName.decode(raw) == nil)
    }

    @Test("имя дорожки веб-клиента разбирается")
    func webTrackName() throws {
        let raw = #"{"k":"0b8f","c":"{\"clientData\":\"{\\\"userId\\\":\\\"u-1\\\",\\\"username\\\":\\\"ivan\\\",\\\"sessionId\\\":\\\"s-1\\\"}\"}","t":1757750000000,"a":true,"v":false}"#
        let name = try #require(TrackName.decode(raw))
        #expect(name.hasAudio && !name.hasVideo)
        #expect(CallClientData.decode(name.clientData) == CallClientData(userId: "u-1", username: "ivan", sessionId: "s-1"))
    }

    @Test("клиентские данные обёрнуты в clientData, как у веб-клиента")
    func clientDataEnvelope() throws {
        let encoded = CallClientData(userId: "u-1", username: "@ivan", sessionId: nil).encoded()
        let outer = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let inner = try #require(outer["clientData"] as? String)
        let innerObject = try #require(JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any])

        #expect(innerObject["userId"] as? String == "u-1")
        #expect(innerObject["username"] as? String == "@ivan")
        #expect(innerObject["sessionId"] == nil)
    }

    @Test("клиентские данные читаются в формате CLIENT%/%SERVER и без обёртки")
    func clientDataVariants() {
        let expected = CallClientData(userId: "u-2", username: nil, sessionId: nil)
        #expect(CallClientData.decode(expected.encoded() + "%/%server-metadata") == expected)
        #expect(CallClientData.decode(#"{"userId":"u-2"}"#) == expected)
        #expect(CallClientData.decode("not json") == nil)
    }

    @Test("сигналы mute, speakerOff и speak совпадают с useP2pCall.ts")
    func signals() throws {
        let packet = CallSignal.microphoneMuted(userId: "u-1", muted: true).packet(client: "client")
        #expect(packet.type == "mute")
        let body = try #require(JSONSerialization.jsonObject(with: Data(packet.data.utf8)) as? [String: Any])
        #expect(body["userId"] as? String == "u-1")
        #expect(body["muted"] as? Bool == true)
        #expect(body["type"] as? String == "MIC")

        let wire = try #require(SignalPacket.decode(packet.encoded()))
        #expect(wire == packet)
        #expect(CallSignal(packet: wire) == .microphoneMuted(userId: "u-1", muted: true))

        let speaker = CallSignal.speakerOff(userId: "u-1", muted: false).packet(client: "")
        #expect(CallSignal(packet: speaker) == .speakerOff(userId: "u-1", muted: false))
        #expect(speaker.data.contains("\"SPEAK\""))

        let speak = CallSignal.speaking(userId: "u-1", speaking: true).packet(client: "")
        #expect(speak.type == "speak")
        #expect(CallSignal(packet: speak) == .speaking(userId: "u-1", speaking: true))
    }

    @Test("сигнал веб-клиента разбирается, чужие типы пропускаются")
    func webSignal() throws {
        let raw = #"{"type":"mute","data":"{\"userId\":\"web\",\"muted\":false,\"type\":\"MIC\"}","client":"x"}"#
        let packet = try #require(SignalPacket.decode(Data(raw.utf8)))
        #expect(CallSignal(packet: packet) == .microphoneMuted(userId: "web", muted: false))
        #expect(CallSignal(packet: SignalPacket(type: "chat", data: "{}", client: "")) == nil)
    }

    @Test("события SSE звонков разбираются с любым полем идентификатора")
    func callEvents() {
        #expect(P2PCallEvent.decode(#"{"type":"CALL","id":"c-1","callerUserId":"a","calleeUserId":"b"}"#)
            == .call(callId: "c-1", callerUserId: "a", calleeUserId: "b"))
        #expect(P2PCallEvent.decode(#"{"type":"CANCEL","p2pCallId":"c-1","callerUserId":"a","calleeUserId":"b"}"#)
            == .cancel(callId: "c-1", callerUserId: "a", calleeUserId: "b"))
        #expect(P2PCallEvent.decode(#"{"type":"CALL","callerUserId":"a","calleeUserId":"b"}"#)
            == .call(callId: nil, callerUserId: "a", calleeUserId: "b"))
        #expect(P2PCallEvent.decode(#"{"type":"PING"}"#) == nil)
    }
}

@Suite("Сборка дорожек в потоки")
struct RemoteStreamTrackerTests {
    private func name(key: String, audio: Bool, video: Bool, userId: String = "peer") -> String {
        TrackName(
            key: key,
            clientData: CallClientData(userId: userId, username: nil, sessionId: nil).encoded(),
            createdAtMilliseconds: 0,
            hasAudio: audio,
            hasVideo: video
        ).encoded()
    }

    @Test("аудиопоток объявляется сразу и пропадает с последней дорожкой")
    func audioStream() {
        var tracker = RemoteStreamTracker()
        let added = tracker.handle(.trackPublished(participant: "p", trackId: "t1", name: name(key: "s", audio: true, video: false), kind: .audio))
        guard case let .added(stream)? = added.first else {
            Issue.record("поток не объявлен")
            return
        }
        #expect(stream.clientData?.userId == "peer")
        #expect(tracker.handle(.trackUnpublished(participant: "p", trackId: "t1")) == [.removed(stream)])
    }

    @Test("поток с видео ждёт обе дорожки")
    func waitsForAllKinds() {
        var tracker = RemoteStreamTracker()
        let raw = name(key: "cam", audio: true, video: true)
        #expect(tracker.handle(.trackPublished(participant: "p", trackId: "a", name: raw, kind: .audio)).isEmpty)
        #expect(tracker.handle(.trackPublished(participant: "p", trackId: "v", name: raw, kind: .video)).count == 1)
        #expect(tracker.handle(.trackUnpublished(participant: "p", trackId: "a")).isEmpty)
        #expect(tracker.handle(.trackUnpublished(participant: "p", trackId: "v")).count == 1)
    }

    @Test("уход участника и разрыв снимают объявленные потоки")
    func participantLeft() {
        var tracker = RemoteStreamTracker()
        _ = tracker.handle(.trackPublished(participant: "p", trackId: "t1", name: name(key: "s", audio: true, video: false), kind: .audio))
        #expect(tracker.handle(.participantLeft(participant: "p")).count == 1)

        _ = tracker.handle(.trackPublished(participant: "q", trackId: "t2", name: name(key: "s", audio: true, video: false), kind: .audio))
        #expect(tracker.handle(.disconnected(networkLoss: false)).count == 1)
    }

    @Test("дорожки с чужим именем не создают поток")
    func ignoresForeignTracks() {
        var tracker = RemoteStreamTracker()
        #expect(tracker.handle(.trackPublished(participant: "p", trackId: "t", name: "microphone", kind: .audio)).isEmpty)
    }
}

@Suite("Трансляции камеры и экрана")
struct RemoteSharesTests {
    private func share(userId: String, type: String, key: String, trackId: String, createdAt: Int64, participant: String = "s") -> CallRoomEvent {
        let name = TrackName(
            key: key,
            clientData: CallClientData(userId: userId, username: "u", sessionId: nil, streamType: "SHARE", streamId: key, shareType: type).encoded(),
            createdAtMilliseconds: createdAt,
            hasAudio: false,
            hasVideo: true
        )
        return .trackPublished(participant: participant, trackId: trackId, name: name.encoded(), kind: .video)
    }

    @Test("клиентские данные трансляции веба разбираются, у голоса полей трансляции нет")
    func clientData() {
        let web = #"{"clientData":"{\"streamType\":\"SHARE\",\"streamId\":\"x\",\"shareType\":\"SHARE_DISPLAY\",\"userId\":\"u1\",\"username\":\"ivan\"}"}"#
        let parsed = CallClientData.decode(web)
        #expect(parsed?.shareType == "SHARE_DISPLAY")
        #expect(parsed?.streamType == "SHARE")
        #expect(!CallClientData(userId: "me", username: "me", sessionId: nil).encoded().contains("streamType"))
    }

    @Test("камера и экран отдельно, новая камера того же пользователя заменяет старую, своя не показывается")
    func newestPerKind() {
        var tracker = RemoteStreamTracker()
        var shares = RemoteShares()
        func feed(_ event: CallRoomEvent) { tracker.handle(event).forEach { shares.apply($0, me: "me") } }

        feed(share(userId: "u1", type: "WEB_CAMERA", key: "cam1", trackId: "v1", createdAt: 10))
        feed(share(userId: "u1", type: "SHARE_DISPLAY", key: "scr", trackId: "v2", createdAt: 11))
        feed(share(userId: "me", type: "WEB_CAMERA", key: "mine", trackId: "v3", createdAt: 12))
        #expect(shares.items.map(\.id) == ["u1-WEB_CAMERA", "u1-SHARE_DISPLAY"])
        #expect(shares.items.first?.trackId == "v1")

        feed(share(userId: "u1", type: "WEB_CAMERA", key: "cam2", trackId: "v4", createdAt: 20, participant: "s2"))
        #expect(shares.items.first { $0.kind == .camera }?.trackId == "v4")
        feed(.trackUnpublished(participant: "s", trackId: "v1"))
        #expect(shares.items.first { $0.kind == .camera }?.trackId == "v4")

        feed(.trackUnpublished(participant: "s", trackId: "v2"))
        #expect(shares.items.map(\.kind) == [.camera])
    }
}
