import ConnectChat
import SwiftUI

/// Вкладка «Чаты» или «Группы»: список с превью, временем и непрочитанными.
struct ChatListView: View {
    let model: ChatListModel
    let unread: UnreadModel
    let makeChat: @MainActor (ChatRoute) -> ChatModel
    @Binding var path: [ChatRoute]

    private var title: String { model.kind == .p2p ? "Чаты" : "Группы" }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.canvas)
                .navigationTitle(title)
                .navigationDestination(for: ChatRoute.self) { route in
                    ChatScreenContainer(route: route, makeChat: makeChat)
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
                    ChatRow(chat: chat, unread: unread.unreadCount(kind: chat.kind, roomId: chat.roomId))
                }
                .listRowBackground(Palette.surface)
                .accessibilityIdentifier("chats.row.\(chat.roomId)")
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }
}

/// Адрес открытого чата в навигации.
struct ChatRoute: Hashable {
    let kind: ChatKind
    let roomId: String
    let title: String
}

/// Держит модель чата, пока экран в стеке: `navigationDestination` пересоздаёт содержимое.
private struct ChatScreenContainer: View {
    @State private var model: ChatModel

    init(route: ChatRoute, makeChat: @MainActor (ChatRoute) -> ChatModel) {
        _model = State(initialValue: makeChat(route))
    }

    var body: some View {
        ChatScreen(model: model)
    }
}

private struct ChatRow: View {
    let chat: ChatSummary
    let unread: Int

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: chat.title)

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
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Palette.onAccent)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(Palette.accent, in: Capsule())
                            .accessibilityLabel("Непрочитанных: \(unread)")
                    }
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
