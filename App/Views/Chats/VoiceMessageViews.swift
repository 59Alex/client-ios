import AVFoundation
import ConnectChat
import ConnectFiles
import SwiftUI

/// Кнопка записи голосового (`MessageInput.tsx`): удержание пишет, отпускание отправляет,
/// свайп вверх больше 72 pt фиксирует запись с паузой, удалением и отправкой.
struct VoiceRecordButton: View {
    let recorder: VoiceRecorder
    @Binding var isLocked: Bool
    let onSend: (Data) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isPressing = false
    @State private var startTask: Task<Void, Never>?

    static let lockDistance: CGFloat = 72

    var body: some View {
        Image(systemName: recorder.isActive ? "mic.fill" : "mic")
            .font(.title3)
            .frame(width: 44, height: 44)
            .foregroundStyle(recorder.isActive ? Palette.onAccent : Palette.textSecondary)
            .background(recorder.isActive ? Palette.danger : Palette.canvas, in: Circle())
            .scaleEffect(isPressing ? 1.15 : 1)
            .overlay(alignment: .top) {
                if recorder.isActive && !isLocked {
                    Image(systemName: "lock")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(dragOffset < -Self.lockDistance ? Palette.accent : Palette.textSecondary)
                        .padding(6)
                        .background(Palette.surface, in: Capsule())
                        .offset(y: -44 + min(0, dragOffset / 3))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isPressing {
                            isPressing = true
                            startTask = Task { _ = await recorder.start() }
                        }
                        dragOffset = value.translation.height
                        if !isLocked, dragOffset < -Self.lockDistance, recorder.isActive {
                            isLocked = true
                        }
                    }
                    .onEnded { _ in
                        isPressing = false
                        dragOffset = 0
                        guard !isLocked else { return }
                        Task {
                            await startTask?.value
                            if let data = recorder.finish() { onSend(data) }
                        }
                    }
            )
            .accessibilityLabel(recorder.isActive ? "Идёт запись голосового" : "Записать голосовое сообщение")
            .accessibilityHint("Удерживайте, чтобы записать; проведите вверх, чтобы зафиксировать запись")
            .accessibilityAction(named: "Начать запись") {
                isLocked = true
                Task { _ = await recorder.start() }
            }
            .accessibilityIdentifier("chat.voice.record")
            .onChange(of: recorder.isActive) { _, active in
                if !active { isLocked = false }
            }
    }

}

/// Панель зафиксированной записи: время, уровень, пауза, удаление и отправка.
struct VoiceRecordingBar: View {
    let recorder: VoiceRecorder
    let onSend: (Data) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ShellIconButton(systemImage: "trash", label: "Удалить запись", identifier: "chat.voice.discard", tint: Palette.danger) {
                recorder.cancel()
            }
            Circle()
                .fill(Palette.danger)
                .frame(width: 10, height: 10)
                .opacity(recorder.state == .recording ? 1 : 0.4)
            Text(VoiceMessagePlayer.format(recorder.elapsed))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Palette.textPrimary)
                .accessibilityIdentifier("chat.voice.elapsed")
            GeometryReader { proxy in
                Capsule().fill(Palette.divider)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Palette.accent).frame(width: max(6, proxy.size.width * recorder.level))
                    }
            }
            .frame(height: 6)
            ShellIconButton(systemImage: recorder.state == .paused ? "record.circle" : "pause.fill",
                            label: recorder.state == .paused ? "Продолжить запись" : "Пауза",
                            identifier: "chat.voice.pause") {
                if recorder.state == .paused { recorder.resume() } else { recorder.pause() }
            }
            Button {
                if let data = recorder.finish() { onSend(data) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Palette.onAccent)
                    .background(Palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Отправить голосовое")
            .accessibilityIdentifier("chat.voice.send")
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.voice.bar")
    }
}

/// Голосовое в пузыре (`VoiceMessage.tsx`): кнопка, 32 полосы прогресса и длительность.
struct VoiceMessagePlayer: View {
    let attachment: ChatAttachment
    let isOwn: Bool

    @Environment(\.mediaLoader) private var mediaLoader
    @Environment(\.fileAPI) private var fileAPI
    @State private var player: AVAudioPlayer?
    @State private var progress: Double = 0
    @State private var isPlaying = false
    @State private var failed = false
    @State private var isLoading = false

    private var foreground: Color { isOwn ? Palette.onOwnBubble : Palette.onOtherBubble }

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await toggle() } } label: {
                ZStack {
                    Circle().fill(Palette.accent)
                    if isLoading {
                        ProgressView().tint(Palette.onAccent)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(Palette.onAccent)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(failed)
            .accessibilityLabel(isPlaying ? "Пауза" : "Воспроизвести голосовое")
            .accessibilityIdentifier("voice.play.\(attachment.name)")

            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<32, id: \.self) { index in
                    Capsule()
                        .fill(Double(index) / 32 < progress ? Palette.accent : foreground.opacity(0.35))
                        .frame(width: 3, height: CGFloat(10 + (index * 7) % 20))
                }
            }
            .accessibilityHidden(true)

            Text(failed ? "Не удалось воспроизвести" : Self.format(player.map { isPlaying ? $0.currentTime : $0.duration } ?? 0))
                .font(.caption.monospacedDigit())
                .foregroundStyle(foreground.opacity(0.8))
        }
        .frame(minWidth: 220, alignment: .leading)
        .task(id: isPlaying) {
            while isPlaying, let player {
                progress = player.duration > 0 ? player.currentTime / player.duration : 0
                if !player.isPlaying {
                    isPlaying = false
                    progress = 0
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onDisappear { player?.stop(); isPlaying = false }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    private func toggle() async {
        if let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                activatePlayback()
                player.play()
                isPlaying = true
            }
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard let data = await loadData(), let created = try? AVAudioPlayer(data: data) else {
            failed = true
            return
        }
        activatePlayback()
        player = created
        created.play()
        isPlaying = true
    }

    /// AAC с iOS и Safari проигрывается как есть; webm/ogg с веба перекодирует сервис.
    private func loadData() async -> Data? {
        let ext = attachment.extension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if ["m4a", "mp4", "aac", "mp3", "wav"].contains(ext) {
            return await mediaLoader?.data(for: attachment.urlS3)
        }
        return try? await fileAPI?.playableVoice(urlS3: attachment.urlS3)
    }

    private func activatePlayback() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

extension EnvironmentValues {
    /// API файлов для перекодированного голосового.
    @Entry var fileAPI: (any FileAPI)?
}
