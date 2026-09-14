import ConnectAuth
import ConnectCalls
import ConnectCore
import ConnectFeatures
import SwiftUI

struct LoginView: View {
    private enum Field: Hashable {
        case username, password, code
    }

    private enum Mode: Hashable {
        case login, register
    }

    @State private var model: LoginModel
    @State private var registration: RegistrationModel
    @State private var mode: Mode = .login
    @FocusState private var focusedField: Field?
    private let guest: GuestMeetingModel?
    @State private var isGuestJoinShown = false

    init(auth: AuthService, guest: GuestMeetingModel? = nil) {
        _model = State(initialValue: LoginModel(auth: auth))
        _registration = State(initialValue: RegistrationModel(auth: auth))
        self.guest = guest
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                VStack(alignment: .leading, spacing: 16) {
                    if model.step == .credentials {
                        Picker("Режим", selection: $mode) {
                            Text("Вход").tag(Mode.login)
                            Text("Регистрация").tag(Mode.register)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("login.mode")
                    }
                    switch (model.step, mode) {
                    case (.emailVerification, _): verificationForm
                    case (.credentials, .login): credentialsForm
                    case (.credentials, .register):
                        RegistrationForm(model: registration) { outcome in
                            switch outcome {
                            case let .verificationRequired(username, password, message):
                                model.startVerification(username: username, password: password, message: message)
                            case let .created(username):
                                model.prefill(username: username, message: "Профиль создан. Теперь войдите в аккаунт.")
                                mode = .login
                            }
                        }
                    }
                    if mode == .login || model.step == .emailVerification {
                        messages
                    }
                }
                .padding(20)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.modal))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.modal).strokeBorder(Palette.border)
                }

                if guest != nil, model.step == .credentials {
                    Button {
                        isGuestJoinShown = true
                    } label: {
                        Label("Войти во встречу как гость", systemImage: "person.crop.circle.badge.questionmark")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("login.guestMeeting")
                }
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 20)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.canvas)
        .disabled(model.isSubmitting || registration.isSubmitting)
        .sheet(isPresented: $isGuestJoinShown) {
            if let guest {
                GuestJoinSheet(model: guest)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("cnnect")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(model.step == .emailVerification ? "Подтверждение email" : (mode == .login ? "Вход в аккаунт" : "Создание профиля"))
                .font(.headline)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var credentialsForm: some View {
        VStack(spacing: 12) {
            TextField("Логин", text: $model.username, prompt: Text("Логин").foregroundStyle(Palette.textSecondary))
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .username)
                .onSubmit { focusedField = .password }
                .connectField(isFocused: focusedField == .username)
                .accessibilityIdentifier("login.username")

            SecureField("Пароль", text: $model.password, prompt: Text("Пароль").foregroundStyle(Palette.textSecondary))
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focusedField, equals: .password)
                .onSubmit(submitCredentials)
                .connectField(isFocused: focusedField == .password)
                .accessibilityIdentifier("login.password")

            submitButton(title: "Войти", enabled: model.canSubmitCredentials, action: submitCredentials)
                .accessibilityIdentifier("login.submit")
        }
    }

    private var verificationForm: some View {
        VStack(spacing: 12) {
            TextField("Код из письма", text: $model.verificationCode, prompt: Text("Код из письма").foregroundStyle(Palette.textSecondary))
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(.title3.monospacedDigit())
                .focused($focusedField, equals: .code)
                .connectField(isFocused: focusedField == .code)
                .onChange(of: model.verificationCode) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(LoginModel.verificationCodeLength))
                    if digits != newValue { model.verificationCode = digits }
                }
                .accessibilityIdentifier("login.code")

            submitButton(title: "Подтвердить", enabled: model.canSubmitVerification) {
                Task { await model.submitVerification() }
            }
            .accessibilityIdentifier("login.verify")

            Button("Отправить код повторно") { Task { await model.resendCode() } }
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(Palette.accent)
                .accessibilityIdentifier("login.resend")

            Button("Изменить логин", action: model.backToCredentials)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(Palette.accent)
        }
        .onAppear { focusedField = .code }
    }

    @ViewBuilder
    private var messages: some View {
        if let info = model.infoMessage {
            Label(info, systemImage: "envelope")
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(Palette.danger)
                .accessibilityIdentifier("login.error")
        }
    }

    private func submitButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if model.isSubmitting {
                ProgressView().tint(Palette.onAccent)
            } else {
                Text(title)
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!enabled)
        .padding(.top, 4)
    }

    private func submitCredentials() {
        focusedField = nil
        Task { await model.submitCredentials() }
    }
}

/// Регистрация: имя, логин, email, необязательный телефон и пароль со шкалой сложности.
private struct RegistrationForm: View {
    @Bindable var model: RegistrationModel
    let onOutcome: (RegistrationModel.Outcome) -> Void

    @State private var isPasswordVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Имя", text: $model.name, identifier: "register.name")
                .textContentType(.name)
            field("Логин", text: $model.username, identifier: "register.username")
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            field("Email", text: $model.email, identifier: "register.email")
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            field("+7 (999) 999-99-99", text: $model.phone, identifier: "register.phone")
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)

            HStack {
                Group {
                    if isPasswordVisible {
                        TextField("Пароль", text: $model.password)
                    } else {
                        SecureField("Пароль", text: $model.password)
                    }
                }
                .textContentType(.newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("register.password")
                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel(isPasswordVisible ? "Скрыть пароль" : "Показать пароль")
            }
            .padding(.leading, 14)
            .frame(minHeight: 50)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: Radius.button))
            .overlay { RoundedRectangle(cornerRadius: Radius.button).strokeBorder(Palette.border) }

            PasswordStrengthView(strength: model.passwordStrength)
                .opacity(model.password.isEmpty ? 0.5 : 1)

            Button {
                Task {
                    if let outcome = await model.submit() { onOutcome(outcome) }
                }
            } label: {
                if model.isSubmitting {
                    ProgressView().tint(Palette.onAccent)
                } else {
                    Text("Создать профиль")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canSubmit)
            .padding(.top, 4)
            .accessibilityIdentifier("register.submit")

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("register.error")
            } else if !model.validationErrors.isEmpty, !model.name.isEmpty || !model.username.isEmpty {
                Text(model.validationErrors.joined(separator: "\n"))
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, identifier: String) -> some View {
        TextField(title, text: text, prompt: Text(title).foregroundStyle(Palette.textSecondary))
            .connectField(isFocused: false)
            .accessibilityIdentifier(identifier)
    }
}

private struct PasswordStrengthView: View {
    let strength: PasswordStrength

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Сложность пароля")
                Spacer()
                Text(strength.label).fontWeight(.semibold)
            }
            .font(.footnote)
            .foregroundStyle(Palette.textPrimary)
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index < strength.score ? (strength.score == 4 ? Palette.accent : Palette.textSecondary) : Palette.border)
                        .frame(height: 4)
                }
            }
            Text(strength.hint)
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Сложность пароля: \(strength.label). \(strength.hint)")
    }
}
