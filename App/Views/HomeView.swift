import ConnectCalls
import ConnectChat
import ConnectCore
import ConnectFeatures
import ConnectFiles
import ConnectInbox
import PhotosUI
import SwiftUI

/// Основная навигация вошедшего пользователя. Звонок открывается поверх любой вкладки.
struct HomeView: View {
    let dependencies: SignedInDependencies
    let session: SessionModel

    private var calls: P2PCallModel { dependencies.calls }
    @State private var navigation = AppNavigation()
    @State private var isInboxShown = false
    @State private var isCreateGroupShown = false

    private var inboxBadge: Int {
        dependencies.unread.summary.unread + dependencies.invitations.pendingCount
    }

    private var groupTools: GroupTools {
        let contacts = dependencies.contacts
        let inbox = dependencies.inbox
        return GroupTools(
            contacts: {
                if case let .loaded(list) = contacts.state { return list }
                return []
            },
            invite: { groupId, contact in
                (try? await inbox.invite(kind: .group, targetId: groupId, recipientUserId: contact.userId)) != nil
            }
        )
    }

    var body: some View {
        ZStack {
            TabView(selection: $navigation.tab) {
                ChatListView(model: dependencies.p2pChats, unread: dependencies.unread, makeChat: dependencies.makeChat, path: $navigation.chatsPath, inboxBadge: inboxBadge, onOpenInbox: { isInboxShown = true }, groupTools: groupTools)
                    .tabItem { Label("Чаты", systemImage: "bubble.left.and.bubble.right") }
                    .badge(dependencies.unread.unreadCount(kind: .p2p))
                    .tag(AppNavigation.Tab.chats)
                ChatListView(model: dependencies.groupChats, unread: dependencies.unread, makeChat: dependencies.makeChat, path: $navigation.groupsPath, inboxBadge: inboxBadge, onOpenInbox: { isInboxShown = true }, onCreateGroup: { isCreateGroupShown = true }, groupTools: groupTools)
                    .tabItem { Label("Группы", systemImage: "person.3") }
                    .badge(dependencies.unread.unreadCount(kind: .group))
                    .tag(AppNavigation.Tab.groups)
                ContactsView(model: dependencies.contacts, calls: calls, myUsername: dependencies.user.username) { route in
                    navigation.open(route)
                }
                    .tabItem { Label("Контакты", systemImage: "person.2") }
                    .tag(AppNavigation.Tab.contacts)
                ProfileView(dependencies: dependencies, session: session, onLogout: logout)
                    .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
                    .tag(AppNavigation.Tab.profile)
            }
            .environment(\.mediaLoader, dependencies.mediaLoader)
            .sheet(isPresented: $isInboxShown) {
                InboxView(notifications: dependencies.notifications, invitations: dependencies.invitations) { route in
                    Task {
                        if route.kind == .group { await dependencies.groupChats.load() }
                        navigation.open(route)
                    }
                }
                .environment(\.mediaLoader, dependencies.mediaLoader)
            }
            .sheet(isPresented: $isCreateGroupShown) {
                CreateGroupSheet(model: CreateGroupModel(me: dependencies.user.userId, api: dependencies.inbox), contacts: groupTools.contacts()) {
                    Task { await dependencies.groupChats.load() }
                }
                .environment(\.mediaLoader, dependencies.mediaLoader)
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
        .task { await dependencies.unread.run() }
        .task { await dependencies.invitations.load() }
        .task { await dependencies.contacts.load() }
        .task(id: dependencies.unread.eventRevision) {
            guard dependencies.unread.eventRevision > 0 else { return }
            await dependencies.invitations.load()
            if dependencies.unread.lastEventKind == "invitation" || dependencies.unread.lastEventKind == "sync" {
                await dependencies.groupChats.load()
            }
        }
    }

    private func logout() async {
        await calls.hangUp()
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
                .listRowBackground(Palette.surface)

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
                    .listRowBackground(Palette.surface)
                }

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
