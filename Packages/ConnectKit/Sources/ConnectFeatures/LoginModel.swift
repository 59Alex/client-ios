import ConnectAuth
import Foundation
import Observation

/// Экран входа: логин/пароль и, если сервис требует, подтверждение email кодом.
@MainActor
@Observable
public final class LoginModel {
    public enum Step: Equatable {
        case credentials
        case emailVerification
    }

    public static let verificationCodeLength = 6

    public var username = ""
    public var password = ""
    public var verificationCode = ""
    public private(set) var step: Step = .credentials
    public private(set) var isSubmitting = false
    public private(set) var errorMessage: String?
    public private(set) var infoMessage: String?

    private let auth: AuthService

    public init(auth: AuthService) {
        self.auth = auth
    }

    public var canSubmitCredentials: Bool {
        !isSubmitting && !normalizedUsername.isEmpty && !password.isEmpty
    }

    public var canSubmitVerification: Bool {
        !isSubmitting && verificationCode.count == Self.verificationCodeLength && verificationCode.allSatisfy(\.isNumber)
    }

    public func submitCredentials() async {
        guard canSubmitCredentials else { return }
        await perform {
            try await self.auth.login(username: self.normalizedUsername, password: self.password)
        }
    }

    public func submitVerification() async {
        guard canSubmitVerification else { return }
        await perform {
            let signedIn = try await self.auth.verifyEmail(username: self.normalizedUsername, code: self.verificationCode)
            if !signedIn {
                // Токен не пришёл вместе с подтверждением — входим повторно тем же паролем.
                try await self.auth.login(username: self.normalizedUsername, password: self.password)
            }
        }
    }

    /// Переход к подтверждению email после регистрации: логин и пароль уже известны.
    public func startVerification(username: String, password: String, message: String?) {
        self.username = username
        self.password = password
        verificationCode = ""
        errorMessage = nil
        infoMessage = message ?? "Подтвердите email кодом из письма"
        step = .emailVerification
    }

    /// Повторная отправка кода: веб-клиент для этого заново вызывает вход.
    public func resendCode() async {
        await perform {
            try await self.auth.login(username: self.normalizedUsername, password: self.password)
        }
        if step == .emailVerification, errorMessage == nil {
            infoMessage = "Новый код отправлен на почту."
        }
    }

    /// Логин после регистрации без подтверждения.
    public func prefill(username: String, message: String) {
        self.username = username
        password = ""
        step = .credentials
        infoMessage = message
        errorMessage = nil
    }

    public func backToCredentials() {
        step = .credentials
        verificationCode = ""
        errorMessage = nil
        infoMessage = nil
    }

    private var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await operation()
        } catch AuthError.emailVerificationRequired(let message) {
            step = .emailVerification
            verificationCode = ""
            infoMessage = message ?? "Подтвердите email кодом из письма"
        } catch AuthError.emailDeliveryFailed(let message) {
            errorMessage = message ?? "Не удалось отправить код подтверждения на почту"
        } catch AuthError.rejected(let message) {
            errorMessage = message ?? (step == .credentials ? "Не удалось выполнить вход" : "Не удалось подтвердить email")
        } catch AuthError.missingToken {
            errorMessage = "Не удалось получить токен"
        } catch {
            errorMessage = "Нет соединения с сервером. Проверьте интернет и попробуйте снова"
        }
    }
}
