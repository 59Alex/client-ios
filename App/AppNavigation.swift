import Observation

/// Выбранная вкладка и стеки чатов: «Написать» из контактов открывает чат на вкладке «Чаты».
@MainActor
@Observable
final class AppNavigation {
    enum Tab: Hashable {
        case chats
        case groups
        case contacts
        case profile
    }

    var tab: Tab = .chats
    var chatsPath: [ChatRoute] = []
    var groupsPath: [ChatRoute] = []

    func open(_ route: ChatRoute) {
        switch route.kind {
        case .p2p:
            tab = .chats
            chatsPath = [route]
        case .group:
            tab = .groups
            groupsPath = [route]
        }
    }
}
