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

@MainActor
@Suite("Действия с контактами")
struct ContactActionsTests {
    @Test("запрос поиска: логин с одним @, телефон в формате +7 (999) 123-45-67", arguments: [
        ("ivan", ContactQuery.login("@ivan")),
        ("@@ivan", .login("@ivan")),
        ("8 999 123-45-67", .phone("+7 (999) 123-45-67")),
        ("+7(999)1234567", .phone("+7 (999) 123-45-67")),
        ("9991234567", .phone("+7 (999) 123-45-67")),
    ])
    func queries(raw: String, expected: ContactQuery) {
        #expect(ContactQuery(raw) == expected)
    }

    @Test("неполный телефон и пустой запрос не ищутся")
    func invalidQueries() {
        #expect(ContactQuery("12-34") == nil)
        #expect(ContactQuery("  ") == nil)
        #expect(ContactQuery("@") == nil)
    }

    @Test("поиск по логину кодирует @ и кириллицу в пути, 404 — не найден")
    func remoteSearch() async throws {
        let transport = StubTransport()
        transport.on("/api/user-card/search-by-login/@иван") { _ in HTTPResponse(statusCode: 404, body: Data()) }
        let client = HTTPClient(baseURL: try #require(URL(string: "https://domain.cnnect.ru")), transport: transport)
        let repository = RemoteContactsRepository(client: client)

        let result = try await repository.search(.login("@иван"))

        #expect(result == nil)
        let url = try #require(transport.requests.first?.url?.absoluteString)
        #expect(url.hasSuffix("/search-by-login/%40%D0%B8%D0%B2%D0%B0%D0%BD"))
    }

    @Test("найти, добавить и удалить контакт")
    func searchAddRemove() async {
        let ivan = Contact(userId: "u-ivan", name: "Иван", username: "ivan", status: .online)
        let repository = FakeContactsRepository(contacts: ["me": []], directory: [ivan, Contact(userId: "me", name: "Я", username: "me")])
        let model = ContactsModel(userId: "me", repository: repository)
        await model.load()

        model.searchText = "@ivan"
        await model.search()
        #expect(model.searchResult == .found(ivan))
        #expect(!model.isContact(ivan))

        #expect(await model.add(ivan))
        #expect(model.state == .loaded([ivan]))
        #expect(model.searchResult == .idle)
        #expect(await repository.contactsByUser["me"] == [ivan])

        #expect(await model.remove(ivan))
        #expect(model.state == .loaded([]))

        model.searchText = "me"
        await model.search()
        if case let .found(me) = model.searchResult {
            #expect(!(await model.add(me)))
        }
        model.searchText = "nobody"
        await model.search()
        #expect(model.searchResult == .notFound)
    }

    @Test("фото профиля: аватар первым, без повторов")
    func photoKeys() {
        var contact = Contact(userId: "u", name: "", username: "u", avatarKey: "a")
        contact.gallery = ["b", "a", "", "c"]
        #expect(contact.photoKeys == ["a", "b", "c"])
    }
}
