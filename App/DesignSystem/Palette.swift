import ConnectSettings
import Foundation
import SwiftUI

/// Текущее оформление приложения. Цвета читаются из наблюдаемой модели,
/// поэтому смена темы перерисовывает все экраны без передачи окружения.
@MainActor
enum AppTheme {
    private(set) static var appearance = AppearanceModel(api: DisabledAppearanceAPI(), store: MemoryAppearanceStoreFallback())

    static var colors: ThemeColors { appearance.colors }

    static func use(_ model: AppearanceModel) {
        appearance = model
    }

    /// Логотип темы (`THEME_LOGOS`): Dracula — свой, Dark — серебро, Дубай — прежний, остальные — белый.
    static var logoName: String {
        switch colors.theme {
        case .dracula: "LogoDracula"
        case .dark: "LogoSilver"
        case .gothic: "LogoGothic"
        case .monochrome, .light, .cathedral: "LogoWhite"
        }
    }
}

/// Роли цветов веб-клиента (`resolveAppearance`, `features/appearance/surfaces.css`).
@MainActor
enum Palette {
    private static var c: ThemeColors { AppTheme.colors }

    /// Фон списков и содержимого — `currentLine`.
    static var canvas: Color { Color(themeHex: c.currentLine) }
    /// Шапки, рейл комнат, поля и карточки — `editorBackground`.
    static var surface: Color { Color(themeHex: c.editorBackground) }
    static var chrome: Color { Color(themeHex: c.editorBackground) }
    /// Выделенная строка: текст 12% поверх `currentLine`.
    static var selected: Color { Color(themeHex: HexColor.mix(c.text, 0.12, c.currentLine)) }
    /// Панель пользователя внизу: между фоном и содержимым.
    static var panel: Color { Color(themeHex: HexColor.mix(c.editorBackground, 0.35, c.currentLine)) }
    static var textPrimary: Color { Color(themeHex: c.text) }
    static var textSecondary: Color { Color(themeHex: c.comment) }
    static var accent: Color { Color(themeHex: c.accent) }
    static var onAccent: Color { Color(themeHex: c.onAccent) }
    static var danger: Color { Color(themeHex: c.red) }
    static var success: Color { Color(themeHex: c.green) }
    static var info: Color { Color(themeHex: c.cyan) }
    /// Граница: текст 14% поверх содержимого, видна и там, где `line` совпадает с фоном.
    static var border: Color { Color(themeHex: HexColor.mix(c.text, 0.14, c.currentLine)) }
    static var divider: Color { Color(themeHex: c.text).opacity(0.1) }
    static var press: Color { Color(themeHex: c.press) }
    static var onPress: Color { Color(themeHex: c.onPress) }
    static var chat: Color { Color(themeHex: c.chat) }
    static var ownBubble: Color { Color(themeHex: c.own) }
    static var onOwnBubble: Color { Color(themeHex: c.onOwn) }
    static var otherBubble: Color { Color(themeHex: c.other) }
    static var onOtherBubble: Color { Color(themeHex: c.onOther) }
    static var messageName: Color { Color(themeHex: c.messageName) }
    static var ownMessageName: Color { Color(themeHex: c.ownMessageName) }
    static var roomName: Color { Color(themeHex: c.roomName) }
    /// Созвон: зелёная заливка кнопки звонка в шапке чата.
    static var callFill: Color { Color(themeHex: HexColor.mix(c.green, 0.22, c.editorBackground)) }

    static var colorScheme: ColorScheme { c.isLight ? .light : .dark }
}

/// Радиусы темы: у Dracula 8/8/8, у остальных кнопка 12, панель 16, модальное окно 24.
@MainActor
enum Radius {
    static var button: CGFloat { CGFloat(AppTheme.colors.buttonRadius) }
    static var panel: CGFloat { CGFloat(AppTheme.colors.panelRadius) }
    static var modal: CGFloat { CGFloat(AppTheme.colors.modalRadius) }
}

extension Color {
    /// Цвет `#RRGGBB` из палитры темы; некорректная строка даёт чёрный.
    init(themeHex: String) {
        let parts = HexColor.components(themeHex)
        self.init(.sRGB, red: Double(parts.red) / 255, green: Double(parts.green) / 255, blue: Double(parts.blue) / 255)
    }
}

/// До сборки зависимостей оформление не синхронизируется.
private struct DisabledAppearanceAPI: AppearanceAPI {
    func appearance(deviceId: String?) async throws -> AppearanceSettings {
        throw CancellationError()
    }

    func updateAppearance(_ settings: AppearanceSettings, deviceId: String?) async throws -> AppearanceSettings {
        throw CancellationError()
    }
}

private struct MemoryAppearanceStoreFallback: AppearanceStore {
    func load() -> AppearancePreferences? { nil }
    func save(_ preferences: AppearancePreferences) {}
}

/// Оформление устройства в UserDefaults (`connect.appearance.preferences`, как localStorage веба).
struct DeviceAppearanceStore: AppearanceStore {
    static let key = "connect.appearance.preferences"

    func load() -> AppearancePreferences? {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(AppearancePreferences.self, from: data)
    }

    func save(_ preferences: AppearancePreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
