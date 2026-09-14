import SwiftUI

@main
struct ConnectApp: App {
    @State private var dependencies = AppDependencies.makeForLaunch()

    init() {
        // Фоны чата — картинки по 100–700 КБ с публичным кэшем: стандартного дискового кэша не хватает.
        URLCache.shared = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
        }
    }
}
