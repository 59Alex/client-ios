import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectSettings
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
@Suite("Оформление")
struct AppearanceTests {
    @Test("палитры и производные цвета совпадают с resolveAppearance")
    func resolvedColors() {
        let dracula = ThemeColors(AppearancePreferences(theme: .dracula))
        #expect(dracula.editorBackground == "#282A36")
        #expect(dracula.accent == "#BD93F9")
        #expect(dracula.own == "#44475A")
        #expect(dracula.other == "#282A36")
        #expect(dracula.onAccent == "#000000")
        #expect(dracula.onOwn == "#FFFFFF")
        #expect(dracula.buttonRadius == 8 && dracula.modalRadius == 8)

        let light = ThemeColors(AppearancePreferences(theme: .light))
        #expect(light.own == "#DCE5FA")
        #expect(light.canvas == "#E8ECF2")
        #expect(light.raised == "#FFFFFF")
        #expect(light.onOwn == "#000000")
        #expect(light.isLight)
        #expect(light.panelRadius == 16)

        let gothic = ThemeColors(AppearancePreferences(theme: .gothic))
        #expect(gothic.own == "#353027")
        #expect(gothic.panel == "#1D2025")
        #expect(gothic.accent == "#F4C967")

        let cathedral = ThemeColors(AppearancePreferences(theme: .cathedral))
        #expect(cathedral.canvas == "#040506")
        #expect(cathedral.line == "#383D46")
    }

    @Test("свой цвет подсветки заменяет purple, cyan и pink")
    func accentOverride() {
        let colors = ThemeColors(AppearancePreferences(theme: .dark, accentColor: "#FF0000", pressColor: "#FFFFFF"))
        #expect(colors.accent == "#FF0000")
        #expect(colors.purple == "#FF0000" && colors.cyan == "#FF0000" && colors.pink == "#FF0000")
        #expect(colors.green == "#7DE2AC")
        #expect(colors.press == "#FFFFFF")
        #expect(colors.onPress == "#000000")
    }

    @Test("смешивание и контраст")
    func hex() {
        #expect(HexColor.mix("#FFFFFF", 0.5, "#000000") == "#808080")
        #expect(HexColor.mix("#282A36", 0.95, "#000000") == "#262833")
        #expect(HexColor.textOn("#FFFFFF") == "#000000")
        #expect(HexColor.textOn("#141821") == "#FFFFFF")
        #expect(!HexColor.isValid("#12345"))
        #expect(!HexColor.isValid("red"))
    }

    @Test("разбор: неизвестная тема и неверный цвет заменяются умолчаниями, пустые цвета уходят null")
    func coding() throws {
        let json = ##"{"theme":"neon","background":"plain","accentColor":"blue","pressColor":"#00FF00","reducedMotion":true}"##
        let preferences = try JSONDecoder().decode(AppearancePreferences.self, from: Data(json.utf8))
        #expect(preferences.theme == .dark)
        #expect(preferences.background == "plain")
        #expect(preferences.accentColor == nil)
        #expect(preferences.pressColor == "#00FF00")
        #expect(preferences.reducedMotion)

        let encoded = String(decoding: try JSONEncoder().encode(AppearancePreferences.standard), as: UTF8.self)
        #expect(encoded.contains(#""accentColor":null"#))
        #expect(encoded.contains(#""desktopBackground":null"#))
        #expect(encoded.contains(#""theme":"dark""#))
    }

    @Test("выбор темы сбрасывает цвета, ставит первый фон галереи и сохраняет «меньше анимации»")
    func selectingTheme() {
        let current = AppearancePreferences(theme: .dark, accentColor: "#123456", reducedMotion: true)
        let next = current.selecting(.gothic)
        #expect(next.theme == .gothic)
        #expect(next.accentColor == nil)
        #expect(next.background == "pin1031605858416701040")
        #expect(next.desktopBackground == "plain")
        #expect(next.reducedMotion)
        #expect(current.selecting(.dracula).desktopBackground == "pin1031605858416702611")
    }

    @Test("вход читает запись устройства, правка уходит с ревизией и сохраняется локально")
    func syncChange() async {
        let api = FakeAppearanceAPI(preferences: AppearancePreferences(theme: .light, background: "plain"), revision: 4)
        let store = MemoryAppearanceStore()
        let model = AppearanceModel(api: api, store: store)
        #expect(model.draft == .standard)

        await model.start(deviceId: "device-1")
        #expect(model.state == .ready)
        #expect(model.draft.theme == .light)
        #expect(store.load()?.theme == .light)
        #expect(await api.deviceIds == ["device-1"])

        model.selectTheme(.dracula)
        #expect(model.draft.theme == .dracula)
        #expect(model.state == .saving)
        await model.flush()
        #expect(model.state == .ready)
        let puts = await api.puts
        #expect(puts.count == 1)
        #expect(puts.first?.revision == 4)
        #expect(puts.first?.preferences.theme == .dracula)
        #expect(await api.stored.revision == 5)
        #expect(store.load()?.theme == .dracula)
    }

    @Test("409: запись перечитывается, правка ложится поверх изменений другого устройства")
    func conflict() async {
        let api = FakeAppearanceAPI(revision: 1)
        let model = AppearanceModel(api: api, store: MemoryAppearanceStore())
        await model.start(deviceId: "device-1")

        await api.externalUpdate(AppearancePreferences(theme: .dark, reducedMotion: true))
        var next = model.draft
        next.accentColor = "#FF0000"
        model.change(next)
        await model.flush()

        #expect(model.state == .ready)
        let stored = await api.stored
        #expect(stored.preferences.accentColor == "#FF0000")
        #expect(stored.preferences.reducedMotion)
        #expect(await api.puts.map(\.revision) == [1, 2])
        #expect(model.draft.reducedMotion)
    }

    @Test("ошибка сети оставляет черновик, повтор отправляет правку")
    func retryAfterError() async {
        let api = FakeAppearanceAPI(revision: 0)
        await api.setFailGets(true)
        let store = MemoryAppearanceStore(AppearancePreferences(theme: .cathedral))
        let model = AppearanceModel(api: api, store: store)
        #expect(model.draft.theme == .cathedral)

        await model.start(deviceId: nil)
        #expect(model.state == .error)
        model.selectTheme(.monochrome)
        await model.flush()
        #expect(model.state == .error)
        #expect(model.draft.theme == .monochrome)

        await api.setFailGets(false)
        await model.flush()
        #expect(model.state == .ready)
        #expect(await api.stored.preferences.theme == .monochrome)
    }

    @Test("запрос: deviceId в параметре, пустой не отправляется, PUT с телом")
    func remoteRequests() async throws {
        #expect(RemoteAppearanceAPI.path("undefined") == "/api/appearance")
        #expect(RemoteAppearanceAPI.path(nil) == "/api/appearance")
        #expect(RemoteAppearanceAPI.path("a b") == "/api/appearance?deviceId=a%20b")

        let transport = StubTransport()
        let body = #"{"preferences":{"theme":"gothic","background":"plain","reducedMotion":false},"revision":3}"#
        transport.on("/api/appearance", json: body)
        let api = RemoteAppearanceAPI(settings: HTTPClient(baseURL: URL(string: "https://settings.example")!, transport: transport))
        let loaded = try await api.appearance(deviceId: "dev-1")
        #expect(loaded.preferences.theme == .gothic)
        #expect(loaded.revision == 3)
        _ = try await api.updateAppearance(loaded, deviceId: "dev-1")
        let put = try #require(transport.requests.last)
        #expect(put.httpMethod == "PUT")
        #expect(put.url?.query == "deviceId=dev-1")
        let sent = try JSONDecoder().decode(AppearanceSettings.self, from: try #require(put.httpBody))
        #expect(sent == loaded)
    }
}
