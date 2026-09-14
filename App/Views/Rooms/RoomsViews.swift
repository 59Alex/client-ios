import ConnectCalls
import ConnectChat
import ConnectCore
import ConnectFeatures
import ConnectRooms
import SwiftUI

/// Открытая из рейла комната со стеком каналов; без выбранной комнаты — список комнат.
struct RoomsListView: View {
    let model: RoomsModel
    let unread: UnreadModel
    let makeRoom: @MainActor (String) -> RoomModel
    let makeCalendar: @MainActor (String) -> RoomCalendarModel
    let makeChat: @MainActor (ChatRoute) -> ChatModel
    let groupTools: GroupTools
    let inviteToRoom: @MainActor (_ roomId: String, _ contact: Contact) async -> Bool
    let origin: URL
    let voice: RoomVoiceModel
    let directory: UserDirectory
    let canJoinVoice: @MainActor () -> Bool
    let room: AppNavigation.RoomSelection?
    let onOpenRoom: (RoomCard) -> Void
    @Binding var path: [RoomRoute]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let room {
                    RoomScreen(model: makeRoom(room.id), title: room.name, unread: unread, makeCalendar: makeCalendar, groupTools: groupTools, inviteToRoom: inviteToRoom, origin: origin, voice: voice, directory: directory, canJoinVoice: canJoinVoice)
                        .id(room.id)
                } else {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.canvas)
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
            .navigationDestination(for: RoomRoute.self) { route in
                switch route {
                case let .room(id, name):
                    RoomScreen(model: makeRoom(id), title: name, unread: unread, makeCalendar: makeCalendar, groupTools: groupTools, inviteToRoom: inviteToRoom, origin: origin, voice: voice, directory: directory, canJoinVoice: canJoinVoice)
                case let .channel(route):
                    RoomChannelContainer(route: route, makeChat: makeChat)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().controlSize(.large)
        case let .failed(message):
            ContentUnavailableView {
                Label(message, systemImage: "wifi.exclamationmark")
            } actions: {
                Button("Повторить") { Task { await model.load() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 240)
            }
        case let .loaded(rooms) where rooms.isEmpty:
            ContentUnavailableView("Комнат пока нет", systemImage: "square.grid.2x2", description: Text("Создайте комнату или войдите по приглашению"))
        case let .loaded(rooms):
            List(rooms) { room in
                Button { onOpenRoom(room) } label: {
                    HStack(spacing: 12) {
                        Avatar(name: room.name, imageKey: room.avatarKey)
                        Text(room.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                        UnreadBadge(count: model.unreadCount(room, unread: unread))
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("rooms.row.\(room.id)")
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }
}

enum RoomRoute: Hashable, Codable {
    case room(id: String, name: String)
    case channel(ChatRoute)
}

private struct RoomChannelContainer: View {
    @State private var model: ChatModel

    init(route: ChatRoute, makeChat: @MainActor (ChatRoute) -> ChatModel) {
        _model = State(initialValue: makeChat(route))
    }

    var body: some View {
        ChatScreen(model: model)
    }
}

/// Комната: текстовые и голосовые каналы, календарь, приглашения.
private struct RoomScreen: View {
    @State var model: RoomModel
    let title: String
    let unread: UnreadModel
    let makeCalendar: @MainActor (String) -> RoomCalendarModel
    let groupTools: GroupTools
    let inviteToRoom: @MainActor (_ roomId: String, _ contact: Contact) async -> Bool
    let origin: URL
    let voice: RoomVoiceModel
    let directory: UserDirectory
    let canJoinVoice: @MainActor () -> Bool

    @State private var isCalendarShown = false
    @State private var isInviteShown = false
    @State private var newChannel: NewChannel?

    private var name: String { model.details?.name ?? title }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Palette.roomName)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .accessibilityAddTraits(.isHeader)

                    sectionHeader("Текстовые каналы", addLabel: "Создать текстовый канал", identifier: "room.createText", kind: .text)
                    if model.textChannels.isEmpty {
                        emptyRow("Каналов пока нет")
                    }
                    ForEach(model.textChannels) { channel in
                        NavigationLink(value: RoomRoute.channel(ChatRoute(kind: .channel, roomId: channel.id, title: "# \(channel.name)"))) {
                            ChannelRow(systemImage: "number", name: channel.name, highlighted: false, unread: unread.unreadCount(kind: .channel, roomId: channel.id))
                        }
                        .buttonStyle(ChannelRowStyle())
                        .accessibilityIdentifier("room.channel.\(channel.id)")
                    }

                    sectionHeader("Голосовые каналы", addLabel: "Создать голосовой канал", identifier: "room.createVoice", kind: .voice)
                    if model.voiceChannels.isEmpty {
                        emptyRow("Голосовых каналов нет")
                    }
                    ForEach(model.voiceChannels) { channel in
                        voiceChannel(channel)
                    }

                    if model.failed {
                        Text("Не удалось загрузить комнату")
                            .foregroundStyle(Palette.danger)
                            .padding(16)
                    }
                }
                .padding(.bottom, 16)
            }
            .refreshable { await model.load() }
        }
        .background(Palette.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
        .task(id: model.voiceChannels.map(\.id)) {
            await voice.watch(channelIds: model.voiceChannels.map(\.id))
        }
        .task(id: voice.presence.byKey.keys.sorted()) {
            await directory.load(voice.presence.byKey.values.map(\.userId))
        }
        .sheet(isPresented: $isCalendarShown) {
            RoomCalendarSheet(model: makeCalendar(model.roomId), canCreate: model.canManage)
        }
        .sheet(isPresented: $isInviteShown) {
            GroupMembersSheet(members: model.details?.members ?? [], contacts: groupTools.contacts()) { contact in
                await inviteToRoom(model.roomId, contact)
            }
        }
        .sheet(item: $newChannel) { channel in
            TextPromptSheet(title: channel.kind == .text ? "Текстовый канал" : "Голосовой канал", placeholder: "Название", actionTitle: "Создать", identifier: "room.createChannel") { name in
                await model.createChannel(name: name, kind: channel.kind)
            }
        }
    }

    /// Шапка комнаты (`room-sidebar-header`): буква комнаты, приглашение, ссылка и календарь.
    private var header: some View {
        HStack(spacing: 4) {
            Text(String(name.first(where: \.isLetter) ?? "#").uppercased())
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(Palette.textPrimary)
                .padding(.leading, 16)
                .accessibilityHidden(true)
            Spacer()
            ShellIconButton(systemImage: "person.badge.plus", label: "Пригласить в комнату", identifier: "room.invite") { isInviteShown = true }
            ShareLink(item: InviteLinks.roomURL(origin: origin, roomId: model.roomId)) {
                Image(systemName: "link")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Поделиться ссылкой-приглашением")
            .accessibilityIdentifier("room.share")
            ShellIconButton(systemImage: "calendar", label: "Открыть календарь комнаты", identifier: "room.calendar") { isCalendarShown = true }
        }
        .padding(.trailing, 8)
        .frame(minHeight: 64)
        .background(Palette.chrome)
    }

    private func sectionHeader(_ text: String, addLabel: String, identifier: String, kind: RoomChannel.Kind) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.caption.weight(.bold))
                .kerning(0.6)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if model.canManage {
                ShellIconButton(systemImage: "plus", label: addLabel, identifier: identifier) { newChannel = NewChannel(kind: kind) }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: 44)
        .padding(.top, 12)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
    }

    @ViewBuilder
    private func voiceChannel(_ channel: RoomChannel) -> some View {
        let inChannel = voice.channelId == channel.id && voice.phase != .idle
        Button {
            Task {
                if inChannel {
                    await voice.leave()
                } else if canJoinVoice() {
                    await voice.join(channelId: channel.id, name: channel.name)
                }
            }
        } label: {
            ChannelRow(systemImage: inChannel ? "speaker.wave.3.fill" : "speaker.wave.2", name: channel.name, highlighted: inChannel, unread: 0, trailing: inChannel ? "Выйти" : nil)
        }
        .buttonStyle(ChannelRowStyle())
        .accessibilityIdentifier("room.voice.\(channel.id)")
        ForEach(voice.presence.participants(in: channel.id), id: \.userId) { participant in
            let speaking = voice.channelId == channel.id && (voice.session?.participants.first { $0.userId == participant.userId }?.isSpeaking ?? false)
            HStack(spacing: 8) {
                Avatar(name: memberName(participant.userId), size: 24)
                    .overlay { if speaking { Circle().strokeBorder(Palette.success, lineWidth: 2) } }
                Text(memberName(participant.userId))
                    .font(.subheadline)
                    .foregroundStyle(Palette.roomName)
                Spacer()
                if participant.muted { Image(systemName: "mic.slash").foregroundStyle(Palette.textSecondary).accessibilityLabel("Микрофон выключен") }
                if participant.speakerOff { Image(systemName: "speaker.slash").foregroundStyle(Palette.textSecondary).accessibilityLabel("Звук выключен") }
            }
            .frame(minHeight: 32)
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .overlay(alignment: .leading) { Rectangle().fill(Palette.textSecondary.opacity(0.3)).frame(width: 1) }
            .padding(.leading, 34)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("room.voice.participant.\(participant.userId)")
        }
    }
}

/// Строка канала комнаты (`room-channel`): иконка, имя, счётчик.
private struct ChannelRow: View {
    let systemImage: String
    let name: String
    let highlighted: Bool
    let unread: Int
    var trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(highlighted ? Palette.success : Palette.textSecondary)
                .frame(width: 22)
            Text(name)
                .foregroundStyle(Palette.roomName)
                .lineLimit(1)
            Spacer()
            if let trailing {
                Text(trailing).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.danger)
            }
            if unread > 0 { CountBadge(count: unread) }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct ChannelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 8)
    }
}

extension RoomScreen {
    fileprivate func memberName(_ userId: String) -> String {
        if let member = model.details?.members.first(where: { $0.userId == userId }) { return member.displayName }
        if let known = directory.name(of: userId) { return known }
        if let voiceName = voice.session?.participants.first(where: { $0.userId == userId })?.username { return voiceName }
        return "Пользователь"
    }
}

private struct NewChannel: Identifiable {
    let kind: RoomChannel.Kind
    var id: String { kind.rawValue }
}

/// Календарь комнаты: дата, события дня и создание события.
private struct RoomCalendarSheet: View {
    @State var model: RoomCalendarModel
    let canCreate: Bool

    /// Неделя с понедельника, как сетка календаря веб-клиента.
    static var mondayCalendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "ru_RU")
        calendar.firstWeekday = 2
        return calendar
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDay = Date()
    @State private var isCreateShown = false

    var body: some View {
        NavigationStack {
            List {
                DatePicker("Дата", selection: $selectedDay, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                    .environment(\.calendar, Self.mondayCalendar)
                    .listRowBackground(Palette.surface)
                Section(selectedDay.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU")))) {
                    let events = model.events(on: selectedDay)
                    if events.isEmpty {
                        Text(model.failed ? "Не удалось загрузить события" : "Событий нет").foregroundStyle(Palette.textSecondary)
                    }
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.body.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                            Text(ChatDates.messageTime(event.startsAt)).font(.subheadline).foregroundStyle(Palette.accent)
                            if !event.description.isEmpty {
                                Text(event.description).font(.subheadline).foregroundStyle(Palette.textSecondary)
                            }
                            if !event.notificationTimes.isEmpty {
                                Text("Напоминаний: \(event.notificationTimes.count)").font(.caption).foregroundStyle(Palette.textSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Календарь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                if canCreate {
                    ToolbarItem(placement: .primaryAction) {
                        Button { isCreateShown = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Новое событие")
                            .accessibilityIdentifier("calendar.create")
                    }
                }
            }
            .task(id: Calendar.current.dateComponents([.year, .month], from: selectedDay)) {
                await model.load(month: selectedDay)
            }
            .sheet(isPresented: $isCreateShown) {
                CreateEventSheet(model: model, day: selectedDay)
            }
        }
    }
}

private struct CreateEventSheet: View {
    let model: RoomCalendarModel
    let day: Date

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var startsAt = Date()
    @State private var reminders: [Date] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $title)
                        .accessibilityIdentifier("event.title")
                    TextField("Описание", text: $details, axis: .vertical)
                        .lineLimit(2...6)
                    DatePicker("Начало", selection: $startsAt)
                }
                Section {
                    ForEach(reminders.indices, id: \.self) { index in
                        DatePicker("Напоминание \(index + 1)", selection: $reminders[index])
                    }
                    .onDelete { reminders.remove(atOffsets: $0) }
                    if reminders.count < RoomCalendarModel.maxReminders {
                        Button("Добавить напоминание", systemImage: "bell.badge.plus") {
                            reminders.append(max(Date().addingTimeInterval(3600), startsAt.addingTimeInterval(-3600)))
                        }
                    }
                } header: {
                    Text("Напоминания")
                } footer: {
                    Text("До \(RoomCalendarModel.maxReminders), не позже начала и не чаще чем раз в 12 часов")
                }
                if let error {
                    Text(error).foregroundStyle(Palette.danger)
                }
            }
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .navigationTitle("Новое событие")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        Task {
                            error = await model.create(title: title, description: details, startsAt: startsAt, reminders: reminders)
                            if error == nil { dismiss() }
                        }
                    }
                    .accessibilityIdentifier("event.save")
                }
            }
            .onAppear {
                let calendar = Calendar.current
                startsAt = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
                if startsAt < Date() { startsAt = Date().addingTimeInterval(3600) }
            }
        }
    }
}

/// Вкладка «Каналы»: ленты-подписки и создание.
struct FeedsListView: View {
    let model: FeedsModel
    let unread: UnreadModel
    let makeFeed: @MainActor (String) -> FeedModel
    let origin: URL
    let contacts: () -> [Contact]

    @State private var isCreateShown = false
    @State private var isJoinShown = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !model.loaded && !model.failed {
                    ProgressView().controlSize(.large)
                } else if model.failed {
                    ContentUnavailableView {
                        Label("Не удалось загрузить каналы", systemImage: "wifi.exclamationmark")
                    } actions: {
                        Button("Повторить") { Task { await model.load() } }
                    }
                } else if model.feeds.isEmpty {
                    ContentUnavailableView("Каналов пока нет", systemImage: "megaphone", description: Text("Создайте канал или подпишитесь по приглашению"))
                } else {
                    List(model.feeds) { feed in
                        NavigationLink(value: feed.id) {
                            HStack(spacing: 12) {
                                Avatar(name: feed.name, imageKey: feed.avatarKey)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(feed.name).font(.body.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                                    Text(feed.lastPost ?? "Постов пока нет").font(.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(1)
                                }
                                Spacer()
                                UnreadBadge(count: unread.summary.chats.first { $0.chatType == "POST_FEED" && $0.chatId == feed.id }?.unread ?? 0)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("feeds.row.\(feed.id)")
                    }
                    .scrollContentBackground(.hidden)
                    .refreshable { await model.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                HStack(spacing: 0) {
                    CreateButton(label: "Создать канал", identifier: "feeds.create") { isCreateShown = true }
                    Button { isJoinShown = true } label: {
                        Label("По ссылке", systemImage: "link")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.button))
                            .overlay { RoundedRectangle(cornerRadius: Radius.button).strokeBorder(Palette.divider) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Подписаться по ссылке")
                    .accessibilityIdentifier("feeds.join")
                }
            }
            .navigationDestination(for: String.self) { feedId in
                FeedScreen(model: makeFeed(feedId), title: model.feeds.first { $0.id == feedId }?.name ?? "Канал", unread: unread, origin: origin, contacts: contacts) {
                    Task { await model.load() }
                }
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $isCreateShown) {
            TextPromptSheet(title: "Новый канал", placeholder: "Название", actionTitle: "Создать", identifier: "feeds.createName") { name in
                await model.create(name: name)
            }
        }
        .sheet(isPresented: $isJoinShown) {
            TextPromptSheet(title: "Подписаться по ссылке", placeholder: "Ссылка-приглашение в канал", actionTitle: "Подписаться", identifier: "feeds.joinLink") { link in
                switch await model.join(link: link) {
                case let .success(feedId):
                    path = [feedId]
                    return nil
                case let .failure(error):
                    return error.message
                }
            }
        }
    }
}

private struct FeedScreen: View {
    @State var model: FeedModel
    let title: String
    let unread: UnreadModel
    let origin: URL
    let contacts: () -> [Contact]
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isMembersShown = false
    @State private var commentsPostId: CommentsTarget?

    private struct CommentsTarget: Identifiable {
        let id: String
    }
    @State private var confirmDelete = false
    @State private var isActionsShown = false

    private var summaryStamp: Int {
        unread.summary.chats.first { $0.chatType == "POST_FEED" && $0.chatId == model.feedId }?.unread ?? -1
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isBanned {
                ContentUnavailableView("Вы забанены владельцем канала", systemImage: "nosign")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.hasOlder {
                            ProgressView().frame(maxWidth: .infinity).task { await model.loadOlder() }
                        }
                        if model.posts.isEmpty, !model.isLoading {
                            Text("Постов пока нет").foregroundStyle(Palette.textSecondary).frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        ForEach(model.posts) { post in
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(post.attachments, id: \.self) { attachment in
                                    Label(attachment.displayName, systemImage: attachment.kind == .image ? "photo" : "doc")
                                        .font(.subheadline)
                                        .foregroundStyle(Palette.textPrimary)
                                }
                                if !post.text.isEmpty {
                                    Text(post.text).foregroundStyle(Palette.textPrimary).textSelection(.enabled)
                                }
                                HStack(spacing: 12) {
                                    Text("\(ChatDates.listTime(post.createdAt)) · \(ChatDates.messageTime(post.createdAt))")
                                    if let views = post.uniqueViewsCount {
                                        Label("\(views)", systemImage: "eye").accessibilityLabel("Просмотров: \(views)")
                                    }
                                    Spacer()
                                    Button { commentsPostId = CommentsTarget(id: post.id) } label: {
                                        Label("\(post.commentsCount ?? 0)", systemImage: "bubble.left")
                                            .frame(minHeight: 32)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Комментарии: \(post.commentsCount ?? 0)")
                                    .accessibilityIdentifier("feed.comments.\(post.id)")
                                }
                                .font(.caption).foregroundStyle(Palette.textSecondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
                            .overlay { RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Palette.border) }
                            .id(post.id)
                            .onAppear { model.markViewed(post.id) }
                            .accessibilityElement(children: .contain)
                        }
                    }
                    .padding(12)
                }
                .defaultScrollAnchor(.bottom)
                footer
            }
        }
        .background(Palette.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isActionsShown = true } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Действия канала")
                .accessibilityIdentifier("feed.menu")
            }
        }
        .confirmationDialog("Канал", isPresented: $isActionsShown) {
            Button("Участники") { isMembersShown = true }
            if model.canUnsubscribe {
                Button("Отписаться") { Task { await model.setSubscribed(false); onChanged() } }
            }
            if model.canDelete {
                Button("Удалить канал", role: .destructive) { confirmDelete = true }
            }
        }
        .task { await model.load() }
        .task(id: summaryStamp) { await model.refresh() }
        .sheet(isPresented: $isMembersShown) {
            FeedMembersSheet(model: model, origin: origin, contacts: contacts())
        }
        .sheet(item: $commentsPostId, onDismiss: { Task { await model.refresh() } }) { target in
            PostCommentsSheet(model: model.commentsModel(postId: target.id))
        }
        .confirmationDialog("Удалить канал?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                Task {
                    if await model.deleteFeed() {
                        onChanged()
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.canPost {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Новый пост", text: $model.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
                    .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.border) }
                    .accessibilityIdentifier("feed.input")
                Button {
                    Task { _ = await model.publish() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(Palette.onAccent)
                        .background(Palette.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Опубликовать")
                .accessibilityIdentifier("feed.publish")
            }
            .padding(12)
        } else if !model.isSubscribed, !model.isLoading {
            Button("Подписаться") { Task { await model.setSubscribed(true); onChanged() } }
                .buttonStyle(PrimaryButtonStyle())
                .padding(12)
                .accessibilityIdentifier("feed.subscribe")
        }
        if let error = model.errorMessage {
            Text(error).font(.footnote).foregroundStyle(Palette.danger).padding(.bottom, 8)
        }
    }
}

/// Участники канала с модерацией (`PostFeedMembersList.tsx`), приглашение ссылкой и из контактов.
private struct FeedMembersSheet: View {
    let model: FeedModel
    let origin: URL
    let contacts: [Contact]

    @Environment(\.dismiss) private var dismiss
    @State private var selected: MemberAction?
    @State private var moderatorCandidate: FeedMembers.Member?
    @State private var isContactsShown = false

    private enum Section: String {
        case moderator, subscriber, banned
    }

    private struct MemberAction: Identifiable {
        let member: FeedMembers.Member
        let section: Section
        var id: String { "\(section.rawValue):\(member.userId)" }
    }

    var body: some View {
        NavigationStack {
            List {
                SwiftUI.Section {
                    ShareLink(item: InviteLinks.feedURL(origin: origin, feedId: model.feedId)) {
                        Label("Пригласительная ссылка", systemImage: "link")
                    }
                    .accessibilityIdentifier("feed.members.link")
                    Button { isContactsShown = true } label: {
                        Label("Добавить из контактов", systemImage: "person.badge.plus")
                    }
                    .accessibilityIdentifier("feed.members.addContacts")
                }
                .listRowBackground(Palette.surface)

                if let admin = model.memberList?.admin {
                    SwiftUI.Section("Владелец") { Text("@\(admin.username)").foregroundStyle(Palette.textPrimary) }
                        .listRowBackground(Palette.surface)
                }
                memberSection("Модераторы", members: model.visibleModerators, section: .moderator, actionable: model.canAssignModerators || model.canBan)
                memberSection("Подписчики", members: model.visibleSubscribers, section: .subscriber, actionable: model.canAssignModerators || model.canBan)
                memberSection("Заблокированы", members: model.memberList?.bannedUsers ?? [], section: .banned, actionable: model.canUnban)

                if let error = model.moderationError {
                    Text(error).foregroundStyle(Palette.danger).listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Участники")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .confirmationDialog(selected.map { "@\($0.member.username)" } ?? "", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible, presenting: selected) { action in
                switch action.section {
                case .moderator:
                    if model.canAssignModerators {
                        Button("Снять модератора") { Task { await model.removeModerator(action.member.userId) } }
                    }
                    if model.canBan {
                        Button("Выдать бан", role: .destructive) { Task { await model.setBanned(true, userId: action.member.userId) } }
                    }
                case .subscriber:
                    if model.canAssignModerators {
                        Button("Сделать модератором") { moderatorCandidate = action.member }
                    }
                    if model.canBan {
                        Button("Выдать бан", role: .destructive) { Task { await model.setBanned(true, userId: action.member.userId) } }
                    }
                case .banned:
                    if model.canUnban {
                        Button("Разблокировать") { Task { await model.setBanned(false, userId: action.member.userId) } }
                    }
                }
            }
            .sheet(item: $moderatorCandidate) { member in
                ModeratorPrivilegesSheet(username: member.username) { privileges in
                    await model.makeModerator(member.userId, privileges: privileges)
                }
            }
            .sheet(isPresented: $isContactsShown) {
                FeedAddContactsSheet(model: model, contacts: contacts)
            }
        }
        .task { await model.loadMembers() }
    }

    @ViewBuilder
    private func memberSection(_ title: String, members: [FeedMembers.Member], section: Section, actionable: Bool) -> some View {
        if !members.isEmpty {
            SwiftUI.Section("\(title) · \(members.count)") {
                ForEach(members) { member in
                    Button {
                        if actionable { selected = MemberAction(member: member, section: section) }
                    } label: {
                        HStack {
                            Avatar(name: member.username, size: 32)
                            Text("@\(member.username)").foregroundStyle(Palette.textPrimary)
                            Spacer()
                            if actionable { Image(systemName: "ellipsis").foregroundStyle(Palette.textSecondary) }
                        }
                    }
                    .disabled(!actionable)
                    .accessibilityIdentifier("feed.member.\(section.rawValue).\(member.userId)")
                }
            }
            .listRowBackground(Palette.surface)
        }
    }
}

/// «Назначить модератором» (`PostFeedModeratorModal.tsx`): шесть прав, все выключены.
private struct ModeratorPrivilegesSheet: View {
    let username: String
    let submit: (FeedPrivileges) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var privileges = FeedPrivileges()
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("@\(username)") {
                    Toggle("Назначать модераторов", isOn: $privileges.canAssignModerators).accessibilityIdentifier("moderator.assign")
                    Toggle("Банить пользователей", isOn: $privileges.canBanUsers).accessibilityIdentifier("moderator.ban")
                    Toggle("Разбанивать пользователей", isOn: $privileges.canUnbanUsers).accessibilityIdentifier("moderator.unban")
                    Toggle("Публиковать посты", isOn: $privileges.canCreatePosts).accessibilityIdentifier("moderator.post")
                    Toggle("Удалять посты", isOn: $privileges.canDeletePosts).accessibilityIdentifier("moderator.deletePosts")
                    Toggle("Управлять комментариями", isOn: $privileges.canManageComments).accessibilityIdentifier("moderator.comments")
                }
                .listRowBackground(Palette.surface)
            }
            .tint(Palette.accent)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Назначить модератором")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Назначить") {
                        isSaving = true
                        Task {
                            await submit(privileges)
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("moderator.submit")
                }
            }
        }
    }
}

private struct FeedAddContactsSheet: View {
    let model: FeedModel
    let contacts: [Contact]

    @Environment(\.dismiss) private var dismiss
    @State private var added: Set<String> = []

    private var candidates: [Contact] {
        let list = model.memberList
        let known = Set(([list?.admin].compactMap { $0 } + (list?.moderators ?? []) + (list?.subscribers ?? []) + (list?.bannedUsers ?? [])).map(\.userId))
        return contacts.filter { !known.contains($0.userId) || added.contains($0.userId) }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { contact in
                HStack(spacing: 12) {
                    Avatar(name: contact.displayName, imageKey: contact.avatarKey)
                    VStack(alignment: .leading) {
                        Text(contact.displayName).foregroundStyle(Palette.textPrimary)
                        Text(contact.handle).font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    if added.contains(contact.userId) {
                        Text("Добавлен").font(.subheadline).foregroundStyle(Palette.textSecondary)
                    } else {
                        Button("Добавить") {
                            Task { if await model.addSubscriber(contact.userId) { added.insert(contact.userId) } }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("feed.addContact.\(contact.username)")
                    }
                }
                .listRowBackground(Palette.surface)
            }
            .overlay { if candidates.isEmpty { ContentUnavailableView("Все контакты уже в канале", systemImage: "person.2") } }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Добавить из контактов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

/// Комментарии поста (`PostCommentsThread.tsx`): опрос раз в 4 с, удаление своих.
private struct PostCommentsSheet: View {
    @State var model: PostCommentsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    if model.comments.isEmpty {
                        Text(model.failed ? "Не удалось загрузить комментарии" : "Комментариев пока нет")
                            .foregroundStyle(Palette.textSecondary)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(model.comments) { comment in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(comment.username.isEmpty ? "Пользователь" : "@\(comment.username)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Palette.messageName)
                                Spacer()
                                Text(ChatDates.messageTime(comment.createdAt)).font(.caption2).foregroundStyle(Palette.textSecondary)
                            }
                            Text(comment.text).foregroundStyle(Palette.textPrimary)
                        }
                        .listRowBackground(Palette.surface)
                        .swipeActions {
                            if model.isOwn(comment), !comment.id.hasPrefix("local-") {
                                Button("Удалить", role: .destructive) { Task { await model.delete(comment) } }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("comment.\(comment.id)")
                    }
                }
                .scrollContentBackground(.hidden)

                HStack(spacing: 8) {
                    TextField("Комментарий", text: $model.draft, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 22))
                        .accessibilityIdentifier("comment.input")
                    Button { Task { await model.send() } } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(Palette.onAccent)
                            .background(Palette.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Отправить комментарий")
                    .accessibilityIdentifier("comment.send")
                }
                .padding(12)
                .background(Palette.surface)
            }
            .background(Palette.canvas)
            .navigationTitle("Комментарии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .task { await model.poll() }
    }
}

/// Лист с одним полем ввода; `submit` возвращает текст ошибки или `nil` при успехе.
struct TextPromptSheet: View {
    let title: String
    let placeholder: String
    let actionTitle: String
    let identifier: String
    let submit: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("\(identifier).field")
                if let error {
                    Text(error).foregroundStyle(Palette.danger)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        Task {
                            isSubmitting = true
                            error = await submit(text)
                            isSubmitting = false
                            if error == nil { dismiss() }
                        }
                    }
                    .disabled(isSubmitting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("\(identifier).submit")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            CountBadge(count: count)
                .accessibilityHidden(false)
                .accessibilityLabel("Непрочитанных: \(count)")
        }
    }
}
