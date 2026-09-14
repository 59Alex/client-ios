import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectCalls
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Встречи")
struct MeetingsTests {
    private let code = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde"

    @Test("код из ссылки и сам код; чужие ссылки и неверная длина отбрасываются")
    func links() {
        #expect(code.count == 43)
        #expect(MeetingLinks.code(from: "https://cnnect.ru/share/meet/\(code)") == code)
        #expect(MeetingLinks.code(from: " https://cnnect.ru/share/meet/\(code)?auth=login ") == code)
        #expect(MeetingLinks.code(from: code) == code)
        #expect(MeetingLinks.code(from: "https://cnnect.ru/invite/abc") == nil)
        #expect(MeetingLinks.code(from: "https://cnnect.ru/share/meet/short") == nil)
        #expect(MeetingLinks.url(origin: URL(string: "https://cnnect.ru")!, code: code).absoluteString == "https://cnnect.ru/share/meet/\(code)")
    }

    @Test("статусы сервиса превращаются в понятные ошибки")
    func errors() async throws {
        let transport = StubTransport()
        transport.on("/api/meetings/invitations", status: 404, json: "")
        transport.on("/api/meetings/accept", json: #"{"groupId":"g1","callId":"c1","active":true}"#)
        let api = RemoteMeetingsAPI(main: HTTPClient(baseURL: URL(string: "https://main.example")!, transport: transport))

        await #expect(throws: MeetingError.disabled) { try await api.createInvitation(groupId: "g1", callId: "c1") }
        let accepted = try await api.accept(code: code)
        #expect(accepted == MeetingAcceptance(groupId: "g1", callId: "c1", active: true))
        #expect(MeetingError.from(status: 403, creating: true) == .forbidden)
        #expect(MeetingError.from(status: 410, creating: false) == .expired)
        #expect(MeetingError.from(status: 429, creating: false) == .tooMany)
    }

    @Test("ведущий получает ссылку идущего звонка, ошибка показывается текстом")
    @MainActor
    func hostLink() async throws {
        let callAPI = FakeGroupCallAPI()
        let model = GroupCallModel(me: CallParticipant(userId: "me", name: "Я", username: "@me"), api: callAPI, rtcUrl: URL(string: "wss://x")!, makeRoom: { FakeCallRoom() }, sessionId: { nil }, requestMicrophone: { true }, sleep: { _ in await Task.yield() })
        await model.start(groupChatId: "g1", name: "Группа", memberUserIds: ["me", "u2"])
        let meetings = FakeMeetingsAPI()

        await model.createGuestLink(api: meetings, origin: URL(string: "https://cnnect.ru")!)
        #expect(model.guestLink == "https://cnnect.ru/share/meet/\(String(repeating: "a", count: 43))")
        #expect(await meetings.invitations.first?.groupId == "g1")

        await meetings.setFailure(.forbidden)
        await model.createGuestLink(api: meetings, origin: URL(string: "https://cnnect.ru")!)
        #expect(model.guestLinkError == MeetingError.forbidden.message)
    }
}

@MainActor
@Suite("Гость на встрече")
struct GuestMeetingTests {
    private let link = "https://cnnect.ru/share/meet/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde"

    private func makeModel(api: FakeGuestMeetingAPI, rooms: GuestRooms, microphone: Bool = true) -> GuestMeetingModel {
        GuestMeetingModel(api: api, rtcUrl: URL(string: "wss://rtc.cnnect.ru")!, makeRoom: {
            let room = FakeCallRoom()
            rooms.items.append(room)
            return room
        }, requestMicrophone: { microphone }, sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
    }

    @Test("проверка ссылки и имени до запроса")
    func validation() async {
        let api = FakeGuestMeetingAPI()
        let model = makeModel(api: api, rooms: GuestRooms())
        #expect(await model.join(link: "https://cnnect.ru/invite/x", displayName: "Гость") == "Вставьте ссылку на встречу")
        #expect(await model.join(link: link, displayName: "   ") == "Укажите, как вас называть")
        #expect(await model.join(link: link, displayName: String(repeating: "я", count: 81)) == "Имя не длиннее 80 символов")
        #expect(await api.joined.isEmpty)
    }

    @Test("вход: голос с данными гостя, сообщения, отправка, выход закрывает сессию")
    func flow() async throws {
        let api = FakeGuestMeetingAPI()
        let rooms = GuestRooms()
        let model = makeModel(api: api, rooms: rooms)

        #expect(await model.join(link: link, displayName: " Иван ") == nil)
        #expect(model.phase == .active)
        #expect(model.title == "QA Group")
        let room = try #require(rooms.items.first)
        #expect(room.token == "voice-token")
        let rawName = try #require(room.publishedTrackName)
        let name = try #require(TrackName.decode(rawName))
        #expect(CallClientData.decode(name.clientData)?.userId == "guest:1")
        #expect(CallClientData.decode(name.clientData)?.username == "Иван")
        #expect(await api.joined.first?.name == "Иван")

        for _ in 0..<100 where model.messages.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.messages.first?.message == "Добро пожаловать на встречу")

        model.draft = "Всем привет"
        await model.send()
        #expect(await api.sent == ["Всем привет"])
        #expect(model.messages.last?.message == "Всем привет")

        await model.leave()
        #expect(model.phase == .idle)
        #expect(room.isDisconnected)
        #expect(await api.leftTokens == ["session-token"])
    }

    @Test("звонок завершился — гость видит это и выходит; ошибка ссылки показывается текстом")
    func ended() async throws {
        let api = FakeGuestMeetingAPI()
        let model = makeModel(api: api, rooms: GuestRooms())
        _ = await model.join(link: link, displayName: "Иван")
        await api.setActive(false)
        for _ in 0..<200 where model.phase == .active { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.phase == .ended("Звонок завершён"))

        let failing = FakeGuestMeetingAPI()
        await failing.setFailure(.expired)
        let other = makeModel(api: failing, rooms: GuestRooms())
        #expect(await other.join(link: link, displayName: "Иван") == MeetingError.expired.message)
    }
}

@MainActor
final class GuestRooms {
    var items: [FakeCallRoom] = []
}
