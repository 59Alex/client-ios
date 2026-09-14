import ConnectChat
import ConnectCore
import ConnectRooms
import SwiftUI

/// Вкладка «Комнаты»: список комнат, создание и вход по ссылке.
struct RoomsListView: View {
    let model: RoomsModel
    let unread: UnreadModel
    let makeRoom: @MainActor (String) -> RoomModel
    let makeCalendar: @MainActor (String) -> RoomCalendarModel
    let makeChat: @MainActor (ChatRoute) -> ChatModel
    let groupTools: GroupTools
    let inviteToRoom: @MainActor (_ roomId: String, _ contact: Contact) async -> Bool
    let origin: URL
    @Binding var path: [RoomRoute]

    @State private var isCreateShown = false
    @State private var isJoinShown = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.canvas)
                .navigationTitle("Комнаты")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Создать комнату", systemImage: "plus") { isCreateShown = true }
                            Button("Войти по приглашению", systemImage: "link") { isJoinShown = true }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Добавить комнату")
                        .accessibilityIdentifier("rooms.add")
                    }
                }
                .navigationDestination(for: RoomRoute.self) { route in
                    switch route {
                    case let .room(id, name):
                        RoomScreen(model: makeRoom(id), title: name, unread: unread, makeCalendar: makeCalendar, groupTools: groupTools, inviteToRoom: inviteToRoom, origin: origin)
                    case let .channel(route):
                        RoomChannelContainer(route: route, makeChat: makeChat)
                    }
                }
        }
        .task { await model.load() }
        .sheet(isPresented: $isCreateShown) {
            TextPromptSheet(title: "Новая комната", placeholder: "Название", actionTitle: "Создать", identifier: "rooms.create") { name in
                await model.createRoom(name: name)
            }
        }
        .sheet(isPresented: $isJoinShown) {
            TextPromptSheet(title: "Войти по приглашению", placeholder: "Ссылка-приглашение", actionTitle: "Войти", identifier: "rooms.join") { link in
                await model.join(link: link)
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
                NavigationLink(value: RoomRoute.room(id: room.id, name: room.name)) {
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
                .listRowBackground(Palette.surface)
                .accessibilityIdentifier("rooms.row.\(room.id)")
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }
}

enum RoomRoute: Hashable {
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

    @State private var isCalendarShown = false
    @State private var isInviteShown = false
    @State private var newChannel: NewChannel?
    @State private var isActionsShown = false

    var body: some View {
        List {
            Section("Текстовые каналы") {
                if model.textChannels.isEmpty {
                    Text("Каналов пока нет").foregroundStyle(Palette.textSecondary)
                }
                ForEach(model.textChannels) { channel in
                    NavigationLink(value: RoomRoute.channel(ChatRoute(kind: .channel, roomId: channel.id, title: "# \(channel.name)"))) {
                        HStack {
                            Label(channel.name, systemImage: "number")
                                .foregroundStyle(Palette.textPrimary)
                            Spacer()
                            UnreadBadge(count: unread.unreadCount(kind: .channel, roomId: channel.id))
                        }
                    }
                    .accessibilityIdentifier("room.channel.\(channel.id)")
                }
            }
            .listRowBackground(Palette.surface)

            Section {
                ForEach(model.voiceChannels) { channel in
                    Label(channel.name, systemImage: "speaker.wave.2")
                        .foregroundStyle(Palette.textPrimary)
                }
                if model.voiceChannels.isEmpty {
                    Text("Голосовых каналов нет").foregroundStyle(Palette.textSecondary)
                }
            } header: {
                Text("Голосовые каналы")
            } footer: {
                Text("Подключение к голосовым каналам появится на этапе звонков")
            }
            .listRowBackground(Palette.surface)

            if model.failed {
                Text("Не удалось загрузить комнату").foregroundStyle(Palette.danger)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle(model.details?.name ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: InviteLinks.roomURL(origin: origin, roomId: model.roomId)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Поделиться ссылкой-приглашением")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { isActionsShown = true } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Действия комнаты")
                .accessibilityIdentifier("room.menu")
            }
        }
        .confirmationDialog("Комната", isPresented: $isActionsShown) {
            Button("Календарь") { isCalendarShown = true }
            Button("Пригласить") { isInviteShown = true }
            if model.canManage {
                Button("Текстовый канал") { newChannel = NewChannel(kind: .text) }
                Button("Голосовой канал") { newChannel = NewChannel(kind: .voice) }
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
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

    @State private var isCreateShown = false

    var body: some View {
        NavigationStack {
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
                        .listRowBackground(Palette.surface)
                        .accessibilityIdentifier("feeds.row.\(feed.id)")
                    }
                    .scrollContentBackground(.hidden)
                    .refreshable { await model.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
            .navigationTitle("Каналы")
            .navigationDestination(for: String.self) { feedId in
                FeedScreen(model: makeFeed(feedId), title: model.feeds.first { $0.id == feedId }?.name ?? "Канал", unread: unread) {
                    Task { await model.load() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isCreateShown = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Создать канал")
                        .accessibilityIdentifier("feeds.create")
                }
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $isCreateShown) {
            TextPromptSheet(title: "Новый канал", placeholder: "Название", actionTitle: "Создать", identifier: "feeds.createName") { name in
                await model.create(name: name)
            }
        }
    }
}

private struct FeedScreen: View {
    @State var model: FeedModel
    let title: String
    let unread: UnreadModel
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var members: FeedMembers?
    @State private var isMembersShown = false
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
                                Text("\(ChatDates.listTime(post.createdAt)) · \(ChatDates.messageTime(post.createdAt))")
                                    .font(.caption).foregroundStyle(Palette.textSecondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.panel))
                            .overlay { RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Palette.border) }
                            .id(post.id)
                            .accessibilityElement(children: .combine)
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
            Button("Участники") {
                Task {
                    members = await model.members()
                    isMembersShown = true
                }
            }
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
            FeedMembersSheet(members: members)
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

private struct FeedMembersSheet: View {
    let members: FeedMembers?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let admin = members?.admin {
                    Section("Владелец") { Text("@\(admin.username)") }
                }
                if let moderators = members?.moderators, !moderators.isEmpty {
                    Section("Модераторы") { ForEach(moderators) { Text("@\($0.username)") } }
                }
                Section("Подписчики · \(members?.subscribers.count ?? 0)") {
                    ForEach(members?.subscribers ?? []) { Text("@\($0.username)") }
                }
                if let banned = members?.bannedUsers, !banned.isEmpty {
                    Section("Заблокированы") { ForEach(banned) { Text("@\($0.username)") } }
                }
            }
            .navigationTitle("Участники")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
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
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 7)
                .frame(minWidth: 22, minHeight: 22)
                .background(Palette.accent, in: Capsule())
                .accessibilityLabel("Непрочитанных: \(count)")
        }
    }
}
