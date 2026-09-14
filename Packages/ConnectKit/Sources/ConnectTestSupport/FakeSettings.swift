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
