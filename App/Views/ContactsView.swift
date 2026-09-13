import ConnectCalls
import ConnectCore
import ConnectFeatures
import SwiftUI

struct ContactsView: View {
    let model: ContactsModel
    let calls: P2PCallModel

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.canvas)
                .navigationTitle("Контакты")
        }
        .task { await model.load() }
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
        case let .loaded(contacts) where contacts.isEmpty:
            ContentUnavailableView("Контактов пока нет", systemImage: "person.2", description: Text("Добавьте контакты в веб-версии"))
        case let .loaded(contacts):
            List(contacts) { contact in
                ContactRow(contact: contact, isCallDisabled: calls.isInCall) {
                    Task { await calls.call(contact) }
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
            .accessibilityIdentifier("contacts.list")
        }
    }
}

private struct ContactRow: View {
    let contact: Contact
    let isCallDisabled: Bool
    let onCall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: contact.displayName, status: contact.status)

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

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Palette.textPrimary)
            .frame(width: size, height: size)
            .background(Palette.canvas, in: Circle())
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
