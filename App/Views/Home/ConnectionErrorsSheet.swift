import ConnectFeatures
import SwiftUI

/// Панель ошибок подключения (`ConnectionErrorBar.tsx`): сбои медиасервера и доступ к микрофону.
struct ConnectionErrorsSheet: View {
    let model: ConnectionErrorsModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if model.entries.isEmpty {
                        Label("Ошибок подключения нет", systemImage: "checkmark.circle")
                            .foregroundStyle(Palette.success)
                            .padding(.top, 24)
                    }
                    ForEach(model.entries) { entry in
                        ConnectionErrorCard(entry: entry, model: model)
                    }
                }
                .padding(16)
            }
            .background(Palette.canvas)
            .navigationTitle("Подключение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

private struct ConnectionErrorCard: View {
    let entry: ConnectionErrorEntry
    let model: ConnectionErrorsModel

    private var resolved: Bool { entry.state == .resolved }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(resolved ? entry.kind.resolvedTitle : entry.kind.title, systemImage: resolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(resolved ? Palette.success : Palette.danger)
            if !resolved {
                Text(entry.kind.description)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                if entry.kind == .microphone {
                    MicrophoneSettingsGuide()
                }
                actions
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay { RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(resolved ? Palette.success : Palette.danger, lineWidth: 1.5) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection.error.\(entry.kind.rawValue)")
    }

    @ViewBuilder
    private var actions: some View {
        switch entry.kind {
        case .mediaServer:
            Button {
                Task { await model.checkMediaServer() }
            } label: {
                HStack {
                    if entry.retrying { ProgressView().tint(Palette.onAccent) }
                    Text(entry.kind.retryLabel)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(entry.retrying)
            .accessibilityIdentifier("connection.retry.mediaServer")
        case .mediaConnection:
            Button(entry.kind.retryLabel) { model.dismiss(.mediaConnection) }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("connection.retry.mediaConnection")
        case .microphone:
            if MicrophonePermission.status == .undetermined {
                Button("Запросить доступ") {
                    Task { model.microphone(granted: await MicrophonePermission.request()) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("connection.microphone.request")
            } else {
                Button {
                    MicrophonePermission.openAppSettings()
                } label: {
                    Label("Открыть настройки Connect", systemImage: "gearshape")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("connection.microphone.settings")
            }
        }
    }
}

/// Подсказка перед переходом: iOS открывает страницу Connect в «Настройках», но не даёт
/// приложению подсветить нужный переключатель, поэтому он показан заранее.
struct MicrophoneSettingsGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("В настройках включите переключатель:")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
            VStack(spacing: 0) {
                row(icon: "app.badge", tint: .gray, title: "Connect", trailing: AnyView(Image(systemName: "chevron.right").foregroundStyle(.secondary)), highlighted: false)
                Divider().padding(.leading, 52)
                row(icon: "mic.fill", tint: .orange, title: "Микрофон", trailing: AnyView(Toggle("", isOn: .constant(true)).labelsHidden().tint(.green).allowsHitTesting(false)), highlighted: true)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .environment(\.colorScheme, .light)
            Text("После возврата в Connect доступ проверится сам.")
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("В настройках Connect включите переключатель «Микрофон». После возврата доступ проверится сам.")
        .accessibilityIdentifier("connection.microphone.guide")
    }

    private func row(icon: String, tint: Color, title: String, trailing: AnyView, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint, in: RoundedRectangle(cornerRadius: 7))
            Text(title).foregroundStyle(.black)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.accent, lineWidth: 3)
                    .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .padding(3)
            }
        }
    }
}
