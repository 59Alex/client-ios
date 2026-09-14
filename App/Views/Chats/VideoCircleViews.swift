import AVFoundation
import AVKit
import ConnectChat
import ConnectFiles
import SwiftUI

/// Предпросмотр камеры в круге, пока пишется кружок.
struct VideoCircleRecordingOverlay: View {
    let recorder: VideoCircleRecorder

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                CameraPreview(session: recorder.session)
                    .frame(width: 260, height: 260)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .trim(from: 0, to: min(1, recorder.elapsed / VideoCircleRecorder.maxDuration))
                            .stroke(Palette.danger, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(-6)
                    }
                Text(VoiceMessagePlayer.format(recorder.elapsed))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Идёт запись кружка")
        .accessibilityIdentifier("chat.circle.recording")
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// Кружок в переписке (`VideoCircle.tsx`): превью, по нажатию — HLS-поток со звуком и кольцом прогресса.
struct VideoCirclePlayer: View {
    let attachment: ChatAttachment

    @Environment(\.fileAPI) private var fileAPI
    @State private var player: AVPlayer?
    @State private var progress: Double = 0
    @State private var isLoading = false
    @State private var failed = false

    private let size: CGFloat = 200

    var body: some View {
        Button { Task { await toggle() } } label: {
            ZStack {
                RemoteImage(key: attachment.previewUrlS3) {
                    Palette.surface
                }
                .frame(width: size, height: size)
                if let player {
                    PlayerLayerView(player: player)
                        .frame(width: size, height: size)
                }
                if isLoading {
                    ProgressView().tint(.white)
                } else if player == nil {
                    Image(systemName: failed ? "exclamationmark.triangle.fill" : "play.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .shadow(radius: 0)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player == nil ? "Воспроизвести кружок" : "Остановить кружок")
        .accessibilityIdentifier("circle.play.\(attachment.name)")
        .task(id: player != nil) {
            while !Task.isCancelled, let current = player {
                if let item = current.currentItem, item.duration.seconds.isFinite, item.duration.seconds > 0 {
                    progress = current.currentTime().seconds / item.duration.seconds
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            if let item = notification.object as? AVPlayerItem, item === player?.currentItem { stop() }
        }
        .onDisappear { stop() }
    }

    private func toggle() async {
        if player != nil {
            stop()
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard let url = await fileAPI?.videoPlaylistURL(urlS3: attachment.urlS3) else {
            failed = true
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let created = AVPlayer(url: url)
        player = created
        created.play()
    }

    private func stop() {
        player?.pause()
        player = nil
        progress = 0
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
