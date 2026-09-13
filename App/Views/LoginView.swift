import ConnectAuth
import ConnectFeatures
import SwiftUI

struct LoginView: View {
    private enum Field: Hashable {
        case username, password, code
    }

    @State private var model: LoginModel
    @FocusState private var focusedField: Field?

    init(auth: AuthService) {
        _model = State(initialValue: LoginModel(auth: auth))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                VStack(alignment: .leading, spacing: 16) {
                    switch model.step {
                    case .credentials: credentialsForm
                    case .emailVerification: verificationForm
                    }
                    messages
                }
                .padding(20)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.modal))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.modal).strokeBorder(Palette.border)
                }
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 20)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.canvas)
        .disabled(model.isSubmitting)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("cnnect")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(model.step == .credentials ? "Вход в аккаунт" : "Подтверждение email")
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

            Button("Изменить логин", action: model.backToCredentials)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(Palette.accent)
        }
        .onAppear { focusedField = .code }
    }

    @ViewBuilder
    private var messages: some View {
        if let info = model.infoMessage, model.step == .emailVerification {
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
