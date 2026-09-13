import ConnectCore
import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectFeatures

@MainActor
@Suite("Контакты")
struct ContactsModelTests {
    @Test("карточка контакта читает userId или id, аватар из S3 и lastSeenAt")
    func decoding() throws {
        let json = #"""
        [{"id":"card-1","name":"  ","username":"@@ivan","status":"ONLINE","avatarUrl":"old","avatarUrlS3":"avatars/1.png","lastSeenAt":"2026-09-13T10:00:00.123Z"},
         {"userId":"u-2","name":"Мария","username":"maria","status":"WEIRD"}]
        """#
        let contacts = try JSONDecoder().decode([Contact].self, from: Data(json.utf8))

        #expect(contacts[0].userId == "card-1")
        #expect(contacts[0].displayName == "@ivan")
        #expect(contacts[0].avatarKey == "avatars/1.png")
        #expect(contacts[0].lastSeenAt != nil)
        #expect(contacts[1].status == .offline)
        #expect(contacts[1].lastSeenAt == nil)
    }

    @Test("сортировка: в сети, затем недавние, затем по имени")
    func sorting() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        let sorted = ContactsModel.sorted([
            Contact(userId: "b", name: "Борис", username: "b"),
            Contact(userId: "old", name: "Олег", username: "o", lastSeenAt: old),
            Contact(userId: "a", name: "Анна", username: "a"),
            Contact(userId: "online", name: "Яна", username: "y", status: .online),
            Contact(userId: "recent", name: "Павел", username: "p", lastSeenAt: recent),
        ])
        #expect(sorted.map(\.userId) == ["online", "recent", "old", "a", "b"])
    }

    @Test("загрузка контактов текущего пользователя")
    func loads() async throws {
        let transport = StubTransport()
        transport.on("/api/user-card/get-contacts/me", json: #"[{"userId":"u-1","name":"Иван","username":"ivan","status":"OFFLINE"}]"#)
        let client = HTTPClient(baseURL: try #require(URL(string: "https://domain.cnnect.ru")), transport: transport)
        let model = ContactsModel(userId: "me", repository: RemoteContactsRepository(client: client))

        await model.load()

        #expect(model.state == .loaded([Contact(userId: "u-1", name: "Иван", username: "ivan")]))
    }

    @Test("ошибка сети без загруженного списка показывает сообщение")
    func failure() async throws {
        let transport = StubTransport()
        let client = HTTPClient(baseURL: try #require(URL(string: "https://domain.cnnect.ru")), transport: transport)
        let model = ContactsModel(userId: "me", repository: RemoteContactsRepository(client: client))

        await model.load()

        #expect(model.state == .failed("Не удалось загрузить контакты"))
    }
}
