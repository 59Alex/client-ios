import ConnectFeatures
import SwiftUI

struct RootView: View {
    let dependencies: AppDependencies

    private var session: SessionModel { dependencies.session }

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()

            switch session.state {
            case .launching, .loadingUser:
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Загрузка")
            case .signedOut:
                LoginView(auth: dependencies.auth)
            case .signedIn(let user):
                HomeView(user: user, session: session)
            case .failed(let message):
                ContentUnavailableView {
                    Label(message, systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("Повторить") { Task { await session.loadUser() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: 240)
                    Button("Выйти", role: .destructive) { Task { await session.logout() } }
                }
            }
        }
        .task { await session.run() }
    }
}
