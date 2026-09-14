import ConnectCalls
import ConnectCore
import SwiftUI

/// Экран группового звонка: входящий вызов, плитки участников, ожидающие и отказавшиеся.
struct GroupCallView: View {
    let model: GroupCallModel
    let names: [String: String]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(model.title.isEmpty ? "Групповой звонок" : model.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityIdentifier("group.call.title")
                status
                    .accessibilityIdentifier("group.call.status")
            }
            .padding(.top, 32)
            .padding(.horizontal, 20)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(model.participants) { participant in
                        ParticipantTile(name: name(of: participant.userId), state: participant.stateText, isSpeaking: participant.isSpeaking, isMuted: participant.isMuted)
                            .accessibilityIdentifier("group.call.participant.\(participant.userId)")
                    }
                    ForEach(model.pendingUserIds, id: \.self) { userId in
                        ParticipantTile(name: name(of: userId), state: "Вызываем…", isSpeaking: false, isMuted: false)
                            .opacity(0.6)
                    }
                    ForEach(model.declinedUserIds, id: \.self) { userId in
                        ParticipantTile(name: name(of: userId), state: "Отклонил(а)", isSpeaking: false, isMuted: false)
                            .opacity(0.45)
                    }
                }
                .padding(20)
            }

            controls
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas.ignoresSafeArea())
    }

    private func name(of userId: String) -> String {
        names[userId] ?? model.session?.participants.first { $0.userId == userId }?.username ?? "Участник"
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case let .active(startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("Созвон активен · \(CallView.duration(from: startedAt, to: context.date))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)
            }
        case .incoming:
            Text("Входящий групповой звонок").foregroundStyle(Palette.textSecondary)
        case .connecting:
            Text("Соединение...").foregroundStyle(Palette.textSecondary)
        case let .failed(message):
            Text(message).foregroundStyle(Palette.danger)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .incoming:
            HStack(spacing: 48) {
                RoundControl(title: "Отклонить", systemImage: "phone.down.fill", fill: Palette.danger, identifier: "group.call.decline") {
                    Task { await model.decline() }
                }
                RoundControl(title: "Присоединиться", systemImage: "phone.fill", fill: Palette.accent, identifier: "group.call.accept") {
                    Task { await model.accept() }
                }
            }
        case .failed:
            Button("Закрыть") { Task { await model.hangUp() } }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("group.call.close")
        default:
            let muted = model.session?.isMuted ?? false
            let speakerOff = model.session?.isSpeakerOff ?? false
            HStack(spacing: 32) {
                RoundControl(title: muted ? "Включить микрофон" : "Выключить микрофон", systemImage: muted ? "mic.slash.fill" : "mic.fill", fill: muted ? Palette.textPrimary : Palette.surface, foreground: muted ? Palette.canvas : Palette.textPrimary, identifier: "group.call.mute") {
                    Task { await model.toggleMute() }
                }
                RoundControl(title: "Выйти из звонка", systemImage: "phone.down.fill", fill: Palette.danger, identifier: "group.call.hangup") {
                    Task { await model.hangUp() }
                }
                RoundControl(title: speakerOff ? "Включить звук" : "Выключить звук", systemImage: speakerOff ? "speaker.slash.fill" : "speaker.wave.2.fill", fill: speakerOff ? Palette.textPrimary : Palette.surface, foreground: speakerOff ? Palette.canvas : Palette.textPrimary, identifier: "group.call.speaker") {
                    Task { await model.toggleSpeakerOff() }
                }
            }
        }
    }
}

private struct ParticipantTile: View {
    let name: String
    let state: String
    let isSpeaking: Bool
    let isMuted: Bool

    var body: some View {
        VStack(spacing: 8) {
            Avatar(name: name, size: 64)
                .overlay {
                    if isSpeaking { Circle().strokeBorder(Palette.accent, lineWidth: 3).padding(-4) }
                }
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Label(state, systemImage: isMuted ? "mic.slash" : (isSpeaking ? "waveform" : "phone"))
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay { RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(isSpeaking ? Palette.accent : Palette.border) }
        .accessibilityElement(children: .combine)
    }
}

struct RoundControl: View {
    let title: String
    let systemImage: String
    let fill: Color
    var foreground: Color = Palette.onAccent
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: 68, height: 68)
                .foregroundStyle(foreground)
                .background(fill, in: Circle())
                .overlay { Circle().strokeBorder(Palette.border) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// Панель текущего голосового канала над вкладками.
struct VoiceChannelBar: View {
    let model: RoomVoiceModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.phase == .connecting ? "Подключение…" : "Голосовой канал")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
                Text(model.channelName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if case let .failed(message) = model.phase {
                    Text(message).font(.caption).foregroundStyle(Palette.danger)
                }
            }
            Spacer()
            let muted = model.session?.isMuted ?? false
            let speakerOff = model.session?.isSpeakerOff ?? false
            barButton(muted ? "mic.slash.fill" : "mic.fill", label: muted ? "Включить микрофон" : "Выключить микрофон", identifier: "voice.mute") {
                Task { await model.toggleMute() }
            }
            barButton(speakerOff ? "speaker.slash.fill" : "speaker.wave.2.fill", label: speakerOff ? "Включить звук" : "Выключить звук", identifier: "voice.speaker") {
                Task { await model.toggleSpeakerOff() }
            }
            barButton("phone.down.fill", label: "Выйти из канала", identifier: "voice.leave", tint: Palette.danger) {
                Task { await model.leave() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay { RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Palette.border) }
        .padding(.horizontal, 12)
        .accessibilityIdentifier("voice.bar")
    }

    private func barButton(_ image: String, label: String, identifier: String, tint: Color = Palette.textPrimary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .frame(width: 44, height: 44)
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
