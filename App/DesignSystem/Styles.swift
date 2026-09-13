import SwiftUI

/// Основная кнопка: однотонная заливка акцентом, без теней и градиентов.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(Palette.onAccent)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: Radius.button))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Radius.button))
    }
}

/// Поле ввода на поднятой поверхности с тонкой границей; фокус выделяется акцентной рамкой.
struct ConnectFieldModifier: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .foregroundStyle(Palette.textPrimary)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: Radius.button))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.button)
                    .strokeBorder(isFocused ? Palette.accent : Palette.border, lineWidth: isFocused ? 2 : 1)
            }
    }
}

extension View {
    func connectField(isFocused: Bool) -> some View {
        modifier(ConnectFieldModifier(isFocused: isFocused))
    }
}
