import ConnectNetworking
import ConnectSettings
import Foundation

/// Настройки в памяти для тестов и офлайн-стаба.
public actor FakeSettingsAPI: SettingsAPI {
    public private(set) var accountValue: AccountSettings
    public private(set) var sounds: NotificationSounds
    public private(set) var voice: VoiceSettings?
    public private(set) var sticker: GreetingSticker?
    public private(set) var takenUsernames: Set<String>
    public private(set) var takenEmails: Set<String>
    public private(set) var accountUpdates: [AccountSettings] = []
    public var failUpdates = false

    public init(userId: String, name: String, username: String, email: String, phone: String? = nil, takenUsernames: Set<String> = [], takenEmails: Set<String> = [], sticker: GreetingSticker? = nil) {
        accountValue = AccountSettings(
            userId: userId,
            name: AccountField(value: name),
            username: AccountField(value: username),
            phoneNumber: AccountField(value: phone),
            email: AccountField(value: email, keycloakStatus: .complete, connectStatus: .complete)
        )
        sounds = NotificationSounds(userId: userId)
        self.takenUsernames = takenUsernames
        self.takenEmails = takenEmails
        self.sticker = sticker
    }

    public func setFailUpdates(_ value: Bool) { failUpdates = value }

    public func account(userId: String) async throws -> AccountSettings { accountValue }

    public func updateAccount(_ settings: AccountSettings) async throws -> AccountSettings {
        if failUpdates { throw URLError(.badServerResponse) }
        accountUpdates.append(settings)
        var stored = settings
        for keyPath in [\AccountSettings.name, \.username, \.phoneNumber, \.email] where stored[keyPath: keyPath].newValue != nil {
            stored[keyPath: keyPath].keycloakStatus = .request
            stored[keyPath: keyPath].connectStatus = .request
        }
        accountValue = stored
        return stored
    }

    public func usernameExists(_ username: String) async throws -> Bool { takenUsernames.contains(username) }
    public func emailExists(_ email: String) async throws -> Bool { takenEmails.contains(email.lowercased()) }

    public func notificationSounds(userId: String) async throws -> NotificationSounds { sounds }

    public func updateNotificationSounds(_ value: NotificationSounds) async throws -> NotificationSounds {
        if failUpdates { throw URLError(.badServerResponse) }
        sounds = value
        return value
    }

    public func voiceSettings(userId: String, deviceId: String) async throws -> VoiceSettings {
        if let voice, voice.deviceId == deviceId { return voice }
        let created = VoiceSettings(userId: userId, deviceId: deviceId)
        voice = created
        return created
    }

    public func updateVoiceSettings(_ settings: VoiceSettings) async throws -> VoiceSettings {
        if failUpdates { throw URLError(.badServerResponse) }
        voice = settings
        return settings
    }

    public func greeting(userId: String) async throws -> GreetingSticker? { sticker }
    public func setGreeting(_ value: GreetingSticker) async throws { sticker = value }
    public func resetGreeting() async throws { sticker = nil }
}

/// Оформление в памяти: ревизии, конфликты записи и журнал отправленных тел.
public actor FakeAppearanceAPI: AppearanceAPI {
    public private(set) var stored: AppearanceSettings
    public private(set) var puts: [AppearanceSettings] = []
    public private(set) var gets = 0
    public private(set) var deviceIds: [String?] = []
    public var conflicts = 0
    public var failGets = false

    public init(preferences: AppearancePreferences = .standard, revision: Int = 0) {
        stored = AppearanceSettings(preferences: preferences, revision: revision)
    }

    public func setConflicts(_ value: Int) { conflicts = value }
    public func setFailGets(_ value: Bool) { failGets = value }

    /// Правка с другого устройства той же записи.
    public func externalUpdate(_ preferences: AppearancePreferences) {
        stored = AppearanceSettings(preferences: preferences, revision: stored.revision + 1)
    }

    public func appearance(deviceId: String?) async throws -> AppearanceSettings {
        gets += 1
        deviceIds.append(deviceId)
        if failGets { throw APIError.http(statusCode: 503, body: nil) }
        return stored
    }

    public func updateAppearance(_ settings: AppearanceSettings, deviceId: String?) async throws -> AppearanceSettings {
        puts.append(settings)
        if conflicts > 0 || settings.revision != stored.revision {
            conflicts = max(0, conflicts - 1)
            throw APIError.http(statusCode: 409, body: nil)
        }
        stored = AppearanceSettings(preferences: settings.preferences, revision: stored.revision + 1)
        return stored
    }
}

/// Хранилище оформления устройства в памяти.
public final class MemoryAppearanceStore: AppearanceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppearancePreferences?

    public init(_ value: AppearancePreferences? = nil) {
        self.value = value
    }

    public func load() -> AppearancePreferences? {
        lock.withLock { value }
    }

    public func save(_ preferences: AppearancePreferences) {
        lock.withLock { value = preferences }
    }
}
