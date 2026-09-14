import AVKit
import SwiftUI

struct StreamingVideo: Identifiable {
    let url: URL
    let title: String
    var id: URL { url }
}

/// Видео из чата потоком: системный плеер с перемоткой и картинкой в картинке.
struct StreamingVideoPlayer: View {
    let video: StreamingVideo

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier("video.player")
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(video.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                        .accessibilityIdentifier("video.close")
                }
            }
        }
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let created = AVPlayer(url: video.url)
            player = created
            created.play()
        }
        .onDisappear { player?.pause() }
    }
}
