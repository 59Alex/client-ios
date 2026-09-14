import ConnectNetworking
import Foundation

/// Тема интерфейса веб-клиента (`components/func/Theme.ts`). Порядок — как в выборе тем.
public enum AppearanceTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case monochrome, dracula, light, dark, gothic, cathedral

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .monochrome: "Чёрно-белая"
        case .dracula: "Dracula"
        case .light: "Светлая"
        case .dark: "Dark"
        case .gothic: "Дубай"
        case .cathedral: "Готика"
        }
    }

    /// Фоны чата темы для телефона (`THEME_GALLERIES`); первый выбирается вместе с темой.
    public var gallery: [String] {
        switch self {
        case .monochrome, .light: ["pin1031605858416701128", "pin1031605858416701130", "pin1031605858416701142", "pin1031605858416701132"]
        case .dracula: ["pin1031605858416701164", "pin1031605858416700989", "pin1031605858416700983", "pin1031605858416701003", "pin1031605858416700997", "pin1031605858416702602"]
        case .dark: ["pin1031605858416701070", "pin1031605858416701078", "pin1031605858416701073", "pin1031605858416701083", "pin1031605858416701086", "pin1031605858416701115"]
        case .gothic: ["pin1031605858416701040", "pin1031605858416701033", "pin1031605858416701031"]
        case .cathedral: ["pin1031605858416700963", "pin1031605858416700969", "pin1031605858416701162", "pin1031605858416701166", "pin1031605858416701172", "pin1031605858416701164"]
        }
    }

    /// Фоны для широкого экрана (`DESKTOP_GALLERIES`).
    public var desktopGallery: [String] {
        switch self {
        case .monochrome, .light, .gothic: []
        case .dracula: ["pin1031605858416702611", "pin1031605858416702613", "pin1031605858416702606", "pin1031605858416702618"]
        case .cathedral: ["pin1031605858416702622", "pin1031605858416702627"]
        case .dark: ["pin1031605858416702640", "pin1031605858416702643", "pin1031605858416702662"]
        }
    }

    /// Палитра в порядке веб-клиента: editorBackground, currentLine, text, comment, cyan, green, orange, pink, purple, red, yellow.
    var palette: [String] {
        switch self {
        case .dracula: ["#282A36", "#44475A", "#F8F8F2", "#A4AFD0", "#8BE9FD", "#50FA7B", "#FFB86C", "#FF79C6", "#BD93F9", "#FF5555", "#F1FA8C"]
        case .monochrome: ["#101113", "#242629", "#F5F5F5", "#A9ACB2", "#E4E4E7", "#D4D4D8", "#D4D4D8", "#F4F4F5", "#E4E4E7", "#FF7878", "#D4D4D8"]
        case .light: ["#F3F5F9", "#FFFFFF", "#192234", "#596578", "#006879", "#217345", "#895400", "#9E306C", "#5145B8", "#BC283D", "#796000"]
        case .dark: ["#141821", "#242C3A", "#F1F5F9", "#A4B1C5", "#79D5EC", "#7DE2AC", "#FFBD80", "#F2A2D0", "#ABB0FF", "#FF828D", "#ECD787"]
        case .gothic: ["#121315", "#26282C", "#FAF8F2", "#BDBFC5", "#F4C967", "#7ED7A5", "#F4B76A", "#F4C967", "#F4C967", "#FF7A85", "#F4C967"]
        case .cathedral: ["#08090B", "#1B1D21", "#FFFFFF", "#B6BBC5", "#FFFFFF", "#96D6B1", "#E8C99B", "#FFFFFF", "#FFFFFF", "#FF858D", "#ECEEF2"]
        }
    }
}

/// Оформление пользователя на устройстве (`AppearancePreferences` веб-клиента и settings-service).
public struct AppearancePreferences: Codable, Sendable, Equatable {
    public var theme: AppearanceTheme
    public var background: String
    public var desktopBackground: String?
    public var accentColor: String?
    public var pressColor: String?
    public var chatBackground: String?
    public var ownMessageColor: String?
    public var otherMessageColor: String?
    public var messageNameColor: String?
    public var roomNameColor: String?
    public var reducedMotion: Bool

    public init(
        theme: AppearanceTheme = .dark,
        background: String = "pin1031605858416701070",
        desktopBackground: String? = nil,
        accentColor: String? = nil,
        pressColor: String? = nil,
        chatBackground: String? = nil,
        ownMessageColor: String? = nil,
        otherMessageColor: String? = nil,
        messageNameColor: String? = nil,
        roomNameColor: String? = nil,
        reducedMotion: Bool = false
    ) {
        self.theme = theme
        self.background = background
        self.desktopBackground = desktopBackground
        self.accentColor = accentColor
        self.pressColor = pressColor
        self.chatBackground = chatBackground
        self.ownMessageColor = ownMessageColor
        self.otherMessageColor = otherMessageColor
        self.messageNameColor = messageNameColor
        self.roomNameColor = roomNameColor
        self.reducedMotion = reducedMotion
    }

    /// Тёмная тема с фоном «Чёрная дыра» — первый вход.
    public static let standard = AppearancePreferences()

    /// Выбор темы сбрасывает цвета к её палитре и ставит первый фон галереи (`AppearanceSection.tsx`).
    public func selecting(_ theme: AppearanceTheme) -> AppearancePreferences {
        AppearancePreferences(
            theme: theme,
            background: theme.gallery.first ?? "plain",
            desktopBackground: theme.desktopGallery.first ?? "plain",
            reducedMotion: reducedMotion
        )
    }

    enum CodingKeys: String, CodingKey {
        case theme, background, desktopBackground, accentColor, pressColor, chatBackground, ownMessageColor, otherMessageColor, messageNameColor, roomNameColor, reducedMotion
    }

    /// Неизвестные значения и цвета не в формате `#RRGGBB` заменяются умолчаниями, как в `readDeviceAppearance`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = AppearancePreferences.standard
        theme = (try? container.decodeIfPresent(AppearanceTheme.self, forKey: .theme)) ?? standard.theme
        background = (try? container.decodeIfPresent(String.self, forKey: .background)) ?? standard.background
        desktopBackground = try? container.decodeIfPresent(String.self, forKey: .desktopBackground)
        func color(_ key: CodingKeys) -> String? {
            guard let value = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
            return HexColor.isValid(value) ? value : nil
        }
        accentColor = color(.accentColor)
        pressColor = color(.pressColor)
        chatBackground = color(.chatBackground)
        ownMessageColor = color(.ownMessageColor)
        otherMessageColor = color(.otherMessageColor)
        messageNameColor = color(.messageNameColor)
        roomNameColor = color(.roomNameColor)
        reducedMotion = (try? container.decodeIfPresent(Bool.self, forKey: .reducedMotion)) ?? false
    }

    /// Пустые цвета уходят явным `null`, как в веб-клиенте.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(theme, forKey: .theme)
        try container.encode(background, forKey: .background)
        try container.encode(desktopBackground, forKey: .desktopBackground)
        try container.encode(accentColor, forKey: .accentColor)
        try container.encode(pressColor, forKey: .pressColor)
        try container.encode(chatBackground, forKey: .chatBackground)
        try container.encode(ownMessageColor, forKey: .ownMessageColor)
        try container.encode(otherMessageColor, forKey: .otherMessageColor)
        try container.encode(messageNameColor, forKey: .messageNameColor)
        try container.encode(roomNameColor, forKey: .roomNameColor)
        try container.encode(reducedMotion, forKey: .reducedMotion)
    }
}

public struct AppearanceSettings: Codable, Sendable, Equatable {
    public var preferences: AppearancePreferences
    public var revision: Int

    public init(preferences: AppearancePreferences, revision: Int) {
        self.preferences = preferences
        self.revision = revision
    }
}

/// Цвета `#RRGGBB`: проверка, смешивание и контрастный текст.
public enum HexColor {
    public static func isValid(_ value: String) -> Bool {
        value.count == 7 && value.hasPrefix("#") && value.dropFirst().allSatisfy(\.isHexDigit)
    }

    /// Каналы 0…255; для некорректной строки — чёрный.
    public static func components(_ value: String) -> (red: Int, green: Int, blue: Int) {
        guard isValid(value) else { return (0, 0, 0) }
        let digits = Array(value.dropFirst())
        func channel(_ index: Int) -> Int { Int(String(digits[index..<index + 2]), radix: 16) ?? 0 }
        return (channel(0), channel(2), channel(4))
    }

    public static func make(_ red: Int, _ green: Int, _ blue: Int) -> String {
        String(format: "#%02X%02X%02X", clamp(red), clamp(green), clamp(blue))
    }

    /// `color-mix(in srgb, first share, second)`.
    public static func mix(_ first: String, _ share: Double, _ second: String) -> String {
        let a = components(first)
        let b = components(second)
        func blend(_ x: Int, _ y: Int) -> Int { Int((Double(x) * share + Double(y) * (1 - share)).rounded()) }
        return make(blend(a.red, b.red), blend(a.green, b.green), blend(a.blue, b.blue))
    }

    /// Чёрный или белый текст поверх цвета по контрасту WCAG (`textOn` веб-клиента).
    public static func textOn(_ value: String) -> String {
        let c = components(value)
        func linear(_ channel: Int) -> Double {
            let n = Double(channel) / 255
            return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
        }
        let luminance = linear(c.red) * 0.2126 + linear(c.green) * 0.7152 + linear(c.blue) * 0.0722
        return (luminance + 0.05) / 0.05 > 1.05 / (luminance + 0.05) ? "#000000" : "#FFFFFF"
    }

    private static func clamp(_ value: Int) -> Int { min(255, max(0, value)) }
}

/// Итоговые цвета оформления (`resolveAppearance`): палитра темы с пользовательскими цветами поверх.
public struct ThemeColors: Sendable, Equatable {
    public let theme: AppearanceTheme
    public let editorBackground: String
    public let currentLine: String
    public let text: String
    public let comment: String
    public let cyan: String
    public let green: String
    public let orange: String
    public let pink: String
    public let purple: String
    public let red: String
    public let yellow: String

    public let canvas: String
    public let panel: String
    public let raised: String
    public let line: String
    public let press: String
    public let onPress: String
    public let accent: String
    public let onAccent: String
    public let chat: String
    public let own: String
    public let onOwn: String
    public let other: String
    public let onOther: String
    public let messageName: String
    public let ownMessageName: String
    public let roomName: String

    /// Радиусы `button`, `panel`, `modal`: у Dracula все 8, у остальных 12/16/24.
    public let buttonRadius: Double
    public let panelRadius: Double
    public let modalRadius: Double

    public var isLight: Bool { theme == .light }

    public init(_ preferences: AppearancePreferences) {
        let theme = preferences.theme
        let palette = theme.palette
        let accent = preferences.accentColor ?? palette[8]
        self.theme = theme
        editorBackground = palette[0]
        currentLine = palette[1]
        text = palette[2]
        comment = palette[3]
        cyan = preferences.accentColor ?? palette[4]
        green = palette[5]
        orange = palette[6]
        pink = preferences.accentColor ?? palette[7]
        purple = accent
        red = palette[9]
        yellow = palette[10]

        switch theme {
        case .light:
            canvas = "#E8ECF2"; panel = "#F7F9FC"; raised = "#FFFFFF"; line = "#CBD2DE"
        case .cathedral:
            canvas = "#040506"; panel = "#111317"; raised = "#23262C"; line = "#383D46"
        case .gothic:
            canvas = palette[0]; panel = "#1D2025"; raised = "#30343B"; line = "#454A53"
        default:
            canvas = palette[0]; panel = palette[0]; raised = palette[1]; line = palette[1]
        }

        let own = preferences.ownMessageColor ?? (theme == .light ? "#DCE5FA" : theme == .gothic ? "#353027" : palette[1])
        let other = preferences.otherMessageColor ?? palette[0]
        let press = preferences.pressColor ?? palette[1]
        self.press = press
        onPress = HexColor.textOn(press)
        self.accent = accent
        onAccent = HexColor.textOn(accent)
        chat = preferences.chatBackground ?? palette[0]
        self.own = own
        onOwn = HexColor.textOn(own)
        self.other = other
        onOther = HexColor.textOn(other)
        messageName = preferences.messageNameColor ?? HexColor.textOn(other)
        ownMessageName = preferences.messageNameColor ?? HexColor.textOn(own)
        roomName = preferences.roomNameColor ?? palette[2]

        let compact = theme == .dracula
        buttonRadius = compact ? 8 : 12
        panelRadius = compact ? 8 : 16
        modalRadius = compact ? 8 : 24
    }
}

public protocol AppearanceAPI: Sendable {
    func appearance(deviceId: String?) async throws -> AppearanceSettings
    func updateAppearance(_ settings: AppearanceSettings, deviceId: String?) async throws -> AppearanceSettings
}

/// `GET/PUT /api/appearance` settings-service; запись своя у каждого устройства.
public struct RemoteAppearanceAPI: AppearanceAPI {
    private let settings: HTTPClient

    public init(settings: HTTPClient) {
        self.settings = settings
    }

    public func appearance(deviceId: String?) async throws -> AppearanceSettings {
        try await settings.getDecoded(Self.path(deviceId))
    }

    public func updateAppearance(_ value: AppearanceSettings, deviceId: String?) async throws -> AppearanceSettings {
        try HTTPClient.decode(try await settings.send(method: "PUT", path: Self.path(deviceId), body: JSONEncoder().encode(value), timeout: 10))
    }

    static func path(_ deviceId: String?) -> String {
        guard let deviceId, VoiceSettingsModel.isValidDeviceId(deviceId) else { return "/api/appearance" }
        return "/api/appearance?deviceId=\(RemoteSettingsAPI.path(deviceId))"
    }
}

/// Оформление на устройстве до ответа сервера.
public protocol AppearanceStore: Sendable {
    func load() -> AppearancePreferences?
    func save(_ preferences: AppearancePreferences)
}
