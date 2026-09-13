import ConnectCore
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
                SignedInRoot(user: user, dependencies: dependencies)
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

/// Держит зависимости вошедшего пользователя, пока он в сессии.
private struct SignedInRoot: View {
    let user: User
    let dependencies: AppDependencies
    @State private var signedIn: SignedInDependencies?

    var body: some View {
        Group {
            if let signedIn, signedIn.user.userId == user.userId {
                HomeView(dependencies: signedIn, session: dependencies.session)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task(id: user.userId) {
            signedIn = dependencies.makeSignedIn(user: user)
        }
    }
}
