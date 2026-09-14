import Observation

/// Раздел главной, открытая комната и стеки чатов: «Написать» из контактов открывает чат на вкладке «Чаты».
@MainActor
@Observable
final class AppNavigation {
    enum Tab: Hashable {
        case chats
        case groups
        /// Открыта комната из рейла; вкладки главной скрыты, как в веб-клиенте.
        case rooms
        case feeds
        case contacts
    }

    struct RoomSelection: Hashable {
        let id: String
        let name: String
    }

    var tab: Tab = .chats {
        didSet { if tab != .rooms { lastHomeTab = tab } }
    }
    private(set) var lastHomeTab: Tab = .chats
    var room: RoomSelection?
    var isRailShown = true
    var chatsPath: [ChatRoute] = []
    var groupsPath: [ChatRoute] = []
    var roomsPath: [RoomRoute] = []

    /// Внутри чата или канала рейл, панель пользователя и вкладки уступают место переписке.
    var isDeep: Bool {
        switch tab {
        case .chats: !chatsPath.isEmpty
        case .groups: !groupsPath.isEmpty
        case .rooms: !roomsPath.isEmpty
        case .feeds, .contacts: false
        }
    }

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

    func openRoom(id: String, name: String) {
        room = RoomSelection(id: id, name: name)
        roomsPath = []
        tab = .rooms
    }

    func goHome() {
        room = nil
        roomsPath = []
        tab = lastHomeTab
    }
}
