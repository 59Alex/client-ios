import SwiftUI

/// Роли цветов из палитр `light`/`dark` веб-клиента (`connect-ui/src/components/func/Theme.ts`).
/// Значения лежат в Assets.xcassets с вариантами для светлой и тёмной темы.
enum Palette {
    static let canvas = Color("Canvas")
    static let surface = Color("Surface")
    static let textPrimary = Color("TextPrimary")
    static let textSecondary = Color("TextSecondary")
    static let accent = Color("Accent")
    static let onAccent = Color("OnAccent")
    static let danger = Color("Danger")
    static let border = Color("TextSecondary").opacity(0.35)
}

/// Радиусы веб-клиента: кнопка 12, панель 16, модальное окно 24.
enum Radius {
    static let button: CGFloat = 12
    static let panel: CGFloat = 16
    static let modal: CGFloat = 24
}
