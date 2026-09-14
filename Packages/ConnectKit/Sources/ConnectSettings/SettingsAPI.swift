import ConnectNetworking
import Foundation

/// Поле аккаунта с асинхронным обновлением через Keycloak и connect (`types/settings.ts`).
public struct AccountField: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case request = "REQUEST"
        case retry = "RETRY"
        case complete = "COMPLETE"
    }

    public var value: String?
    public var newValue: String?
    public var keycloakStatus: Status?
    public var connectStatus: Status?
    public var verifyStatus: Status?
    public var verified: Bool?

    public init(value: String?, newValue: String? = nil, keycloakStatus: Status? = nil, connectStatus: Status? = nil, verifyStatus: Status? = nil, verified: Bool? = nil) {
        self.value = value
        self.newValue = newValue
        self.keycloakStatus = keycloakStatus
        self.connectStatus = connectStatus
        self.verifyStatus = verifyStatus
        self.verified = verified
    }

    /// Плашка статуса заявки на изменение, как в `AccountSettingsSection.tsx`.
    public var pendingMessage: String? {
        guard let newValue, let keycloakStatus, let connectStatus else { return nil }
        if keycloakStatus == .retry || connectStatus == .retry {
            return "Проблемы на сервере, обновление находится в очереди, новое значение: \(newValue)"
        }
        if keycloakStatus == .request && connectStatus == .request {
            return "Поступил запрос обновления данных, данные обновляются на: \(newValue)"
        }
        return nil
    }
}

public struct AccountSettings: Codable, Sendable, Equatable {
    public var userId: String
    public var eventId: String?
    public var name: AccountField
    public var username: AccountField
    public var phoneNumber: AccountField
    public var avatarUrlS3: AccountField?
    public var email: AccountField

    public init(userId: String, name: AccountField, username: AccountField, phoneNumber: AccountField, email: AccountField) {
        self.userId = userId
        self.name = name
        self.username = username
        self.phoneNumber = phoneNumber
        self.email = email
    }

    /// Почта считается подтверждённой, пока письмо не отправлено (`useUserSettings.ts`).
    public var isEmailVerified: Bool {
        email.verifyStatus != .request || email.verified == true
    }
}

public enum AccountFieldKind: String, Sendable, CaseIterable, Identifiable {
    case name, username, phone, email

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .name: "Отображаемое имя"
        case .username: "Имя пользователя"
        case .phone: "Номер телефона"
        case .email: "Электронная почта"
        }
    }
}

/// Звуки уведомлений: 11 флагов в порядке веб-клиента.
public struct NotificationSounds: Codable, Sendable, Equatable {
    public var userId: String
    public var messageSound: Bool
    public var connectToVoiceChannelSound: Bool
    public var disconnectVoiceChannelSound: Bool
    public var someoneConnectToVoiceChannelSound: Bool
    public var someoneDisconnectFromVoiceChannelSound: Bool
    public var startScreenSharingSound: Bool
    public var someoneStartScreenSharingSound: Bool
    public var endScreenSharingSound: Bool
    public var someoneEndScreenSharingSound: Bool
    public var turnOffAllNotificationsInCall: Bool
    public var turnOffAllNotifications: Bool

    public init(userId: String, enabled: Bool = true) {
        self.userId = userId
        messageSound = enabled
        connectToVoiceChannelSound = enabled
        disconnectVoiceChannelSound = enabled
        someoneConnectToVoiceChannelSound = enabled
        someoneDisconnectFromVoiceChannelSound = enabled
        startScreenSharingSound = enabled
        someoneStartScreenSharingSound = enabled
        endScreenSharingSound = enabled
        someoneEndScreenSharingSound = enabled
        turnOffAllNotificationsInCall = false
        turnOffAllNotifications = false
    }

    public static var items: [(title: String, keyPath: WritableKeyPath<NotificationSounds, Bool>)] {[
        ("Звуки входящих сообщений", \.messageSound),
        ("Звук подключения к голосовому каналу", \.connectToVoiceChannelSound),
        ("Звук отключения от голосового канала", \.disconnectVoiceChannelSound),
        ("Звук подключения участников к голосовому каналу", \.someoneConnectToVoiceChannelSound),
        ("Звук отключения участников от голосового канала", \.someoneDisconnectFromVoiceChannelSound),
        ("Звук начала демонстрации экрана", \.startScreenSharingSound),
        ("Звук начала демонстрации экрана участников", \.someoneStartScreenSharingSound),
        ("Звук прекращения демонстрации экрана", \.endScreenSharingSound),
        ("Звук прекращения демонстрации экрана участников", \.someoneEndScreenSharingSound),
        ("Отключить все звуки во время звонка", \.turnOffAllNotificationsInCall),
        ("Отключить все звуки", \.turnOffAllNotifications),
    ]}
}

/// Голос и видео для устройства (`VoiceAndSoundSection.tsx`). Поле `noiceReductionType` — с опечаткой сервиса.
public struct VoiceSettings: Codable, Sendable, Equatable {
    public enum NoiseReduction: String, Codable, Sendable, CaseIterable, Identifiable {
        case ai = "AI"
        case aiLight = "AI_LIGHT"
        case standard = "STANDARD"
        case none = "NONE"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .ai: "ИИ"
            case .aiLight: "Облегченный ИИ"
            case .standard: "Стандартное"
            case .none: "Чистый звук"
            }
        }
    }

    public var userId: String
    public var deviceId: String
    public var micVolume: Int
    public var speakerVolume: Int
    public var activateMicrophoneThreshold: Int?
    public var noiceReductionType: NoiseReduction
    public var echoSuppression: Bool
    public var webcamPreview: Bool?
    public var streamPreview: Bool?
    public var walkieTalkieMode: Bool?
    public var micActivationKey: String?
    public var micMuteDelayTime: Int?
    public var inputDevices: [InputDevice]?

    public struct InputDevice: Codable, Sendable, Equatable {
        public var inputDeviceId: String
        public var inputDeviceName: String?
        public var inputDeviceType: String
        public var active: Bool
    }

    public init(userId: String, deviceId: String) {
        self.userId = userId
        self.deviceId = deviceId
        micVolume = 100
        speakerVolume = 100
        activateMicrophoneThreshold = 0
        noiceReductionType = .standard
        echoSuppression = true
    }
}

/// Приветственный стикер пользователя; `nil` — не задан.
public struct GreetingSticker: Codable, Sendable, Equatable {
    public var urlS3: String
    public var `extension`: String

    public init(urlS3: String, extension: String) {
        self.urlS3 = urlS3
        self.extension = `extension`
    }
}

public protocol SettingsAPI: Sendable {
    func account(userId: String) async throws -> AccountSettings
    func updateAccount(_ settings: AccountSettings) async throws -> AccountSettings
    func usernameExists(_ username: String) async throws -> Bool
    func emailExists(_ email: String) async throws -> Bool
    func notificationSounds(userId: String) async throws -> NotificationSounds
    func updateNotificationSounds(_ sounds: NotificationSounds) async throws -> NotificationSounds
    func voiceSettings(userId: String, deviceId: String) async throws -> VoiceSettings
    func updateVoiceSettings(_ settings: VoiceSettings) async throws -> VoiceSettings
    func greeting(userId: String) async throws -> GreetingSticker?
    func setGreeting(_ sticker: GreetingSticker) async throws
    func resetGreeting() async throws
}

public struct RemoteSettingsAPI: SettingsAPI {
    private let settings: HTTPClient
    private let users: HTTPClient
    private let main: HTTPClient

    public init(settings: HTTPClient, users: HTTPClient, main: HTTPClient) {
        self.settings = settings
        self.users = users
        self.main = main
    }

    public func account(userId: String) async throws -> AccountSettings {
        try await settings.getDecoded("/api/account/get/\(Self.path(userId))")
    }

    public func updateAccount(_ account: AccountSettings) async throws -> AccountSettings {
        try HTTPClient.decode(try await settings.send(method: "PUT", path: "/api/account/update", body: JSONEncoder().encode(account)))
    }

    public func usernameExists(_ username: String) async throws -> Bool {
        try await users.getDecoded("/api/user/exists/\(Self.path(username))", as: Bool.self)
    }

    public func emailExists(_ email: String) async throws -> Bool {
        try await users.getDecoded("/api/user/exists/email/\(Self.path(email))", as: Bool.self)
    }

    public func notificationSounds(userId: String) async throws -> NotificationSounds {
        try await settings.getDecoded("/api/notificationsound/get/\(Self.path(userId))")
    }

    public func updateNotificationSounds(_ sounds: NotificationSounds) async throws -> NotificationSounds {
        try HTTPClient.decode(try await settings.send(method: "PUT", path: "/api/notificationsound/update", body: JSONEncoder().encode(sounds)))
    }

    public func voiceSettings(userId: String, deviceId: String) async throws -> VoiceSettings {
        try await settings.getDecoded("/api/voiceandsound/get/\(Self.path(userId))/\(Self.path(deviceId))")
    }

    public func updateVoiceSettings(_ voice: VoiceSettings) async throws -> VoiceSettings {
        try HTTPClient.decode(try await settings.send(method: "PUT", path: "/api/voiceandsound/update", body: JSONEncoder().encode(voice)))
    }

    public func greeting(userId: String) async throws -> GreetingSticker? {
        let response = try await main.get("/api/user-card/greeting/\(Self.path(userId))")
        if response.statusCode == 404 { return nil }
        try HTTPClient.requireSuccess(response)
        return try? JSONDecoder().decode(GreetingSticker.self, from: response.body)
    }

    public func setGreeting(_ sticker: GreetingSticker) async throws {
        try HTTPClient.requireSuccess(try await main.send(method: "PUT", path: "/api/user-card/greeting", body: JSONEncoder().encode(sticker)))
    }

    public func resetGreeting() async throws {
        try HTTPClient.requireSuccess(try await main.send(method: "DELETE", path: "/api/user-card/greeting", body: nil))
    }

    static func path(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? value
    }
}
