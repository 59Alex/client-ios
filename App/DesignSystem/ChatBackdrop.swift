import ConnectSettings
import SwiftUI
import UIKit

/// Фон переписки (`ChatBackdrop.tsx`): цвет чата, поверх — картинка темы, заполняющая экран
/// как `background-size: cover` с точкой кадрирования `background-position`.
struct ChatBackdrop: View {
    private var background: ChatBackground? { AppTheme.chatBackground }

    @State private var image: UIImage?
    @State private var loadedId: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Palette.chat
                if let image, loadedId == background?.id {
                    let frame = Self.cover(image.size, in: proxy.size, focus: background?.focus ?? (0.5, 0.5))
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea(edges: .bottom)
        .accessibilityHidden(true)
        .task(id: background?.id) { await load() }
    }

    /// Прямоугольник картинки: масштаб по большей стороне, лишнее срезается по доле позиции.
    static func cover(_ imageSize: CGSize, in container: CGSize, focus: (x: Double, y: Double)) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = max(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) * focus.x, y: (container.height - size.height) * focus.y, width: size.width, height: size.height)
    }

    private func load() async {
        guard let background, let url = AppTheme.backgrounds.imageURL(for: background) else {
            image = nil
            loadedId = nil
            return
        }
        // Сервис отдаёт картинки с публичным кэшем на неделю: URLCache повторно не скачивает.
        guard let (data, _) = try? await URLSession.shared.data(from: url), let decoded = UIImage(data: data) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            image = decoded
            loadedId = background.id
        }
    }
}
