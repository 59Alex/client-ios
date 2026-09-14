import ConnectNetworking
import Foundation
import Observation

/// Встроенный фон чата из connect-s3 (`GET /api/backgrounds`).
public struct ChatBackground: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// CSS `background-position`: «50% 40%», «center».
    public let position: String
    public let rotation: Int
    public let width: Int?
    public let height: Int?
    public let imageUrl: String

    public init(id: String, name: String, position: String = "center", rotation: Int = 0, width: Int? = nil, height: Int? = nil, imageUrl: String) {
        self.id = id
        self.name = name
        self.position = position
        self.rotation = rotation
        self.width = width
        self.height = height
        self.imageUrl = imageUrl
    }

    /// Точка кадрирования в долях: «50% 40%» → (0.5, 0.4); ключевые слова CSS тоже понимаются.
    public var focus: (x: Double, y: Double) {
        let parts = position.split(separator: " ").map(String.init)
        func value(_ token: String?, horizontal: Bool) -> Double {
            guard let token else { return 0.5 }
            switch token {
            case "left": return horizontal ? 0 : 0.5
            case "right": return horizontal ? 1 : 0.5
            case "top": return horizontal ? 0.5 : 0
            case "bottom": return horizontal ? 0.5 : 1
            case "center": return 0.5
            default:
                guard token.hasSuffix("%"), let number = Double(token.dropLast()) else { return 0.5 }
                return min(1, max(0, number / 100))
            }
        }
        return (value(parts.first, horizontal: true), value(parts.count > 1 ? parts[1] : parts.first, horizontal: false))
    }
}

public struct ThemeBackgrounds: Decodable, Sendable, Equatable {
    public let theme: String
    public let defaultBackground: String
    public let backgrounds: [ChatBackground]

    public init(theme: String, defaultBackground: String, backgrounds: [ChatBackground]) {
        self.theme = theme
        self.defaultBackground = defaultBackground
        self.backgrounds = backgrounds
    }
}

public struct BackgroundList: Decodable, Sendable, Equatable {
    public let version: Int
    public let platform: String
    public let themes: [ThemeBackgrounds]

    public init(version: Int, platform: String, themes: [ThemeBackgrounds]) {
        self.version = version
        self.platform = platform
        self.themes = themes
    }
}

public enum BackgroundPlatform: String, Sendable {
    case mobile, desktop
}

public protocol BackgroundsAPI: Sendable {
    func backgrounds(platform: BackgroundPlatform) async throws -> BackgroundList
    /// Полный адрес картинки; `nil`, если картинки нет (офлайн-стаб).
    func imageURL(for background: ChatBackground) -> URL?
}

/// Каталог фонов и картинки отдаются connect-s3 без токена.
public struct RemoteBackgroundsAPI: BackgroundsAPI {
    private let s3: HTTPClient

    public init(s3: HTTPClient) {
        self.s3 = s3
    }

    public func backgrounds(platform: BackgroundPlatform) async throws -> BackgroundList {
        try await s3.getDecoded("/api/backgrounds?platform=\(platform.rawValue)")
    }

    public func imageURL(for background: ChatBackground) -> URL? {
        HTTPClient.join(s3.baseURL, background.imageUrl)
    }
}

/// Галереи фонов тем для телефона и выбор фона чата как `getBackgroundId` веб-клиента.
@MainActor
@Observable
public final class ChatBackgroundsModel {
    public private(set) var list: BackgroundList?
    public private(set) var failed = false

    private let api: any BackgroundsAPI
    private var isLoading = false

    public init(api: any BackgroundsAPI) {
        self.api = api
    }

    public func load() async {
        guard list == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            list = try await api.backgrounds(platform: .mobile)
            failed = false
        } catch {
            failed = true
        }
    }

    public func gallery(for theme: AppearanceTheme) -> [ChatBackground] {
        list?.themes.first { $0.theme == theme.rawValue }?.backgrounds ?? []
    }

    /// «plain» — однотонный; выбранный фон из галереи темы; иначе первый фон галереи.
    public func background(for preferences: AppearancePreferences) -> ChatBackground? {
        guard preferences.background != "plain" else { return nil }
        let gallery = gallery(for: preferences.theme)
        return gallery.first { $0.id == preferences.background } ?? gallery.first
    }

    public func imageURL(for background: ChatBackground) -> URL? {
        api.imageURL(for: background)
    }
}

public extension AppearanceModel {
    /// Фон чата телефона; «plain» — однотонный.
    func selectBackground(_ id: String) {
        var next = draft
        next.background = id
        change(next)
    }
}
