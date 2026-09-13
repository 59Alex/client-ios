import ConnectAuth
import ConnectCore
import Foundation
import Observation

/// Регистрация профиля (`AuthGate.tsx`): проверки полей, сложность пароля, маска телефона.
@MainActor
@Observable
public final class RegistrationModel {
    public enum Outcome: Equatable {
        /// Код отправлен на почту: дальше подтверждение тем же логином и паролем.
        case verificationRequired(username: String, password: String, message: String?)
        /// Профиль создан без подтверждения: войти вручную.
        case created(username: String)
    }

    public var name = ""
    public var username = ""
    public var email = ""
    public var phone = "" {
        didSet {
            let formatted = PhoneMask.format(phone)
            if formatted != phone { phone = formatted }
        }
    }
    public var password = ""
    public private(set) var isSubmitting = false
    public private(set) var errorMessage: String?

    private let auth: AuthService

    public init(auth: AuthService) {
        self.auth = auth
    }

    public var passwordStrength: PasswordStrength { PasswordStrength(password) }

    /// Логин с одним ведущим `@`.
    public var normalizedUsername: String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = trimmed.drop { $0 == "@" }
        return "@" + bare
    }

    /// Ошибки по порядку полей; кнопка активна, когда список пуст.
    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("Имя: поле обязательно") }
        if normalizedUsername.range(of: "^@[^\\s@]+$", options: .regularExpression) == nil {
            errors.append("Логин: должен начинаться с @ и содержать имя")
        }
        if !EmailRule.isValid(email.trimmingCharacters(in: .whitespacesAndNewlines)) { errors.append("Email: введите корректный email") }
        if !phone.isEmpty, !PhoneMask.isComplete(phone) { errors.append("Телефон: введите полностью или оставьте поле пустым") }
        if let missing = passwordStrength.missing.first { errors.append("Пароль: " + missing.lowercased()) }
        return errors
    }

    public var canSubmit: Bool { !isSubmitting && validationErrors.isEmpty }

    public func submit() async -> Outcome? {
        guard !isSubmitting else { return nil }
        if let first = validationErrors.first {
            errorMessage = first
            return nil
        }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let profile = NewProfile(
            username: normalizedUsername,
            password: password,
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            phoneNumber: phone.isEmpty ? nil : PhoneMask.format(phone)
        )
        do {
            if try await auth.register(profile) {
                return .verificationRequired(username: profile.username, password: password, message: "Код верификации отправлен на почту.")
            }
            return .created(username: profile.username)
        } catch AuthError.rejected(let message) {
            errorMessage = message ?? "Не удалось создать пользователя"
        } catch {
            errorMessage = "Нет соединения с сервером. Проверьте интернет и попробуйте снова"
        }
        return nil
    }
}
