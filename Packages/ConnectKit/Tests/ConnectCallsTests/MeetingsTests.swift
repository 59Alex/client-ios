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
