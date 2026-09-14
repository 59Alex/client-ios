import SwiftUI

/// Свёрнутый звонок: плашка над приложением с именем и временем; нажатие разворачивает, кнопка завершает.
struct MinimizedCallBar: View {
    enum Phase: Equatable {
        case connecting
        case active(Date)
    }

    let title: String
    let phase: Phase
    let onExpand: () -> Void
    let onHangUp: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Button(action: onExpand) {
                    HStack(spacing: 10) {
                        Image(systemName: "phone.fill")
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 32, height: 32)
                            .background(Palette.success, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                            status
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up")
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Развернуть звонок: \(title)")
                .accessibilityIdentifier("call.minimized.expand")

                Button(action: onHangUp) {
                    Image(systemName: "phone.down.fill")
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Palette.danger, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Завершить звонок")
                .accessibilityIdentifier("call.minimized.hangup")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: Radius.panel))
            .overlay { RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Palette.success.opacity(0.6)) }
            .padding(.horizontal, 10)
            .padding(.top, 52)
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call.minimized")
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .connecting:
            Text("Соединение…").font(.caption).foregroundStyle(Palette.textSecondary)
        case let .active(startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(CallView.duration(from: startedAt, to: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.success)
            }
        }
    }
}

struct MinimizeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.headline)
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 44, height: 44)
                .background(Palette.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Свернуть звонок")
        .accessibilityIdentifier("call.minimize")
    }
}
