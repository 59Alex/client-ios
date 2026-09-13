import Observation

/// Выбранная вкладка и стеки чатов: «Написать» из контактов открывает чат на вкладке «Чаты».
@MainActor
@Observable
final class AppNavigation {
    enum Tab: Hashable {
        case chats
        case groups
        case rooms
        case feeds
        case contacts
    }

    var tab: Tab = .chats
    var chatsPath: [ChatRoute] = []
    var groupsPath: [ChatRoute] = []
    var roomsPath: [RoomRoute] = []

    func open(_ route: ChatRoute) {
        switch route.kind {
        case .p2p:
            tab = .chats
            chatsPath = [route]
        case .group:
            tab = .groups
            groupsPath = [route]
        case .channel:
            tab = .rooms
            roomsPath = [.channel(route)]
        }
    }
}
