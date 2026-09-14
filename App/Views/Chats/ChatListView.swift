import ConnectCalls
import ConnectChat
import ConnectCore
import ConnectFeatures
import SwiftUI

/// Вкладка «Чаты» или «Группы»: список с превью, временем и непрочитанными.
struct ChatListView: View {
    let model: ChatListModel
    let unread: UnreadModel
    let makeChat: @MainActor (ChatRoute) -> ChatModel
    @Binding var path: [ChatRoute]
    var onCreateGroup: (() -> Void)?
    var groupTools: GroupTools?
    /// Статусы собеседников для точки «в сети» на аватаре.
    var statusOf: (String) -> UserStatus? = { _ in nil }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.canvas)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom, alignment: .leading) {
                    if let onCreateGroup {
                        CreateButton(label: "Создать группу", identifier: "groups.create", action: onCreateGroup)
                    }
                }
                .navigationDestination(for: ChatRoute.self) { route in
                    ChatScreenContainer(route: route, makeChat: makeChat, groupTools: groupTools)
                }
        }
        .task { await model.load() }
        .task { await model.keepFresh() }
        .task(id: unread.revision) {
            if unread.revision > 0 { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel("Загрузка")
        case let .failed(message):
            ContentUnavailableView {
                Label(message, systemImage: "wifi.exclamationmark")
            } actions: {
                Button("Повторить") { Task { await model.load() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 240)
            }
        case let .loaded(chats) where chats.isEmpty:
            ContentUnavailableView(
                model.kind == .p2p ? "Чатов пока нет" : "Групп пока нет",
                systemImage: model.kind == .p2p ? "bubble.left.and.bubble.right" : "person.3",
                description: Text(model.kind == .p2p ? "Напишите кому-нибудь из контактов" : "Создайте группу или примите приглашение")
            )
        case let .loaded(chats):
            List(chats) { chat in
                NavigationLink(value: ChatRoute(kind: chat.kind, roomId: chat.roomId, title: chat.title)) {
                    ChatRow(chat: chat, unread: unread.unreadCount(kind: chat.kind, roomId: chat.roomId), status: chat.partnerUserId.flatMap(statusOf))
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("chats.row.\(chat.roomId)")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }
}

/// Адрес открытого чата в навигации.
struct ChatRoute: Hashable, Codable {
    let kind: ChatKind
    let roomId: String
    let title: String
}

/// Держит модель чата, пока экран в стеке: `navigationDestination` пересоздаёт содержимое.
private struct ChatScreenContainer: View {
    @State private var model: ChatModel
    let groupTools: GroupTools?

    init(route: ChatRoute, makeChat: @MainActor (ChatRoute) -> ChatModel, groupTools: GroupTools?) {
        _model = State(initialValue: makeChat(route))
        self.groupTools = groupTools
    }

    var body: some View {
        ChatScreen(model: model, groupTools: model.kind == .group ? groupTools : nil)
    }
}

/// Действия в группе: список контактов для приглашения и отправка приглашения.
struct GroupTools {
    let contacts: @MainActor () -> [Contact]
    let invite: @MainActor (_ groupId: String, _ contact: Contact) async -> Bool
    /// Звонок в группу: участники группы вызываются все сразу.
    var startCall: (@MainActor (_ groupId: String, _ title: String, _ memberUserIds: [String]) async -> Void)?
    var canCall: @MainActor () -> Bool = { true }
    /// Идущий звонок группы для баннера и вход в него.
    var activeCall: (@MainActor (_ groupId: String) async -> GroupCallRecord?)?
    var joinCall: (@MainActor (_ record: GroupCallRecord, _ title: String) async -> Void)?
    var directory: UserDirectory?
}

private struct ChatRow: View {
    let chat: ChatSummary
    let unread: Int
    var status: UserStatus?

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: chat.title, status: status, size: 48, imageKey: chat.avatarKey)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let timestamp = chat.preview?.createdAtMilliseconds {
                        Text(ChatDates.listTime(Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)))
                            .font(.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                HStack {
                    Text(chat.preview?.summaryText ?? "")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    UnreadBadge(count: unread)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Форматы дат веб-клиента (ru-RU).
enum ChatDates {
    static let locale = Locale(identifier: "ru_RU")

    /// Список: сегодня — `HH:mm`, этот год — `d MMM`, иначе `dd.MM.yyyy`.
    static func listTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return messageTime(date) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        }
        return date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().locale(locale))
    }

    static func messageTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
    }

    /// Разделитель дня: «13 сентября».
    static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).locale(locale))
    }
}
