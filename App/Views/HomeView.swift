import ConnectCalls
import ConnectChat
import ConnectCore
import ConnectFeatures
import ConnectFiles
import ConnectInbox
import ConnectRooms
import ConnectSettings
import PhotosUI
import SwiftUI

/// Основная навигация вошедшего пользователя. Звонок открывается поверх любой вкладки.
struct HomeView: View {
    let dependencies: SignedInDependencies
    let session: SessionModel

    private var calls: P2PCallModel { dependencies.calls }
    @State private var navigation = AppNavigation()
    @State private var isCreateGroupShown = false
    @State private var isProfileShown = false

    private var groupTools: GroupTools {
        let contacts = dependencies.contacts
        let inbox = dependencies.inbox
        let groupCalls = dependencies.groupCalls
        let calls = calls
        let voice = dependencies.roomVoice
        return GroupTools(
            contacts: {
                if case let .loaded(list) = contacts.state { return list }
                return []
            },
            invite: { groupId, contact in
                (try? await inbox.invite(kind: .group, targetId: groupId, recipientUserId: contact.userId)) != nil
            },
            startCall: { groupId, title, members in
                if let active = try? await dependencies.groupCallAPI.activeCall(groupChatId: groupId) {
                    await groupCalls.join(callId: active.id, groupChatId: groupId, title: title)
                } else {
                    await groupCalls.start(groupChatId: groupId, name: title, memberUserIds: members)
                }
            },
            canCall: { !calls.isInCall && !groupCalls.isInCall && !voice.isInCall },
            activeCall: { groupId in
                guard !groupCalls.isInCall else { return nil }
                return try? await dependencies.groupCallAPI.activeCall(groupChatId: groupId)
            },
            joinCall: { record, title in
                await groupCalls.join(callId: record.id, groupChatId: record.groupChatId, title: title)
            },
            directory: dependencies.directory
        )
    }

    /// Имена для плиток группового звонка из справочника пользователей.
    private var callNames: [String: String] {
        dependencies.directory.cards.mapValues(\.displayName)
    }

    @State private var inboxSection: InboxView.Section?
    @State private var isRoomActionsShown = false
    @State private var isCreateRoomShown = false
    @State private var isJoinRoomShown = false
    @State private var myCard: Contact?
    @State private var didRestoreNavigation = false
    @State private var isCallMinimized = false
    @State private var isConnectionErrorsShown = false

    private var tabItems: [HomeTabBar.Item] {
        let unread = dependencies.unread
        return [
            .init(tab: .chats, title: "Чаты", systemImage: "envelope", identifier: "home.tab.chats", badge: unread.unreadCount(kind: .p2p)),
            .init(tab: .groups, title: "Группы", systemImage: "person.2", identifier: "home.tab.groups", badge: unread.unreadCount(kind: .group)),
            .init(tab: .feeds, title: "Каналы", systemImage: "doc.text", identifier: "home.tab.feeds", badge: 0),
            .init(tab: .contacts, title: "Контакты", systemImage: "person.2.badge.plus", identifier: "home.tab.contacts", badge: 0),
        ]
    }

    private var contactStatuses: [String: UserStatus] {
        guard case let .loaded(list) = dependencies.contacts.state else { return [:] }
        return Dictionary(list.map { ($0.userId, $0.status) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        ZStack {
            shell
                .environment(\.mediaLoader, dependencies.mediaLoader)
                .environment(\.fileAPI, dependencies.files)
                .environment(\.greetingLookup, { [settings = dependencies.settings] userId in
                    try? await settings.greeting(userId: userId)
                })
                .sheet(item: $inboxSection) { section in
                    InboxView(notifications: dependencies.notifications, invitations: dependencies.invitations, initialSection: section) { route in
                        Task {
                            if route.kind == .group { await dependencies.groupChats.load() }
                            navigation.open(route)
                        }
                    } onOpenRoom: { roomId, name in
                        Task {
                            await dependencies.rooms.load()
                            navigation.openRoom(id: roomId, name: name)
                        }
                    } onOpenFeeds: {
                        navigation.goHome()
                        navigation.tab = .feeds
                    }
                    .environment(\.mediaLoader, dependencies.mediaLoader)
                }
                .sheet(isPresented: $isConnectionErrorsShown) {
                    ConnectionErrorsSheet(model: dependencies.connectionErrors)
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $isProfileShown) {
                    ProfileView(dependencies: dependencies, session: session, onLogout: logout)
                        .environment(\.mediaLoader, dependencies.mediaLoader)
                }
                .sheet(isPresented: $isCreateGroupShown) {
                    CreateGroupSheet(model: CreateGroupModel(me: dependencies.user.userId, api: dependencies.inbox), contacts: groupTools.contacts()) {
                        Task { await dependencies.groupChats.load() }
                    }
                    .environment(\.mediaLoader, dependencies.mediaLoader)
                }
                .sheet(isPresented: $isCreateRoomShown) {
                    TextPromptSheet(title: "Новая комната", placeholder: "Название", actionTitle: "Создать", identifier: "rooms.create") { name in
                        await dependencies.rooms.createRoom(name: name)
                    }
                }
                .sheet(isPresented: $isJoinRoomShown) {
                    TextPromptSheet(title: "Войти по приглашению", placeholder: "Ссылка-приглашение", actionTitle: "Войти", identifier: "rooms.join") { link in
                        await dependencies.rooms.join(link: link)
                    }
                }
                .confirmationDialog("Комнаты", isPresented: $isRoomActionsShown) {
                    Button("Создать комнату") { isCreateRoomShown = true }
                    Button("Войти по приглашению") { isJoinRoomShown = true }
                }
                .accessibilityHidden(calls.isInCall || dependencies.groupCalls.isInCall)

            // Слой, а не fullScreenCover: состояние звонка целиком в модели, закрывать экран жестом нельзя.
            if calls.isInCall {
                if isCallMinimized, calls.phase != .incoming {
                    MinimizedCallBar(title: calls.peer.map { $0.name.isEmpty ? $0.username : $0.name } ?? "Звонок", phase: minimizedPhase(calls.phase), onExpand: { isCallMinimized = false }) {
                        Task { await calls.hangUp() }
                    }
                    .zIndex(1)
                } else {
                    CallView(model: calls, onMinimize: { isCallMinimized = true })
                        .transition(.opacity)
                        .zIndex(1)
                }
            } else if dependencies.groupCalls.isInCall {
                if isCallMinimized, dependencies.groupCalls.phase != .incoming {
                    MinimizedCallBar(title: dependencies.groupCalls.title.isEmpty ? "Групповой звонок" : dependencies.groupCalls.title, phase: minimizedPhase(dependencies.groupCalls.phase), onExpand: { isCallMinimized = false }) {
                        Task { await dependencies.groupCalls.hangUp() }
                    }
                    .zIndex(1)
                } else {
                    GroupCallView(model: dependencies.groupCalls, names: callNames, onMinimize: { isCallMinimized = true })
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: calls.isInCall)
        .animation(.easeInOut(duration: 0.2), value: isCallMinimized)
        .onChange(of: calls.isInCall || dependencies.groupCalls.isInCall) { _, inCall in
            // Следующий звонок снова открывается на весь экран.
            if !inCall { isCallMinimized = false }
        }
        .animation(.easeInOut(duration: 0.2), value: dependencies.groupCalls.isInCall)
        .onAppear {
            if !didRestoreNavigation {
                didRestoreNavigation = true
                if let saved = dependencies.navigationStore.load(userId: dependencies.user.userId) {
                    navigation.restore(saved)
                }
            }
            let groupCalls = dependencies.groupCalls
            let voice = dependencies.roomVoice
            let calls = calls
            calls.isBusyElsewhere = { groupCalls.isInCall || voice.isInCall }
            groupCalls.isBusyElsewhere = { calls.isInCall || voice.isInCall }
            let summaries = dependencies.summaries
            calls.onCallSummary = { await summaries.publish($0) }
            groupCalls.onCallSummary = { await summaries.publish($0) }
        }
        .onChange(of: navigation.snapshot) { _, snapshot in
            guard didRestoreNavigation else { return }
            dependencies.navigationStore.save(snapshot, userId: dependencies.user.userId)
        }
        .task { await dependencies.appearance.start(deviceId: dependencies.deviceId) }
        .task { await dependencies.status.keepAlive(userId: dependencies.user.userId) }
        .task { await calls.runIncomingCalls() }
        .task { await dependencies.groupCalls.runIncomingCalls() }
        .task { await dependencies.unread.run() }
        .task { await dependencies.invitations.load() }
        .task { await dependencies.contacts.load() }
        .task { await dependencies.rooms.load() }
        .task { await dependencies.toasts.refresh() }
        .task {
            // Шумо- и эхоподавление этого устройства применяются к микрофону звонков.
            AudioProcessing.apply(try? await dependencies.settings.voiceSettings(userId: dependencies.user.userId, deviceId: dependencies.deviceId))
        }
        .modifier(ConnectionTracking(dependencies: dependencies, isShown: $isConnectionErrorsShown))
        .task(id: dependencies.contacts.presenceUserIds) {
            await dependencies.contacts.watchPresence(api: dependencies.presence)
        }
        .onChange(of: inboxSection) { _, section in
            dependencies.toasts.isSuppressed = section != nil
        }
        .task { myCard = try? await dependencies.users.card(userId: dependencies.user.userId) }
        .task(id: dependencies.contacts.state) {
            if case let .loaded(list) = dependencies.contacts.state { dependencies.directory.remember(list) }
        }
        .task(id: dependencies.groupCalls.participants.map(\.userId) + dependencies.groupCalls.pendingUserIds + dependencies.groupCalls.declinedUserIds) {
            await dependencies.directory.load(dependencies.groupCalls.participants.map(\.userId) + dependencies.groupCalls.pendingUserIds + dependencies.groupCalls.declinedUserIds)
        }
        .task(id: dependencies.unread.eventRevision) {
            guard dependencies.unread.eventRevision > 0 else { return }
            try? await Task.sleep(for: .milliseconds(200))
            await dependencies.toasts.refresh()
            await dependencies.invitations.load()
            if dependencies.unread.lastEventKind == "invitation" || dependencies.unread.lastEventKind == "sync" {
                await dependencies.groupChats.load()
                await dependencies.rooms.load()
            }
        }
    }

    /// Раскладка мобильного веб-клиента: рейл комнат, верхняя панель, раздел, панель пользователя и вкладки.
    private var shell: some View {
        HStack(spacing: 0) {
            if navigation.isRailShown && !navigation.isDeep {
                RoomRail(
                    rooms: dependencies.rooms.rooms,
                    selectedRoomId: navigation.tab == .rooms ? navigation.room?.id : nil,
                    unreadCount: { dependencies.rooms.unreadCount($0, unread: dependencies.unread) },
                    onHome: { navigation.goHome() },
                    onRoom: { navigation.openRoom(id: $0.id, name: $0.name) },
                    onAdd: { isRoomActionsShown = true }
                )
                .transition(.move(edge: .leading))
            }
            VStack(spacing: 0) {
                HomeTopBar(
                    isRailShown: navigation.isRailShown,
                    invitations: dependencies.invitations.pendingCount,
                    notifications: dependencies.unread.summary.unread,
                    errorTone: dependencies.connectionErrors.tone,
                    onErrors: { isConnectionErrorsShown = true },
                    onMenu: { withAnimation(.easeOut(duration: 0.2)) { navigation.isRailShown.toggle() } },
                    onInvitations: { inboxSection = .invitations },
                    onNotifications: { inboxSection = .notifications }
                )
                section
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        if inboxSection == nil {
                            ToastStack(model: dependencies.toasts) { openToast($0) }
                        }
                    }
                if !navigation.isDeep {
                    UserPanel(user: dependencies.user, avatarKey: myCard?.avatarKey, voice: dependencies.roomVoice) { isProfileShown = true }
                        .background(Palette.canvas)
                    if navigation.tab != .rooms {
                        HomeTabBar(items: tabItems, selection: $navigation.tab)
                    }
                }
            }
            .background(Palette.canvas.ignoresSafeArea(edges: .bottom))
        }
        .background(Palette.chrome.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            LocalCameraPreview(camera: dependencies.roomVoice.camera)
                .padding(.top, 56)
                .padding(.trailing, 12)
        }
        .animation(.easeOut(duration: 0.2), value: navigation.isDeep)
    }

    @ViewBuilder
    private var section: some View {
        switch navigation.tab {
        case .chats:
            ChatListView(model: dependencies.p2pChats, unread: dependencies.unread, makeChat: dependencies.makeChat, path: $navigation.chatsPath, groupTools: groupTools, statusOf: { contactStatuses[$0] }, myUserId: dependencies.user.userId)
        case .groups:
            ChatListView(model: dependencies.groupChats, unread: dependencies.unread, makeChat: dependencies.makeChat, path: $navigation.groupsPath, onCreateGroup: { isCreateGroupShown = true }, groupTools: groupTools)
        case .rooms:
            RoomsListView(
                model: dependencies.rooms,
                unread: dependencies.unread,
                makeRoom: dependencies.makeRoom,
                makeCalendar: dependencies.makeCalendar,
                makeChat: dependencies.makeChat,
                groupTools: groupTools,
                inviteToRoom: { roomId, contact in
                    (try? await dependencies.inbox.invite(kind: .room, targetId: roomId, recipientUserId: contact.userId)) != nil
                },
                origin: dependencies.uiOrigin,
                voice: dependencies.roomVoice,
                directory: dependencies.directory,
                canJoinVoice: { !calls.isInCall && !dependencies.groupCalls.isInCall },
                room: navigation.room,
                onOpenRoom: { navigation.openRoom(id: $0.id, name: $0.name) },
                path: $navigation.roomsPath
            )
        case .feeds:
            FeedsListView(model: dependencies.feeds, unread: dependencies.unread, makeFeed: dependencies.makeFeed, origin: dependencies.uiOrigin, contacts: groupTools.contacts)
        case .contacts:
            ContactsView(model: dependencies.contacts, calls: calls, myUsername: dependencies.user.username, myUserId: dependencies.user.userId, repository: dependencies.contactsRepository, onChatsCreated: { Task { await dependencies.p2pChats.load() } }) { route in
                navigation.open(route)
            }
        }
    }

    /// Переход из тоста (`MainWindow.tsx`): чат, группа, канал комнаты; события и ленты — в свои разделы.
    private func openToast(_ notification: InboxNotification) {
        Task { await dependencies.toasts.dismiss(notification.id) }
        guard let chatId = notification.chatId else { return }
        switch notification.chatType {
        case .p2p:
            navigation.open(ChatRoute(kind: .p2p, roomId: chatId, title: chatTitle(dependencies.p2pChats, chatId) ?? "Личный чат"))
        case .group:
            navigation.open(ChatRoute(kind: .group, roomId: chatId, title: chatTitle(dependencies.groupChats, chatId) ?? "Группа"))
        case .postFeed, .postComment:
            navigation.tab = .feeds
        case .roomEvent:
            if let room = dependencies.rooms.rooms.first(where: { $0.id == chatId }) {
                navigation.openRoom(id: room.id, name: room.name)
            }
        case .room, .unknown:
            navigation.open(ChatRoute(kind: .channel, roomId: chatId, title: "Канал"))
        }
    }

    private func chatTitle(_ list: ChatListModel, _ roomId: String) -> String? {
        guard case let .loaded(chats) = list.state else { return nil }
        return chats.first { $0.roomId == roomId }?.title
    }

    private func minimizedPhase(_ phase: P2PCallModel.Phase) -> MinimizedCallBar.Phase {
        if case let .active(startedAt) = phase { return .active(startedAt) }
        return .connecting
    }

    private func minimizedPhase(_ phase: GroupCallModel.Phase) -> MinimizedCallBar.Phase {
        if case let .active(startedAt) = phase { return .active(startedAt) }
        return .connecting
    }

    private func logout() async {
        isProfileShown = false
        dependencies.appearance.stop()
        await calls.hangUp()
        await dependencies.groupCalls.hangUp()
        await dependencies.roomVoice.leave()
        await dependencies.status.logout(userId: dependencies.user.userId)
        await session.logout()
    }
}

private struct ProfileView: View {
    let dependencies: SignedInDependencies
    let session: SessionModel
    let onLogout: @MainActor () async -> Void

    @State private var card: Contact?
    @State private var avatarItem: PhotosPickerItem?
    @State private var isUploading = false
    @State private var uploadError: String?

    private var user: User { dependencies.user }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Avatar(name: user.name, size: 72, imageKey: card?.avatarKey)
                            .overlay {
                                if isUploading {
                                    ProgressView().frame(width: 72, height: 72).background(Palette.canvas.opacity(0.7), in: Circle())
                                }
                            }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.name)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Palette.textPrimary)
                                .accessibilityIdentifier("profile.name")
                            Text(user.username)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)

                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        Label("Сменить фото", systemImage: "camera")
                    }
                    .disabled(isUploading)
                    .accessibilityIdentifier("profile.changePhoto")

                    if let uploadError {
                        Text(uploadError).font(.footnote).foregroundStyle(Palette.danger)
                    }

                    LabeledContent("Email", value: user.email)
                    LabeledContent("Статус", value: user.status.title)
                }
                .listRowBackground(Palette.canvas)

                Section {
                    NavigationLink {
                        AccountSettingsView(model: AccountSettingsModel(userId: user.userId, api: dependencies.settings))
                    } label: {
                        SettingsRow(title: "Аккаунт", systemImage: "checkmark.shield")
                    }
                    .accessibilityIdentifier("settings.account")
                    NavigationLink {
                        NotificationSoundsView(model: NotificationSoundsModel(userId: user.userId, api: dependencies.settings))
                    } label: {
                        SettingsRow(title: "Уведомления", systemImage: "bell")
                    }
                    .accessibilityIdentifier("settings.sounds")
                    NavigationLink {
                        GreetingSettingsView(model: GreetingModel(userId: user.userId, api: dependencies.settings)) { data, filename, mime in
                            try await dependencies.files.upload(data: data, filename: filename, mimeType: mime, bucket: .userGallery, key: user.userId, userId: user.userId, username: user.username).urlS3
                        }
                    } label: {
                        SettingsRow(title: "Приветственный стикер", systemImage: "face.smiling")
                    }
                    .accessibilityIdentifier("settings.greeting")
                } header: {
                    SettingsSectionHeader(title: "Пользователь")
                }
                .listRowBackground(Palette.canvas)

                Section {
                    NavigationLink {
                        AppearanceSettingsView(model: dependencies.appearance)
                    } label: {
                        SettingsRow(title: "Оформление", systemImage: "paintpalette")
                    }
                    .accessibilityIdentifier("settings.appearance")
                    NavigationLink {
                        VoiceSettingsView(model: VoiceSettingsModel(userId: user.userId, deviceId: dependencies.deviceId, api: dependencies.settings))
                    } label: {
                        SettingsRow(title: "Голос и видео", systemImage: "headphones")
                    }
                    .accessibilityIdentifier("settings.voice")
                } header: {
                    SettingsSectionHeader(title: "Приложение")
                }
                .listRowBackground(Palette.canvas)

                if let gallery = card?.photoKeys, gallery.count > 1 {
                    Section("Фото") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(gallery, id: \.self) { key in
                                    RemoteImage(key: key) { Palette.canvas }
                                        .frame(width: 88, height: 88)
                                        .clipShape(RoundedRectangle(cornerRadius: Radius.button))
                                }
                            }
                        }
                    }
                    .listRowBackground(Palette.canvas)
                }

                Section {
                    Button("Выйти", role: .destructive) {
                        Task { await onLogout() }
                    }
                    .accessibilityIdentifier("profile.logout")
                }
                .listRowBackground(Palette.canvas)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.chrome, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        // Лист живёт в своей презентации: смена темы внутри него должна сразу менять и системные цвета.
        .preferredColorScheme(Palette.colorScheme)
        .task { card = try? await dependencies.users.card(userId: user.userId) }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            avatarItem = nil
            Task { await uploadAvatar(item) }
        }
    }

    /// Фото уходит в корзину `user-gallery` и добавляется в профиль аватаром (`SettingsProfileSection.tsx`).
    private func uploadAvatar(_ item: PhotosPickerItem) async {
        isUploading = true
        uploadError = nil
        defer { isUploading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let type = item.supportedContentTypes.first ?? .jpeg
            let ext = type.preferredFilenameExtension ?? "jpg"
            let file = try await dependencies.files.upload(
                data: data,
                filename: "avatar.\(ext)",
                mimeType: type.preferredMIMEType ?? "image/jpeg",
                bucket: .userGallery,
                key: user.userId,
                userId: user.userId,
                username: user.username
            )
            try await dependencies.users.addPhoto(userId: user.userId, urlS3: file.urlS3, name: file.name, extension: file.extension, isAvatar: true)
            card = try? await dependencies.users.card(userId: user.userId)
            if card?.avatarKey == nil { card = Contact(userId: user.userId, name: user.name, username: user.username, avatarKey: file.urlS3) }
        } catch {
            uploadError = "Не удалось загрузить фото"
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

/// Панель ошибок следит за звонками, голосовыми каналами и возвратом из «Настроек».
private struct ConnectionTracking: ViewModifier {
    let dependencies: SignedInDependencies
    @Binding var isShown: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var errors: ConnectionErrorsModel { dependencies.connectionErrors }

    func body(content: Content) -> some View {
        content
            .task { await errors.checkMediaServer() }
            .onChange(of: scenePhase) { _, phase in
                // Вернулись из «Настроек»: доступ к микрофону проверяется без нового запроса.
                guard phase == .active, errors.entries.contains(where: { $0.kind == .microphone }) else { return }
                errors.microphone(granted: MicrophonePermission.status == .granted)
            }
            .onChange(of: microphoneState) { old, new in
                // Отказ в ответ на звонок сразу показывает подсказку, как модалка веб-клиента.
                if new == .active, old != .active { isShown = true }
            }
            .onChange(of: dependencies.calls.phase) { _, phase in
                switch phase {
                case .active, .ringing: errors.mediaConnected()
                case let .failed(message): reportIfConnection(message)
                default: break
                }
            }
            .onChange(of: dependencies.groupCalls.phase) { _, phase in
                switch phase {
                case .active: errors.mediaConnected()
                case let .failed(message): reportIfConnection(message)
                default: break
                }
            }
            .onChange(of: dependencies.roomVoice.phase) { _, phase in
                switch phase {
                case .active: errors.mediaConnected()
                case let .failed(message): reportIfConnection(message)
                default: break
                }
            }
    }

    private var microphoneState: ConnectionErrorEntry.State? {
        errors.entries.first { $0.kind == .microphone }?.state
    }

    private func reportIfConnection(_ message: String) {
        guard ConnectionErrorsModel.isConnectionFailure(message) else { return }
        Task { await errors.reportMediaConnectionFailure() }
    }
}
