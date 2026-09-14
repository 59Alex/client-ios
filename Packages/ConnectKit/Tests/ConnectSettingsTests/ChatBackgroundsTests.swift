import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectSettings
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
@Suite("Фоны чата")
struct ChatBackgroundsTests {
    @Test("список по платформе без токена, адрес картинки от сервиса S3")
    func remote() async throws {
        let transport = StubTransport()
        transport.on("/api/backgrounds", json: #"{"version":1,"platform":"mobile","themes":[{"theme":"dark","defaultBackground":"pin1","backgrounds":[{"id":"pin1","name":"Чёрная дыра","position":"50% 40%","rotation":0,"width":null,"height":null,"imageUrl":"/api/backgrounds/pin1/image"}]}]}"#)
        let api = RemoteBackgroundsAPI(s3: HTTPClient(baseURL: URL(string: "https://s3.example/")!, transport: transport))

        let list = try await api.backgrounds(platform: .mobile)

        #expect(transport.requests.last?.url?.query == "platform=mobile")
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
        let background = try #require(list.themes.first?.backgrounds.first)
        #expect(background.name == "Чёрная дыра")
        #expect(api.imageURL(for: background)?.absoluteString == "https://s3.example/api/backgrounds/pin1/image")
    }

    @Test("точка кадрирования из CSS")
    func focus() {
        func focus(_ position: String) -> [Double] {
            let value = ChatBackground(id: "a", name: "a", position: position, imageUrl: "").focus
            return [value.x, value.y]
        }
        #expect(focus("50% 40%") == [0.5, 0.4])
        #expect(focus("center") == [0.5, 0.5])
        #expect(focus("left top") == [0, 0])
        #expect(focus("130% x") == [1, 0.5])
    }

    @Test("выбор фона: plain однотонный, чужой фон заменяется первым фоном темы")
    func resolve() async {
        let model = ChatBackgroundsModel(api: FakeBackgroundsAPI())
        #expect(model.background(for: .standard) == nil)
        await model.load()

        #expect(model.background(for: .standard)?.id == "pin1031605858416701070")
        #expect(model.background(for: AppearancePreferences(theme: .dark, background: "plain")) == nil)
        #expect(model.background(for: AppearancePreferences(theme: .dark, background: "pin1031605858416701083"))?.id == "pin1031605858416701083")
        #expect(model.background(for: AppearancePreferences(theme: .gothic, background: "pin1031605858416701083"))?.id == "pin1031605858416701040")
        #expect(model.gallery(for: .light).count == 4)
    }

    @Test("ошибка загрузки помечается, выбор фона уходит в оформление")
    func failureAndSelect() async {
        let failing = ChatBackgroundsModel(api: FakeBackgroundsAPI(fail: true))
        await failing.load()
        #expect(failing.failed)
        #expect(failing.gallery(for: .dark).isEmpty)

        let api = FakeAppearanceAPI()
        let appearance = AppearanceModel(api: api, store: MemoryAppearanceStore())
        await appearance.start(deviceId: "d")
        appearance.selectBackground("plain")
        await appearance.flush()
        #expect(await api.stored.preferences.background == "plain")
    }
}
