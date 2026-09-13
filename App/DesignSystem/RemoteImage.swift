import ConnectFiles
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// Загрузчик файлов connect-s3; без него картинки не грузятся (превью, тесты).
    @Entry var mediaLoader: MediaLoader?
}

/// Картинка из connect-s3 по ключу; пока грузится или если не найдена — `placeholder`.
struct RemoteImage<Placeholder: View>: View {
    let key: String?
    var contentMode: ContentMode = .fill
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.mediaLoader) private var loader
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: key) {
            guard let key, !key.isEmpty, let loader else {
                image = nil
                return
            }
            let data = await loader.data(for: key)
            image = data.flatMap(UIImage.init(data:))
        }
    }
}
