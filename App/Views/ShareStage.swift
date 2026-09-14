import ConnectCalls
import LiveKit
import SwiftUI

/// Сцена трансляций (`ShareStage.tsx`): главная камера или экран крупно, остальные миниатюрами;
/// нажатие на миниатюру делает её главной, экраны показываются целиком.
struct ShareStage: View {
    let shares: [RemoteShare]
    let track: @MainActor (RemoteShare) -> AnyObject?

    @State private var mainId: String?

    private var main: RemoteShare? {
        shares.first { $0.id == mainId } ?? shares.first { $0.kind == .screen } ?? shares.first
    }

    var body: some View {
        VStack(spacing: 8) {
            if let main {
                tile(main, large: true)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(main.kind == .screen ? 16 / 9 : 4 / 3, contentMode: .fit)
                    .accessibilityIdentifier("call.share.main")
            }
            let others = shares.filter { $0.id != main?.id }.prefix(3)
            if !others.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(others)) { share in
                        Button { mainId = share.id } label: {
                            tile(share, large: false)
                                .frame(width: 96, height: 72)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Сделать главной: \(title(share))")
                    }
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call.shareStage")
    }

    private func tile(_ share: RemoteShare, large: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if share.isReady, let videoTrack = track(share) as? VideoTrack {
                LiveKitVideo(track: videoTrack, fit: share.kind == .screen)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Label(title(share), systemImage: share.kind == .screen ? "rectangle.on.rectangle" : "video.fill")
                .font(large ? .caption.weight(.semibold) : .caption2)
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
    }

    private func title(_ share: RemoteShare) -> String {
        let name = share.username ?? "Участник"
        return share.kind == .screen ? "Экран · \(name)" : name
    }
}

private struct LiveKitVideo: UIViewRepresentable {
    let track: VideoTrack
    let fit: Bool

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = fit ? .fit : .fill
        view.track = track
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        if view.track !== track { view.track = track }
        view.layoutMode = fit ? .fit : .fill
    }
}
