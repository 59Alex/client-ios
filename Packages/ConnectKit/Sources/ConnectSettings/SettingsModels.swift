import ConnectCore
import Foundation
import Observation

/// Аккаунт: текущие значения, заявки на изменение, редактирование с проверкой занятости.
@MainActor
@Observable
public final class AccountSettingsModel {
    public private(set) var account: AccountSettings?
    public private(set) var loadError: String?

    private let userId: String
    private let api: any SettingsAPI

    public init(userId: String, api: any SettingsAPI) {
        self.userId = userId
        self.api = api
    }

    public func load() async {
        do {
            account = try await api.account(userId: userId)
            loadError = nil
        } catch {
            loadError = "Не удалось загрузить данные аккаунта"
        }
    }

    public func field(_ kind: AccountFieldKind) -> AccountField? {
        guard let account else { return nil }
        return switch kind {
        case .name: account.name
        case .username: account.username
        case .phone: account.phoneNumber
        case .email: account.email
        }
    }

    /// Ошибка ввода или `nil`, если значение можно отправить.
    public func validate(_ kind: AccountFieldKind, value raw: String) async -> String? {
        let value = kind == .phone ? PhoneMask.format(raw) : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Введенное значение содержит некорректные символы" }
        let current = field(kind)?.value ?? ""
        switch kind {
        case .name:
            return nil
        case .phone:
            return PhoneMask.isComplete(value) ? nil : "Введенное значение содержит некорректные символы"
        case .username:
            if value == current { return "Этот username уже принадлежит вам" }
            if value.contains(where: \.isWhitespace) { return "Введенное значение содержит некорректные символы" }
            if (try? await api.usernameExists(value)) == true { return "Этот username занят \(value)" }
            return nil
        case .email:
            if value.caseInsensitiveCompare(current) == .orderedSame { return "Этот email уже принадлежит вам" }
            guard EmailRule.isValid(value) else { return "Введенное значение содержит некорректные символы" }
            if (try? await api.emailExists(value)) == true { return "Этот email занят \(value)" }
            return nil
        }
    }

    /// Отправляет заявку: весь объект с новым `eventId`, в поле — `newValue` и сброшенные статусы.
    public func save(_ kind: AccountFieldKind, value raw: String) async -> String? {
        if let error = await validate(kind, value: raw) { return error }
        guard var account else { return "Не удалось загрузить данные аккаунта" }
        let value = kind == .phone ? PhoneMask.format(raw) : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        account.eventId = UUID().uuidString.lowercased()
        func request(_ field: inout AccountField) {
            field.newValue = value
            field.connectStatus = nil
            field.keycloakStatus = nil
        }
        switch kind {
        case .name: request(&account.name)
        case .username: request(&account.username)
        case .phone: request(&account.phoneNumber)
        case .email:
            request(&account.email)
            account.email.verified = false
            account.email.verifyStatus = nil
        }
        do {
            self.account = try await api.updateAccount(account)
            return nil
        } catch {
            return "Не удалось сохранить изменения"
        }
    }
}

/// Звуки уведомлений: переключение сохраняется сразу, при ошибке откатывается.
@MainActor
@Observable
public final class NotificationSoundsModel {
    public private(set) var sounds: NotificationSounds?
    public private(set) var errorMessage: String?

    private let userId: String
    private let api: any SettingsAPI

    public init(userId: String, api: any SettingsAPI) {
        self.userId = userId
        self.api = api
    }

    public func load() async {
        do {
            sounds = try await api.notificationSounds(userId: userId)
            errorMessage = nil
        } catch {
            errorMessage = "Не удалось загрузить настройки звуков"
        }
    }

    public func set(_ keyPath: WritableKeyPath<NotificationSounds, Bool>, _ value: Bool) async {
        guard let previous = sounds else { return }
        var updated = previous
        updated[keyPath: keyPath] = value
        sounds = updated
        do {
            sounds = try await api.updateNotificationSounds(updated)
            errorMessage = nil
        } catch {
            sounds = previous
            errorMessage = "Не удалось сохранить настройку"
        }
    }
}

/// Голос и видео этого устройства. Пустой или «undefined» deviceId не отправляется: сервис создал бы запись.
@MainActor
@Observable
public final class VoiceSettingsModel {
    public private(set) var settings: VoiceSettings?
    public private(set) var errorMessage: String?

    private let userId: String
    private let deviceId: String
    private let api: any SettingsAPI

    public init(userId: String, deviceId: String, api: any SettingsAPI) {
        self.userId = userId
        self.deviceId = deviceId
        self.api = api
    }

    public nonisolated static func isValidDeviceId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "undefined" && trimmed != "null"
    }

    public func load() async {
        guard Self.isValidDeviceId(deviceId) else {
            errorMessage = "Не удалось определить устройство"
            return
        }
        do {
            settings = try await api.voiceSettings(userId: userId, deviceId: deviceId)
            errorMessage = nil
        } catch {
            errorMessage = "Не удалось загрузить настройки голоса"
        }
    }

    public func update(_ change: (inout VoiceSettings) -> Void) async {
        guard var updated = settings, updated.deviceId == deviceId else { return }
        let previous = updated
        change(&updated)
        updated.micVolume = min(100, max(0, updated.micVolume))
        updated.speakerVolume = min(100, max(0, updated.speakerVolume))
        if let threshold = updated.activateMicrophoneThreshold {
            updated.activateMicrophoneThreshold = min(0, max(-100, threshold))
        }
        settings = updated
        do {
            settings = try await api.updateVoiceSettings(updated)
            errorMessage = nil
        } catch {
            settings = previous
            errorMessage = "Не удалось сохранить настройку"
        }
    }
}

/// Свой приветственный стикер: загрузка картинки в `user-gallery`, установка и сброс.
@MainActor
@Observable
public final class GreetingModel {
    public static let maxBytes = 5 * 1024 * 1024
    public static let allowedExtensions: Set<String> = [".png", ".jpg", ".jpeg", ".webp", ".gif"]

    public private(set) var sticker: GreetingSticker?
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?

    private let userId: String
    private let api: any SettingsAPI

    public init(userId: String, api: any SettingsAPI) {
        self.userId = userId
        self.api = api
    }

    public func load() async {
        sticker = try? await api.greeting(userId: userId)
    }

    /// `upload` загружает картинку в хранилище и возвращает её адрес.
    public func set(data: Data, extension ext: String, upload: (Data) async throws -> String) async {
        let normalized = (ext.hasPrefix(".") ? ext : "." + ext).lowercased()
        guard Self.allowedExtensions.contains(normalized), data.count <= Self.maxBytes else {
            errorMessage = "Выберите PNG, JPG, WEBP или GIF до 5 МБ"
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let sticker = GreetingSticker(urlS3: try await upload(data), extension: normalized)
            try await api.setGreeting(sticker)
            self.sticker = sticker
        } catch {
            errorMessage = "Не удалось сохранить приветствие. Выберите файл ещё раз."
        }
    }

    public func reset() async {
        do {
            try await api.resetGreeting()
            sticker = nil
            errorMessage = nil
        } catch {
            errorMessage = "Не удалось сбросить приветствие"
        }
    }
}
