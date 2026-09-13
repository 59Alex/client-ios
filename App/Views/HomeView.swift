import ConnectCalls
import ConnectCore
import ConnectFeatures
import SwiftUI

/// Основная навигация вошедшего пользователя. Звонок открывается поверх любой вкладки.
struct HomeView: View {
    let dependencies: SignedInDependencies
    let session: SessionModel

    private var calls: P2PCallModel { dependencies.calls }

    var body: some View {
        ZStack {
            TabView {
                PlaceholderScreen(title: "Чаты", systemImage: "bubble.left.and.bubble.right", description: "Личные и групповые чаты появятся на следующем этапе")
                    .tabItem { Label("Чаты", systemImage: "bubble.left.and.bubble.right") }
                ContactsView(model: dependencies.contacts, calls: calls)
                    .tabItem { Label("Контакты", systemImage: "person.2") }
                ProfileView(user: dependencies.user, session: session, onLogout: logout)
                    .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
            }
            .accessibilityHidden(calls.isInCall)

            // Слой, а не fullScreenCover: состояние звонка целиком в модели, закрывать экран жестом нельзя.
            if calls.isInCall {
                CallView(model: calls)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: calls.isInCall)
        .task { await dependencies.status.keepAlive(userId: dependencies.user.userId) }
        .task { await calls.runIncomingCalls() }
    }

    private func logout() async {
        await calls.hangUp()
        await dependencies.status.logout(userId: dependencies.user.userId)
        await session.logout()
    }
}

private struct PlaceholderScreen: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.canvas)
                .navigationTitle(title)
        }
    }
}

private struct ProfileView: View {
    let user: User
    let session: SessionModel
    let onLogout: @MainActor () async -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Palette.textPrimary)
                            .accessibilityIdentifier("profile.name")
                        Text(user.username)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)

                    LabeledContent("Email", value: user.email)
                    LabeledContent("Статус", value: user.status.title)
                }
                .listRowBackground(Palette.surface)

                Section {
                    Button("Выйти", role: .destructive) {
                        Task { await onLogout() }
                    }
                    .accessibilityIdentifier("profile.logout")
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Профиль")
        }
    }
}

private extension UserStatus {
    var title: String {
        switch self {
        case .online: "В сети"
        case .hidden: "Скрыт"
        case .offline: "Не в сети"
        }
    }
}
