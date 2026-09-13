import Foundation

/// Адреса сервисов Connect. Значения по умолчанию совпадают с профилем `test`
/// веб-клиента (`connect-ui/src/config.ts`).
public struct AppConfig: Sendable, Equatable {
    public var profile: String
    public var uiOrigin: URL
    public var mainApiUrl: URL
    public var settingsApiUrl: URL
    public var userApiUrl: URL
    public var statusApiUrl: URL
    public var notificationApiUrl: URL
    public var s3ApiUrl: URL
    public var eventsApiUrl: URL
    public var eventsOutboxApiUrl: URL
    public var keycloakUrl: URL
    public var rtcUrl: URL

    public init(
        profile: String,
        uiOrigin: URL,
        mainApiUrl: URL,
        settingsApiUrl: URL,
        userApiUrl: URL,
        statusApiUrl: URL,
        notificationApiUrl: URL,
        s3ApiUrl: URL,
        eventsApiUrl: URL,
        eventsOutboxApiUrl: URL,
        keycloakUrl: URL,
        rtcUrl: URL
    ) {
        self.profile = profile
        self.uiOrigin = uiOrigin
        self.mainApiUrl = mainApiUrl
        self.settingsApiUrl = settingsApiUrl
        self.userApiUrl = userApiUrl
        self.statusApiUrl = statusApiUrl
        self.notificationApiUrl = notificationApiUrl
        self.s3ApiUrl = s3ApiUrl
        self.eventsApiUrl = eventsApiUrl
        self.eventsOutboxApiUrl = eventsOutboxApiUrl
        self.keycloakUrl = keycloakUrl
        self.rtcUrl = rtcUrl
    }
}

extension AppConfig {
    /// Адрес медиасервера OpenVidu 3 (LiveKit) для клиента: `https` меняется на `wss`.
    public var rtcWebSocketUrl: URL {
        var components = URLComponents(url: rtcUrl, resolvingAgainstBaseURL: false)
        components?.scheme = rtcUrl.scheme == "http" ? "ws" : "wss"
        return components?.url ?? rtcUrl
    }

    public static let test = AppConfig(
        profile: "test",
        uiOrigin: url("https://cnnect.ru"),
        mainApiUrl: url("https://domain.cnnect.ru"),
        settingsApiUrl: url("https://settings.cnnect.ru"),
        userApiUrl: url("https://user.cnnect.ru"),
        statusApiUrl: url("https://status.cnnect.ru"),
        notificationApiUrl: url("https://notification.cnnect.ru"),
        s3ApiUrl: url("https://s3.cnnect.ru"),
        eventsApiUrl: url("https://events-channel-service.cnnect.ru"),
        eventsOutboxApiUrl: url("https://events-channel-outbox.cnnect.ru"),
        keycloakUrl: url("https://auth.cnnect.ru"),
        rtcUrl: url("https://rtc.cnnect.ru/livekit")
    )

    private static func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid built-in URL: \(string)")
        }
        return url
    }
}
