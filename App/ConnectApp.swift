import SwiftUI

@main
struct ConnectApp: App {
    @State private var dependencies = AppDependencies.makeForLaunch()

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
        }
    }
}
