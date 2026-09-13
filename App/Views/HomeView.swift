import ConnectCore
import ConnectFeatures
import SwiftUI

/// Каркас основной навигации. Разделы наполняются на следующих этапах переноса.
struct HomeView: View {
    let user: User
    let session: SessionModel

    var body: some View {
        TabView {
            PlaceholderScreen(title: "Чаты", systemImage: "bubble.left.and.bubble.right", description: "Личные и групповые чаты появятся на следующем этапе")
                .tabItem { Label("Чаты", systemImage: "bubble.left.and.bubble.right") }
            PlaceholderScreen(title: "Контакты", systemImage: "person.2", description: "Список контактов и поиск появятся на следующем этапе")
                .tabItem { Label("Контакты", systemImage: "person.2") }
            ProfileView(user: user, session: session)
                .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
        }
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
                        Task { await session.logout() }
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
