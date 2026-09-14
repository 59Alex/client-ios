import ConnectInbox
import SwiftUI

/// Тосты новых сообщений под верхней панелью: закрываются сами через 5 с, крестиком или свайпом вверх.
struct ToastStack: View {
    let model: ToastsModel
    let onOpen: (InboxNotification) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { toast in
                ToastCard(notification: toast, onOpen: { onOpen(toast) }, onClose: {
                    Task { await model.dismiss(toast.id) }
                })
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: ToastsModel.displayDuration)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.2)) { model.hide(toast.id) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(.easeOut(duration: 0.2), value: model.toasts.map(\.id))
    }
}

private struct ToastCard: View {
    let notification: InboxNotification
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var offset: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ToastsModel.title(notification))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(ToastsModel.text(notification))
                        .font(.subheadline)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toast.open.\(notification.id)")

            ShellIconButton(systemImage: "xmark", label: "Закрыть уведомление", identifier: "toast.close.\(notification.id)", action: onClose)
        }
        .padding(.leading, 14)
        .padding(.vertical, 6)
        .background(Palette.chrome, in: RoundedRectangle(cornerRadius: Radius.button))
        .overlay { RoundedRectangle(cornerRadius: Radius.button).strokeBorder(Palette.accent.opacity(0.6)) }
        .offset(y: min(0, offset))
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { offset = $0.translation.height }
                .onEnded { value in
                    if value.translation.height < -35 { onClose() } else { withAnimation { offset = 0 } }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toast.\(notification.id)")
    }
}
