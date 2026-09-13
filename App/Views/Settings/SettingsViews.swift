import ConnectCore
import ConnectFiles
import ConnectSettings
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Аккаунт: поля с кнопкой «Изменить», статусы заявок и подтверждения почты.
struct AccountSettingsView: View {
    @State var model: AccountSettingsModel
    @State private var editing: AccountFieldKind?

    var body: some View {
        List {
            if let error = model.loadError {
                Text(error).foregroundStyle(Palette.danger)
            }
            ForEach(AccountFieldKind.allCases) { kind in
                Section(kind.title) {
                    let field = model.field(kind)
                    HStack {
                        Text(field?.value?.isEmpty == false ? field?.value ?? "" : "Не указано")
                            .foregroundStyle(field?.value?.isEmpty == false ? Palette.textPrimary : Palette.textSecondary)
                            .accessibilityIdentifier("account.value.\(kind.rawValue)")
                        if kind == .email, model.account?.isEmailVerified == true, field?.value?.isEmpty == false {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Palette.accent)
                                .accessibilityLabel("Подтверждено")
                        }
                        Spacer()
                        Button("Изменить") { editing = kind }
                            .accessibilityIdentifier("account.edit.\(kind.rawValue)")
                    }
                    if let pending = field?.pendingMessage {
                        Text(pending)
                            .font(.footnote)
                            .foregroundStyle(field?.keycloakStatus == .retry || field?.connectStatus == .retry ? Palette.danger : Palette.textSecondary)
                            .accessibilityIdentifier("account.pending.\(kind.rawValue)")
                    }
                    if kind == .email, let account = model.account, !account.isEmailVerified {
                        Text(account.email.verifyStatus == .request ? "Вам на почту отправлено письмо с ссылкой для подтверждения" : "Почта не подтверждена")
                            .font(.footnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Аккаунт")
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $editing) { kind in
            AccountEditSheet(kind: kind, model: model)
        }
    }
}

private struct AccountEditSheet: View {
    let kind: AccountFieldKind
    let model: AccountSettingsModel

    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $value)
                    .keyboardType(kind == .phone ? .phonePad : (kind == .email ? .emailAddress : .default))
                    .textInputAutocapitalization(kind == .name ? .words : .never)
                    .autocorrectionDisabled(kind != .name)
                    .onChange(of: value) { _, newValue in
                        if kind == .phone {
                            let formatted = PhoneMask.format(newValue)
                            if formatted != newValue { value = formatted }
                        }
                    }
                    .accessibilityIdentifier("account.field")
                if let error {
                    Text(error).foregroundStyle(Palette.danger).accessibilityIdentifier("account.error")
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task {
                            isSaving = true
                            error = await model.save(kind, value: value)
                            isSaving = false
                            if error == nil { dismiss() }
                        }
                    }
                    .disabled(isSaving || value.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("account.save")
                }
            }
            .task(id: value) {
                guard kind == .username || kind == .email, !value.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                error = await model.validate(kind, value: value)
            }
        }
        .presentationDetents([.medium])
    }

    private var placeholder: String {
        switch kind {
        case .name: "Отображаемое имя"
        case .username: "Имя пользователя"
        case .phone: "+7 (___) ___-__-__"
        case .email: "your@mail.ru"
        }
    }
}

struct NotificationSoundsView: View {
    @State var model: NotificationSoundsModel

    var body: some View {
        List {
            if let sounds = model.sounds {
                Section {
                    ForEach(Array(NotificationSounds.items.enumerated()), id: \.offset) { index, item in
                        Toggle(item.title, isOn: Binding(
                            get: { sounds[keyPath: item.keyPath] },
                            set: { newValue in Task { await model.set(item.keyPath, newValue) } }
                        ))
                        .accessibilityIdentifier("sounds.toggle.\(index)")
                    }
                } footer: {
                    Text("Настройки звуков общие для всех устройств")
                }
                .listRowBackground(Palette.surface)
            } else if model.errorMessage == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(Palette.danger)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Уведомления")
        .task { await model.load() }
    }
}

struct VoiceSettingsView: View {
    @State var model: VoiceSettingsModel
    @State private var micVolume = 100.0
    @State private var speakerVolume = 100.0
    @State private var threshold = -48.0

    var body: some View {
        List {
            if let settings = model.settings {
                Section("Громкость") {
                    slider("Громкость микрофона", value: $micVolume, range: 0...100, unit: "%") { value in
                        await model.update { $0.micVolume = Int(value) }
                    }
                    slider("Громкость динамика", value: $speakerVolume, range: 0...100, unit: "%") { value in
                        await model.update { $0.speakerVolume = Int(value) }
                    }
                }
                .listRowBackground(Palette.surface)

                Section {
                    slider("Чувствительность микрофона", value: $threshold, range: -100...0, unit: " дБ") { value in
                        await model.update { $0.activateMicrophoneThreshold = Int(value) }
                    }
                    Button("Подобрать автоматически") {
                        Task { await model.update { $0.activateMicrophoneThreshold = 0 } }
                    }
                } footer: {
                    Text(settings.activateMicrophoneThreshold ?? 0 == 0
                        ? "Подобрана автоматически по фоновому шуму. Сдвиньте ползунок, чтобы задать вручную"
                        : "Задана вручную")
                }
                .listRowBackground(Palette.surface)

                Section {
                    Picker("Шумоподавление", selection: Binding(
                        get: { settings.noiceReductionType },
                        set: { value in Task { await model.update { $0.noiceReductionType = value } } }
                    )) {
                        ForEach(VoiceSettings.NoiseReduction.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Эхоподавление", isOn: Binding(
                        get: { settings.echoSuppression },
                        set: { value in Task { await model.update { $0.echoSuppression = value } } }
                    ))
                    .accessibilityIdentifier("voice.echo")
                } footer: {
                    Text("Уменьшает фоновый шум микрофона. Настройки сохраняются для этого устройства")
                }
                .listRowBackground(Palette.surface)
            } else if model.errorMessage == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(Palette.danger)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Голос и видео")
        .task {
            await model.load()
            if let settings = model.settings {
                micVolume = Double(settings.micVolume)
                speakerVolume = Double(settings.speakerVolume)
                if let value = settings.activateMicrophoneThreshold, value != 0 { threshold = Double(value) }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, save: @escaping (Double) async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue))\(unit)").foregroundStyle(Palette.textSecondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: 1) { editing in
                if !editing { Task { await save(value.wrappedValue) } }
            }
            .accessibilityLabel(title)
            .accessibilityValue("\(Int(value.wrappedValue))\(unit)")
        }
    }
}

/// Свой приветственный стикер: выбор картинки и сброс.
struct GreetingSettingsView: View {
    @State var model: GreetingModel
    let upload: (Data, String, String) async throws -> String

    @State private var item: PhotosPickerItem?

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    RemoteImage(key: model.sticker?.urlS3, contentMode: .fit) {
                        Image(systemName: "hand.wave.fill")
                            .font(.system(size: 72))
                            .foregroundStyle(Palette.accent)
                    }
                    .frame(width: 160, height: 160)
                    .accessibilityLabel("Приветственный стикер")
                    Spacer()
                }
                let pickTitle = model.isSaving ? "Сохраняем…" : "Выбрать стикер"
                PhotosPicker(selection: $item, matching: .images) {
                    Label(pickTitle, systemImage: "photo")
                }
                .disabled(model.isSaving)
                .accessibilityIdentifier("greeting.pick")
                if model.sticker != nil {
                    Button("Сбросить", role: .destructive) { Task { await model.reset() } }
                }
            } footer: {
                Text("Собеседник увидит его в пустом чате с вами и сможет отправить одним нажатием.")
            }
            .listRowBackground(Palette.surface)
            if let error = model.errorMessage {
                Text(error).foregroundStyle(Palette.danger)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Приветственный стикер")
        .task { await model.load() }
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            item = nil
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                let type = newItem.supportedContentTypes.first ?? .png
                let ext = type.preferredFilenameExtension ?? "png"
                await model.set(data: data, extension: ext) { data in
                    try await upload(data, "greeting.\(ext)", type.preferredMIMEType ?? "image/png")
                }
            }
        }
    }
}
