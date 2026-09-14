import ConnectCalls
import SwiftUI

/// Экран личного звонка поверх приложения: входящий вызов, соединение и разговор.
struct CallView: View {
    let model: P2PCallModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 16) {
                Avatar(name: peerName, size: 112)
                    .overlay {
                        if model.isRemoteSpeaking {
                            Circle().strokeBorder(Palette.accent, lineWidth: 3).padding(-6)
                        }
                    }

                Text(peerName)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("call.peer")

                status
                    .accessibilityIdentifier("call.status")

                if model.isRemoteMuted {
                    Label("Микрофон собеседника выключен", systemImage: "mic.slash")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityIdentifier("call.remoteMuted")
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 24)

            controls
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas.ignoresSafeArea())
    }

    private var peerName: String {
        guard let peer = model.peer else { return "" }
        return peer.name.isEmpty ? peer.username : peer.name
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case let .active(startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Self.duration(from: startedAt, to: context.date))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityLabel("Вызов активен, \(Self.duration(from: startedAt, to: context.date))")
            }
        case .failed:
            Text(model.statusText)
                .font(.title3)
                .foregroundStyle(Palette.danger)
        default:
            Text(model.statusText)
                .font(.title3)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .incoming:
            HStack(spacing: 48) {
                RoundCallButton(title: "Отклонить", systemImage: "phone.down.fill", fill: Palette.danger, identifier: "call.decline") {
                    Task { await model.decline() }
                }
                RoundCallButton(title: "Ответить", systemImage: "phone.fill", fill: Palette.accent, identifier: "call.accept") {
                    Task { await model.accept() }
                }
            }
        case .failed:
            Button("Закрыть") { Task { await model.hangUp() } }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("call.close")
        default:
            HStack(spacing: 32) {
                RoundCallButton(
                    title: model.isMuted ? "Включить микрофон" : "Выключить микрофон",
                    systemImage: model.isMuted ? "mic.slash.fill" : "mic.fill",
                    fill: model.isMuted ? Palette.textPrimary : Palette.surface,
                    foreground: model.isMuted ? Palette.canvas : Palette.textPrimary,
                    identifier: "call.mute"
                ) {
                    Task { await model.toggleMute() }
                }
                RoundCallButton(title: "Завершить", systemImage: "phone.down.fill", fill: Palette.danger, identifier: "call.hangup") {
                    Task { await model.hangUp() }
                }
                RoundCallButton(
                    title: model.isSpeakerOn ? "Выключить громкую связь" : "Громкая связь",
                    systemImage: model.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                    fill: model.isSpeakerOn ? Palette.textPrimary : Palette.surface,
                    foreground: model.isSpeakerOn ? Palette.canvas : Palette.textPrimary,
                    identifier: "call.speaker"
                ) {
                    model.toggleSpeaker()
                }
            }
        }
    }

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }
}

private struct RoundCallButton: View {
    let title: String
    let systemImage: String
    let fill: Color
    var foreground: Color?
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: 68, height: 68)
                .foregroundStyle(foreground ?? Palette.onAccent)
                .background(fill, in: Circle())
                .overlay { Circle().strokeBorder(Palette.border) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}
