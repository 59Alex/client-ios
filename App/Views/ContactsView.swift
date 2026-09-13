import ConnectCalls
import ConnectCore
import ConnectFeatures
import SwiftUI

struct ContactsView: View {
    let model: ContactsModel
    let calls: P2PCallModel
    let myUsername: String
    let onOpenChat: (ChatRoute) -> Void

    @State private var profileContact: Contact?
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.canvas)
                .navigationTitle("Контакты")
                .searchable(text: Bindable(model).searchText, prompt: "Логин или телефон")
                .onSubmit(of: .search) { Task { await model.search() } }
        }
        .task { await model.load() }
        .sheet(item: $profileContact) { contact in
            ContactProfileSheet(contact: contact, model: model)
        }
        .alert("Не получилось", isPresented: .init(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel("Загрузка контактов")
        case let .failed(message):
            ContentUnavailableView {
                Label(message, systemImage: "wifi.exclamationmark")
            } actions: {
                Button("Повторить") { Task { await model.load() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 240)
            }
        case let .loaded(contacts):
            List {
                searchSection
                if contacts.isEmpty, model.searchText.isEmpty {
                    ContentUnavailableView("Контактов пока нет", systemImage: "person.2", description: Text("Найдите человека по логину или телефону"))
                        .listRowBackground(Color.clear)
                }
                ForEach(contacts) { contact in
                    ContactRow(contact: contact, isCallDisabled: calls.isInCall) {
                        Task { await calls.call(contact) }
                    }
                    .contextMenu { actions(for: contact) }
                    .listRowBackground(Palette.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
            .accessibilityIdentifier("contacts.list")
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        switch model.searchResult {
        case .idle:
            EmptyView()
        case .searching:
            HStack { Spacer(); ProgressView(); Spacer() }
                .listRowBackground(Color.clear)
        case .notFound:
            Text("Пользователь не найден")
                .foregroundStyle(Palette.textSecondary)
                .listRowBackground(Palette.surface)
                .accessibilityIdentifier("contacts.search.notFound")
        case let .failed(message):
            Text(message)
                .foregroundStyle(Palette.danger)
                .listRowBackground(Palette.surface)
        case let .found(contact):
            Section("Найден") {
                HStack(spacing: 12) {
                    Avatar(name: contact.displayName, status: contact.status, imageKey: contact.avatarKey)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName).font(.body.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                        Text(contact.handle).font(.subheadline).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    if model.isContact(contact) {
                        Text("В контактах").font(.subheadline).foregroundStyle(Palette.textSecondary)
                    } else {
                        Button("Добавить") {
                            Task {
                                if !(await model.add(contact)) { actionError = "Не удалось добавить контакт" }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("contacts.search.add")
                    }
                }
                .listRowBackground(Palette.surface)
            }
        }
    }

    @ViewBuilder
    private func actions(for contact: Contact) -> some View {
        Button("Написать", systemImage: "bubble.left") { openChat(with: contact) }
        Button("Позвонить", systemImage: "phone") { Task { await calls.call(contact) } }
            .disabled(calls.isInCall)
        Button("Профиль", systemImage: "person.crop.circle") { profileContact = contact }
        Button("Удалить из контактов", systemImage: "person.badge.minus", role: .destructive) {
            Task {
                if !(await model.remove(contact)) { actionError = "Не удалось удалить контакт" }
            }
        }
    }

    private func openChat(with contact: Contact) {
        Task {
            do {
                let roomId = try await model.chatRoomId(with: contact, myUsername: myUsername)
                onOpenChat(ChatRoute(kind: .p2p, roomId: roomId, title: contact.displayName))
            } catch {
                actionError = "Не удалось открыть чат"
            }
        }
    }
}

/// Профиль собеседника: фото, логин, блокировка переписки.
private struct ContactProfileSheet: View {
    let contact: Contact
    let model: ContactsModel

    @Environment(\.dismiss) private var dismiss
    @State private var profile: Contact?
    @State private var isBlocked: Bool?

    private var shown: Contact { profile ?? contact }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    let photos = shown.photoKeys
                    if photos.isEmpty {
                        Avatar(name: shown.displayName, size: 160)
                            .padding(.top, 24)
                    } else {
                        TabView {
                            ForEach(photos, id: \.self) { key in
                                RemoteImage(key: key) {
                                    ZStack { Palette.surface; ProgressView() }
                                }
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .accessibilityLabel("Фото профиля")
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
                    }

                    VStack(spacing: 4) {
                        Text(shown.displayName)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Text(shown.handle)
                            .foregroundStyle(Palette.textSecondary)
                        Text(PresenceText.describe(shown))
                            .font(.subheadline)
                            .foregroundStyle(shown.status == .online ? Palette.accent : Palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)

                    if let isBlocked {
                        Button(isBlocked ? "Разблокировать переписку" : "Заблокировать переписку", role: isBlocked ? nil : .destructive) {
                            Task {
                                if await model.setBlocked(!isBlocked, contact: contact) {
                                    self.isBlocked = !isBlocked
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("profile.block")
                    }
                }
                .padding(20)
            }
            .background(Palette.canvas)
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .task {
            async let loaded = model.profile(of: contact)
            async let blocked = model.isBlocked(contact)
            profile = await loaded
            isBlocked = await blocked
        }
    }
}

private struct ContactRow: View {
    let contact: Contact
    let isCallDisabled: Bool
    let onCall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: contact.displayName, status: contact.status, imageKey: contact.avatarKey)

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(PresenceText.describe(contact))
                    .font(.subheadline)
                    .foregroundStyle(contact.status == .online ? Palette.accent : Palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(action: onCall) {
                Image(systemName: "phone.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Palette.onAccent)
                    .background(Palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isCallDisabled)
            .opacity(isCallDisabled ? 0.45 : 1)
            .accessibilityLabel("Позвонить \(contact.displayName)")
            .accessibilityIdentifier("contacts.call.\(contact.username)")
        }
        .padding(.vertical, 4)
    }
}

struct Avatar: View {
    let name: String
    var status: UserStatus?
    var size: CGFloat = 44
    var imageKey: String?

    var body: some View {
        RemoteImage(key: imageKey) {
            Text(initials)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: size, height: size)
                .background(Palette.canvas)
        }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(Palette.border) }
            .overlay(alignment: .bottomTrailing) {
                if status == .online {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: size * 0.26, height: size * 0.26)
                        .overlay { Circle().strokeBorder(Palette.surface, lineWidth: 2) }
                }
            }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace).prefix(2)
        return words.compactMap { $0.first(where: \.isLetter).map(String.init) }.joined().uppercased()
    }
}

/// Подпись присутствия как в веб-клиенте (`features/contacts/presence.ts`).
enum PresenceText {
    static func describe(_ contact: Contact, now: Date = Date()) -> String {
        switch contact.status {
        case .online: return "в сети"
        case .hidden: return "скрыт"
        case .offline:
            guard let lastSeen = contact.lastSeenAt else { return "не в сети" }
            return "был(а) в сети " + relative(lastSeen, now: now)
        }
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDate(date, inSameDayAs: now) { return "в \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "вчера в \(time)"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))) + " в \(time)"
        }
        return date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().locale(Locale(identifier: "ru_RU")))
    }
}
