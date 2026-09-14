import Foundation
import Observation

/// Раздел главной, открытая комната и стеки чатов: «Написать» из контактов открывает чат на вкладке «Чаты».
@MainActor
@Observable
final class AppNavigation {
    enum Tab: String, Hashable, Codable {
        case chats
        case groups
        /// Открыта комната из рейла; вкладки главной скрыты, как в веб-клиенте.
        case rooms
        case feeds
        case contacts
    }

    struct RoomSelection: Hashable, Codable {
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

    /// Последнее место (`lastLocation.ts`): раздел, комната, открытые чаты и рейл. Звонки не восстанавливаются.
    struct Snapshot: Codable, Equatable {
        var tab: Tab
        var lastHomeTab: Tab
        var room: RoomSelection?
        var isRailShown: Bool
        var chatsPath: [ChatRoute]
        var groupsPath: [ChatRoute]
        var roomsPath: [RoomRoute]
    }

    var snapshot: Snapshot {
        Snapshot(tab: tab, lastHomeTab: lastHomeTab, room: room, isRailShown: isRailShown, chatsPath: chatsPath, groupsPath: groupsPath, roomsPath: roomsPath)
    }

    func restore(_ snapshot: Snapshot) {
        lastHomeTab = snapshot.lastHomeTab == .rooms ? .chats : snapshot.lastHomeTab
        room = snapshot.room
        isRailShown = snapshot.isRailShown
        chatsPath = snapshot.chatsPath
        groupsPath = snapshot.groupsPath
        roomsPath = snapshot.roomsPath
        tab = snapshot.tab == .rooms && snapshot.room == nil && snapshot.roomsPath.isEmpty ? lastHomeTab : snapshot.tab
    }

    func goHome() {
        room = nil
        roomsPath = []
        tab = lastHomeTab
    }
}
