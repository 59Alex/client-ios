import ConnectChat
import ConnectCore
import ConnectInbox
import SwiftUI

/// Уведомления и приглашения в одном листе (колокольчик и приглашения веб-клиента).
struct InboxView: View {
    enum Section: Hashable {
        case notifications
        case invitations
    }

    let notifications: NotificationCenterModel
    let invitations: InvitationsModel
    let onOpenChat: (ChatRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .notifications

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Раздел", selection: $section) {
                    Text("Уведомления").tag(Section.notifications)
                    Text(invitations.pendingCount > 0 ? "Приглашения · \(invitations.pendingCount)" : "Приглашения").tag(Section.invitations)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("inbox.section")

                switch section {
                case .notifications: notificationList
                case .invitations: invitationList
                }
            }
            .background(Palette.canvas)
            .navigationTitle(section == .notifications ? "Уведомления" : "Приглашения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                if section == .notifications, !notifications.items.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Очистить") { Task { await notifications.dismissAll() } }
                            .accessibilityIdentifier("inbox.dismissAll")
                    }
                }
            }
        }
        .task { await notifications.load() }
        .task { await invitations.load() }
    }

    @ViewBuilder
    private var notificationList: some View {
        if notifications.items.isEmpty {
            ContentUnavailableView(
                notifications.isLoading ? "Загрузка" : "Уведомлений нет",
                systemImage: "bell",
                description: Text(notifications.failed ? "Не удалось загрузить уведомления" : "Новые сообщения появятся здесь")
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(notifications.items) { item in
                    Button { open(item) } label: {
                        NotificationRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("inbox.notification.\(item.id)")
                    .onAppear { Task { await notifications.markViewed([item.id]) } }
                    .swipeActions {
                        Button("Скрыть", role: .destructive) { Task { await notifications.dismiss(item.id) } }
                    }
                }
                if notifications.hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await notifications.loadMore() }
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await notifications.load() }
        }
    }

    @ViewBuilder
    private var invitationList: some View {
        if invitations.invitations.isEmpty {
            ContentUnavailableView("Приглашений нет", systemImage: "envelope", description: Text("Приглашения в группы и комнаты появятся здесь"))
                .frame(maxHeight: .infinity)
        } else {
            List {
                if let message = invitations.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .listRowBackground(Color.clear)
                }
                if !invitations.incoming.isEmpty {
                    SwiftUI.Section("Входящие") {
                        ForEach(invitations.incoming) { invitation in
                            InvitationRow(invitation: invitation, title: invitations.title(of: invitation), counterpart: "От: \(invitation.senderName)", isProcessing: invitations.processingIds.contains(invitation.id)) {
                                if invitation.status == .pending {
                                    Button("Принять") { Task { await accept(invitation) } }
                                        .buttonStyle(.borderedProminent)
                                        .accessibilityIdentifier("inbox.accept.\(invitation.id)")
                                    Button("Отклонить") { Task { await invitations.decide(invitation, action: .decline) } }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .listRowBackground(Palette.surface)
                        }
                    }
                }
                if !invitations.outgoing.isEmpty {
                    SwiftUI.Section("Исходящие") {
                        ForEach(invitations.outgoing) { invitation in
                            InvitationRow(invitation: invitation, title: invitations.title(of: invitation), counterpart: "Кому: \(invitation.recipientName)", isProcessing: invitations.processingIds.contains(invitation.id)) {
                                if invitation.status == .pending {
                                    Button("Отменить") { Task { await invitations.decide(invitation, action: .cancel) } }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .listRowBackground(Palette.surface)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await invitations.load() }
        }
    }

    private func open(_ item: InboxNotification) {
        Task { await notifications.dismiss(item.id) }
        guard let chatId = item.chatId else { return }
        switch item.chatType {
        case .p2p:
            dismiss()
            onOpenChat(ChatRoute(kind: .p2p, roomId: chatId, title: "Личный чат"))
        case .group:
            dismiss()
            onOpenChat(ChatRoute(kind: .group, roomId: chatId, title: "Группа"))
        default:
            // Комнаты, каналы и события комнат переносятся следующими этапами.
            break
        }
    }

    private func accept(_ invitation: Invitation) async {
        guard let accepted = await invitations.decide(invitation, action: .accept) else { return }
        if accepted.kind == .group, let groupId = accepted.targetId {
            dismiss()
            onOpenChat(ChatRoute(kind: .group, roomId: groupId, title: accepted.targetName))
        }
    }
}

private struct NotificationRow: View {
    let item: InboxNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(item.viewedAt == nil ? Palette.accent : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(item.bodyText)
                    .font(.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(3)
                if let createdAt = item.createdAt {
                    Text(ChatDates.listTime(createdAt))
                        .font(.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct InvitationRow<Actions: View>: View {
    let invitation: Invitation
    let title: String
    let counterpart: String
    let isProcessing: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
            Text(invitation.subtitle)
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
            HStack {
                Text(counterpart)
                if let createdAt = invitation.createdAt {
                    Text("· \(ChatDates.listTime(createdAt))")
                }
                Spacer()
                Text(invitation.status.title)
                    .foregroundStyle(invitation.status == .accepted ? Palette.accent : Palette.textSecondary)
            }
            .font(.caption)
            .foregroundStyle(Palette.textSecondary)
            HStack(spacing: 8) {
                if isProcessing {
                    ProgressView()
                } else {
                    actions()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Создание группы: название, участники из контактов, встречи по ссылке.
struct CreateGroupSheet: View {
    @State var model: CreateGroupModel
    let contacts: [Contact]
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    TextField("Название", text: $model.name)
                        .accessibilityIdentifier("group.name")
                    Toggle("Разрешить встречи по ссылке", isOn: $model.meetingsAllowed)
                }
                SwiftUI.Section {
                    if contacts.isEmpty {
                        Text("Контактов пока нет").foregroundStyle(Palette.textSecondary)
                    }
                    ForEach(contacts) { contact in
                        Button { model.toggle(contact.userId) } label: {
                            HStack(spacing: 12) {
                                Avatar(name: contact.displayName, imageKey: contact.avatarKey)
                                VStack(alignment: .leading) {
                                    Text(contact.displayName).foregroundStyle(Palette.textPrimary)
                                    Text(contact.handle).font(.caption).foregroundStyle(Palette.textSecondary)
                                }
                                Spacer()
                                Image(systemName: model.selectedUserIds.contains(contact.userId) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.selectedUserIds.contains(contact.userId) ? Palette.accent : Palette.textSecondary)
                            }
                        }
                        .accessibilityIdentifier("group.member.\(contact.username)")
                        .accessibilityAddTraits(model.selectedUserIds.contains(contact.userId) ? .isSelected : [])
                    }
                } header: {
                    Text("Участники")
                } footer: {
                    Text("Участников можно добавить сейчас или позже приглашением")
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(Palette.danger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Новая группа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        Task {
                            if await model.submit() {
                                onCreated()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("group.create")
                }
            }
        }
    }
}

/// Участники группы и приглашение контактов (`InviteContacts.tsx`).
struct GroupMembersSheet: View {
    let members: [Contact]
    let contacts: [Contact]
    let invite: (Contact) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var sent: Set<String> = []
    @State private var failed: Set<String> = []

    private var candidates: [Contact] {
        let memberIds = Set(members.map(\.userId))
        return contacts.filter { !memberIds.contains($0.userId) }
    }

    var body: some View {
        NavigationStack {
            List {
                SwiftUI.Section("Участники · \(members.count)") {
                    ForEach(members) { member in
                        HStack(spacing: 12) {
                            Avatar(name: member.displayName, status: member.status, imageKey: member.avatarKey)
                            VStack(alignment: .leading) {
                                Text(member.displayName).foregroundStyle(Palette.textPrimary)
                                Text(member.handle).font(.caption).foregroundStyle(Palette.textSecondary)
                            }
                        }
                    }
                }
                SwiftUI.Section("Пригласить из контактов") {
                    if candidates.isEmpty {
                        Text("Все контакты уже в группе").foregroundStyle(Palette.textSecondary)
                    }
                    ForEach(candidates) { contact in
                        HStack(spacing: 12) {
                            Avatar(name: contact.displayName, imageKey: contact.avatarKey)
                            Text(contact.displayName).foregroundStyle(Palette.textPrimary)
                            Spacer()
                            if sent.contains(contact.userId) {
                                Text("Отправлено").font(.subheadline).foregroundStyle(Palette.textSecondary)
                            } else {
                                Button("Пригласить") {
                                    Task {
                                        if await invite(contact) {
                                            sent.insert(contact.userId)
                                            failed.remove(contact.userId)
                                        } else {
                                            failed.insert(contact.userId)
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("group.invite.\(contact.username)")
                            }
                        }
                    }
                    if !failed.isEmpty {
                        Text("Не удалось отправить приглашение. Проверьте права и соединение.")
                            .font(.footnote)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Группа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
