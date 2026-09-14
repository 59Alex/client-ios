import ConnectCalls
import ConnectCore
import ConnectFeatures
import ConnectRooms
import SwiftUI

/// Левый рейл веб-клиента (`main-panel`): логотип темы ведёт на главную, ниже комнаты и «+».
struct RoomRail: View {
    let rooms: [RoomCard]
    let selectedRoomId: String?
    let unreadCount: (RoomCard) -> Int
    let onHome: () -> Void
    let onRoom: (RoomCard) -> Void
    let onAdd: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                Button(action: onHome) {
                    Image(AppTheme.logoName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())
                        .overlay { Circle().strokeBorder(selectedRoomId == nil ? Palette.accent : Palette.border, lineWidth: 2) }
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Главная")
                .accessibilityAddTraits(selectedRoomId == nil ? .isSelected : [])
                .accessibilityIdentifier("rail.home")

                ForEach(rooms) { room in
                    RailRoomButton(room: room, isSelected: room.id == selectedRoomId, unread: unreadCount(room)) {
                        onRoom(room)
                    }
                }

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 48, height: 48)
                        .overlay {
                            RoundedRectangle(cornerRadius: 17)
                                .strokeBorder(Palette.textSecondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 17))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Создать комнату")
                .accessibilityIdentifier("rail.add")
            }
            .padding(.vertical, 10)
            .frame(width: 58)
        }
        .frame(width: 58)
        .background(Palette.chrome.ignoresSafeArea(edges: [.bottom, .leading]))
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.divider).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Комнаты")
    }
}

private struct RailRoomButton: View {
    let room: RoomCard
    let isSelected: Bool
    let unread: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RemoteImage(key: room.avatarKey) {
                Text(String(room.name.first(where: \.isLetter) ?? "#").uppercased())
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 48, height: 48)
                    .background(Palette.canvas)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: isSelected ? 14 : 17))
            .overlay {
                RoundedRectangle(cornerRadius: isSelected ? 14 : 17)
                    .strokeBorder(isSelected ? Palette.info : .clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if unread > 0 {
                    CountBadge(count: unread).offset(x: 6, y: -6)
                }
            }
            .animation(.easeOut(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unread > 0 ? "\(room.name), непрочитанных: \(unread)" : room.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("rail.room.\(room.id)")
    }
}

/// Красный счётчик непрочитанного, как в списках и на колокольчике веба.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Palette.danger, in: Capsule())
            .accessibilityHidden(true)
    }
}

/// Верхняя панель: меню скрывает рейл, справа приглашения и уведомления.
struct HomeTopBar: View {
    let isRailShown: Bool
    let invitations: Int
    let notifications: Int
    var errorTone: ConnectionErrorsModel.Tone = .none
    var onErrors: () -> Void = {}
    let onMenu: () -> Void
    let onInvitations: () -> Void
    let onNotifications: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ShellIconButton(systemImage: "line.3.horizontal", label: isRailShown ? "Скрыть комнаты" : "Показать комнаты", identifier: "home.menu", action: onMenu)
            Spacer()
            if errorTone != .none {
                ShellIconButton(
                    systemImage: errorTone == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                    label: errorTone == .error ? "Ошибки подключения" : "Подключение восстановлено",
                    identifier: "connection.errors",
                    tint: errorTone == .error ? Palette.danger : Palette.success,
                    action: onErrors
                )
            }
            ShellIconButton(systemImage: "person.badge.plus", label: invitations > 0 ? "Приглашения: \(invitations)" : "Приглашения", identifier: "inbox.invitations", badge: invitations, action: onInvitations)
            ShellIconButton(systemImage: "bell", label: notifications > 0 ? "Уведомления, новых: \(notifications)" : "Уведомления", identifier: "inbox.open", badge: notifications, action: onNotifications)
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(Palette.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.divider).frame(height: 1) }
    }
}

struct ShellIconButton: View {
    let systemImage: String
    let label: String
    let identifier: String
    var badge = 0
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(tint ?? Palette.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if badge > 0 { CountBadge(count: badge).offset(x: -2, y: 2) }
                }
        }
        .buttonStyle(PressHighlightStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// Нажатие подсвечивает фон цветом нажатия темы (`--appearance-press`).
struct PressHighlightStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.press : .clear, in: RoundedRectangle(cornerRadius: 10))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Нижние вкладки главной (`home-sidebar`): активная на подложке с акцентной чертой снизу.
struct HomeTabBar: View {
    struct Item: Identifiable {
        let tab: AppNavigation.Tab
        let title: String
        let systemImage: String
        let identifier: String
        let badge: Int
        var id: String { identifier }
    }

    let items: [Item]
    @Binding var selection: AppNavigation.Tab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let active = selection == item.tab
                Button {
                    selection = item.tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 19))
                            .overlay(alignment: .topTrailing) {
                                if item.badge > 0 { CountBadge(count: item.badge).offset(x: 14, y: -8) }
                            }
                        Text(item.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(active ? Palette.textPrimary : Palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(active ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottom) {
                        if active {
                            Capsule().fill(Palette.accent).frame(height: 3).padding(.horizontal, 6)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.badge > 0 ? "\(item.title), непрочитанных: \(item.badge)" : item.title)
                .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier(item.identifier)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Palette.canvas.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Palette.divider).frame(height: 1) }
    }
}

/// Панель пользователя над вкладками: аватар со статусом, голосовой канал и управление звуком.
struct UserPanel: View {
    let user: User
    let avatarKey: String?
    let voice: RoomVoiceModel
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(name: user.name, size: 40, imageKey: avatarKey)
                    .overlay { Circle().strokeBorder(statusColor, lineWidth: 2.5).padding(-4) }
                    .padding(4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(user.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(user.username)
                        .font(.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle().fill(connectionColor).frame(width: 7, height: 7)
                    Text(connectionText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                .padding(.top, 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("voice.status")
            }

            let inVoice = voice.isInCall
            let muted = voice.session?.isMuted ?? false
            let speakerOff = voice.session?.isSpeakerOff ?? false
            HStack(spacing: 4) {
                Spacer()
                ShellIconButton(systemImage: "gearshape", label: "Настройки", identifier: "profile.open", action: onSettings)
                if inVoice {
                    ShellIconButton(systemImage: voice.camera.isActive ? "video.fill" : "video", label: voice.camera.isActive ? "Выключить камеру" : "Включить камеру", identifier: "voice.camera", tint: voice.camera.isActive ? Palette.accent : nil) {
                        Task {
                            if voice.camera.isActive || (await CameraPermission.request()) { await voice.toggleCamera() }
                        }
                    }
                }
                ShellIconButton(systemImage: muted ? "mic.slash" : "mic", label: muted ? "Включить микрофон" : "Выключить микрофон", identifier: "voice.mute", tint: muted ? Palette.danger : nil) {
                    Task { await voice.toggleMute() }
                }
                .disabled(!inVoice)
                ShellIconButton(systemImage: speakerOff ? "speaker.slash" : "speaker.wave.2", label: speakerOff ? "Включить звук" : "Выключить звук", identifier: "voice.speaker", tint: speakerOff ? Palette.danger : nil) {
                    Task { await voice.toggleSpeakerOff() }
                }
                .disabled(!inVoice)
                ShellIconButton(systemImage: inVoice ? "phone.down" : "phone", label: "Выйти из канала", identifier: "voice.leave", tint: inVoice ? Palette.danger : nil) {
                    Task { await voice.leave() }
                }
                .disabled(!inVoice)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.button))
        .overlay { RoundedRectangle(cornerRadius: Radius.button).strokeBorder(Palette.divider) }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("user.panel")
    }

    private var statusColor: Color {
        switch user.status {
        case .online: Palette.success
        case .hidden: Palette.accent
        case .offline: Palette.textSecondary
        }
    }

    private var connectionText: String {
        switch voice.phase {
        case .idle: "Нет подключения"
        case .connecting: "Подключение…"
        case .active: voice.channelName.isEmpty ? "В голосовом канале" : voice.channelName
        case .failed: "Ошибка подключения"
        }
    }

    private var connectionColor: Color {
        switch voice.phase {
        case .idle: Palette.textSecondary
        case .connecting: Palette.accent
        case .active: Palette.success
        case .failed: Palette.danger
        }
    }
}

/// Кнопка «+ Создать» над панелью пользователя (группы и каналы веб-клиента).
struct CreateButton: View {
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Создать", systemImage: "plus")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.button))
                .overlay { RoundedRectangle(cornerRadius: Radius.button).strokeBorder(Palette.divider) }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
