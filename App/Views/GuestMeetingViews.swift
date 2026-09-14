import ConnectCalls
import SwiftUI

/// Вход во встречу гостем: ссылка и имя (`MeetingEntry.tsx`).
struct GuestJoinSheet: View {
    let model: GuestMeetingModel

    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var name = ""
    @State private var error: String?
    @State private var isJoining = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ссылка на встречу", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("guest.link")
                    TextField("Как вас называть", text: $name)
                        .textContentType(.name)
                        .accessibilityIdentifier("guest.name")
                } footer: {
                    Text("Встреча идёт по ссылке, которую прислал участник группы. Аккаунт не нужен.")
                }
                .listRowBackground(Palette.surface)
                if let error {
                    Text(error)
                        .foregroundStyle(Palette.danger)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("guest.error")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Встреча")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Войти") {
                        isJoining = true
                        Task {
                            error = await model.join(link: link, displayName: name)
                            isJoining = false
                            if error == nil { dismiss() }
                        }
                    }
                    .disabled(isJoining || link.isEmpty || name.isEmpty)
                    .accessibilityIdentifier("guest.join")
                }
            }
            .onAppear {
                if link.isEmpty, let pasted = UIPasteboard.general.string, MeetingLinks.code(from: pasted) != nil {
                    link = pasted
                }
            }
        }
    }
}

/// Гость на встрече: участники звонка, микрофон, чат встречи и выход.
struct GuestMeetingView: View {
    let model: GuestMeetingModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(model.title.isEmpty ? "Встреча" : model.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityIdentifier("guest.title")
                statusText
            }
            .padding(.top, 24)
            .padding(.bottom, 12)

            switch model.phase {
            case let .ended(message):
                Spacer()
                Label(message, systemImage: "phone.down")
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityIdentifier("guest.ended")
                Spacer()
                Button("Закрыть") { Task { await model.leave() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(24)
                    .accessibilityIdentifier("guest.close")
            default:
                if let session = model.session, !session.shares.items.isEmpty {
                    ShareStage(shares: session.shares.items) { session.videoTrack(for: $0) }
                        .padding(.horizontal, 12)
                }
                participants
                chat
                controls
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas.ignoresSafeArea())
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.phase {
        case .joining: Text("Подключение…").font(.subheadline).foregroundStyle(Palette.textSecondary)
        case .active: Text("Вы гость встречи").font(.subheadline).foregroundStyle(Palette.success)
        default: EmptyView()
        }
    }

    private var participants: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(model.session?.participants ?? []) { participant in
                    VStack(spacing: 4) {
                        Avatar(name: participant.username ?? "Участник", size: 48)
                            .overlay { if participant.isSpeaking { Circle().strokeBorder(Palette.success, lineWidth: 3).padding(-3) } }
                        Text(participant.username ?? "Участник")
                            .font(.caption)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        if participant.isMuted {
                            Image(systemName: "mic.slash").font(.caption2).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .frame(width: 72)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 96)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.messages) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.displayName ?? "Участник")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(message.guestId == model.guestId ? Palette.ownMessageName : Palette.messageName)
                            Text(message.message)
                                .foregroundStyle(message.guestId == model.guestId ? Palette.onOwnBubble : Palette.onOtherBubble)
                        }
                        .padding(10)
                        .background(message.guestId == model.guestId ? Palette.ownBubble : Palette.otherBubble, in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity, alignment: message.guestId == model.guestId ? .trailing : .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .background(Palette.chat)
            .accessibilityIdentifier("guest.chat")

            HStack(spacing: 8) {
                TextField("Сообщение", text: Bindable(model).draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Palette.chrome, in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityIdentifier("guest.input")
                Button { Task { await model.send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(Palette.onAccent)
                        .background(Palette.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Отправить")
                .accessibilityIdentifier("guest.send")
            }
            .padding(10)
            .background(Palette.surface)
        }
    }

    private var controls: some View {
        let muted = model.session?.isMuted ?? false
        return HStack(spacing: 32) {
            RoundControl(title: muted ? "Включить микрофон" : "Выключить микрофон", systemImage: muted ? "mic.slash.fill" : "mic.fill", fill: muted ? Palette.textPrimary : Palette.surface, foreground: muted ? Palette.canvas : Palette.textPrimary, identifier: "guest.mute") {
                Task { await model.toggleMute() }
            }
            RoundControl(title: "Выйти из встречи", systemImage: "phone.down.fill", fill: Palette.danger, identifier: "guest.leave") {
                Task { await model.leave() }
            }
        }
        .padding(.vertical, 16)
    }
}
