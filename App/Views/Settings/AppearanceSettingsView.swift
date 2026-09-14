import ConnectSettings
import SwiftUI
import UIKit

/// Строка настроек веб-клиента (`SettingsLayout`): иконка и подпись.
struct SettingsRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(Palette.textPrimary)
        }
        .frame(minHeight: 36)
    }
}

struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .kerning(0.8)
            .foregroundStyle(Palette.textSecondary)
    }
}

/// «Оформление» (`AppearanceSection.tsx`): тема, цвета подсветки и нажатия, меньше анимации, предпросмотр.
struct AppearanceSettingsView: View {
    let model: AppearanceModel

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ВАШ CONNECT")
                        .font(.caption.weight(.bold))
                        .kerning(0.8)
                        .foregroundStyle(Palette.accent)
                    Text("Сделайте его своим")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Palette.textPrimary)
                    Text("Тема, любимые цвета и немного настроения. Изменения применяются и сохраняются автоматически на всех устройствах.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                }

                if model.state == .error {
                    HStack(alignment: .top, spacing: 12) {
                        Text("Не удалось синхронизировать оформление. Последние изменения сохранены на этом устройстве — повторите отправку.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.textPrimary)
                        Button("Повторить") { Task { await model.flush() } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("appearance.retry")
                    }
                    .padding(12)
                    .background(Palette.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.button))
                    .accessibilityElement(children: .contain)
                }

                group("Тема интерфейса") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(AppearanceTheme.allCases) { theme in
                            ThemeCard(theme: theme, isSelected: model.draft.theme == theme) {
                                model.selectTheme(theme)
                            }
                        }
                    }
                    Text("Выбор темы устанавливает её палитру. Затем можно изменить отдельные цвета.")
                        .font(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }

                group("Цвета") {
                    colorRow("Цвет подсветки", value: model.colors.accent, identifier: "appearance.accent") { hex in
                        var next = model.draft
                        next.accentColor = hex
                        model.change(next)
                    }
                    colorRow("Цвет нажатия", value: model.colors.press, identifier: "appearance.press") { hex in
                        var next = model.draft
                        next.pressColor = hex
                        model.change(next)
                    }
                }

                group("Фон чата · Телефон") {
                    BackgroundGallery(model: model, backgrounds: AppTheme.backgrounds)
                }

                Toggle(isOn: Binding(get: { model.draft.reducedMotion }, set: { value in
                    var next = model.draft
                    next.reducedMotion = value
                    model.change(next)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Меньше анимации").foregroundStyle(Palette.textPrimary)
                        Text("Системное предпочтение тоже учитывается.").font(.footnote).foregroundStyle(Palette.textSecondary)
                    }
                }
                .tint(Palette.accent)
                .accessibilityIdentifier("appearance.reducedMotion")

                group("Предпросмотр") {
                    AppearancePreview()
                }

                HStack {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityIdentifier("appearance.status")
                    Spacer()
                    Button("По умолчанию") { model.reset() }
                        .buttonStyle(.bordered)
                        .disabled(model.state == .loading)
                        .accessibilityIdentifier("appearance.reset")
                }
            }
            .padding(16)
        }
        .background(Palette.chrome)
        .navigationTitle("Оформление")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusText: String {
        switch model.state {
        case .loading: "Загрузка оформления…"
        case .saving: "Сохраняем…"
        case .ready: "Все изменения сохранены"
        case .error: "Изменения не отправлены"
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(title: title)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func colorRow(_ title: String, value: String, identifier: String, onChange: @escaping (String) -> Void) -> some View {
        ColorPicker(selection: Binding(get: { Color(themeHex: value) }, set: { color in
            if let hex = color.hexString { onChange(hex) }
        }), supportsOpacity: false) {
            HStack {
                Text(title).foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(value.uppercased())
                    .font(.footnote.monospaced())
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: Radius.button))
        .accessibilityIdentifier(identifier)
    }
}

/// Фоны галереи темы из connect-s3 и однотонный вариант (`appearance-patterns`).
private struct BackgroundGallery: View {
    let model: AppearanceModel
    let backgrounds: ChatBackgroundsModel

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        let selected = backgrounds.background(for: model.draft)?.id ?? "plain"
        LazyVGrid(columns: columns, spacing: 10) {
            tile(id: "plain", title: "Однотонный", isSelected: selected == "plain") {
                Palette.chat
            }
            ForEach(backgrounds.gallery(for: model.draft.theme)) { background in
                tile(id: background.id, title: background.name, isSelected: selected == background.id) {
                    BackgroundThumbnail(url: backgrounds.imageURL(for: background), focus: background.focus)
                }
            }
        }
        if backgrounds.failed {
            Button("Не удалось загрузить фоны. Повторить") { Task { await backgrounds.load() } }
                .font(.footnote)
                .accessibilityIdentifier("appearance.backgrounds.retry")
        }
    }

    private func tile<Preview: View>(id: String, title: String, isSelected: Bool, @ViewBuilder preview: () -> Preview) -> some View {
        Button {
            model.selectBackground(id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                preview()
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isSelected ? Palette.accent : Palette.divider, lineWidth: isSelected ? 3 : 1)
                    }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Фон \(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("appearance.background.\(id)")
    }
}

private struct BackgroundThumbnail: View {
    let url: URL?
    let focus: (x: Double, y: Double)

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Palette.chat
                if let image {
                    let frame = ChatBackdrop.cover(image.size, in: proxy.size, focus: focus)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: url) {
            guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            image = UIImage(data: data)
        }
    }
}

/// Карточка темы: мини-макет рейла, списка и чата в цветах самой темы.
private struct ThemeCard: View {
    let theme: AppearanceTheme
    let isSelected: Bool
    let action: () -> Void

    private var colors: ThemeColors { ThemeColors(AppearancePreferences.standard.selecting(theme)) }

    var body: some View {
        let colors = colors
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 3) {
                    VStack(spacing: 4) {
                        Circle().fill(Color(themeHex: colors.accent)).frame(width: 12, height: 12)
                        RoundedRectangle(cornerRadius: 3).fill(Color(themeHex: colors.currentLine)).frame(width: 12, height: 12)
                        Spacer()
                    }
                    .padding(4)
                    .background(Color(themeHex: colors.editorBackground))
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(themeHex: colors.text).opacity(0.8)).frame(width: 36, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(Color(themeHex: colors.comment).opacity(0.7)).frame(width: 26, height: 4)
                        Spacer()
                        HStack {
                            Spacer()
                            RoundedRectangle(cornerRadius: 4).fill(Color(themeHex: colors.own)).frame(width: 30, height: 10)
                        }
                        RoundedRectangle(cornerRadius: 4).fill(Color(themeHex: colors.other)).frame(width: 34, height: 10)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(themeHex: colors.currentLine))
                }
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(themeHex: colors.text).opacity(0.12)) }

                Text(theme.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(isSelected ? "Выбрана" : "Выбрать")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
            }
            .padding(8)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: Radius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.panel)
                    .strokeBorder(isSelected ? Palette.accent : Palette.divider, lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.panel))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Тема \(theme.title)")
        .accessibilityValue(isSelected ? "Выбрана" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("appearance.theme.\(theme.rawValue)")
    }
}

/// Пример переписки в текущих цветах (`appearance-preview`).
private struct AppearancePreview: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(AppTheme.logoName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Избранное").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                    Text("Пример оформления").font(.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Palette.chrome)

            VStack(spacing: 8) {
                Text("Сегодня")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Palette.surface.opacity(0.8), in: Capsule())
                PreviewBubble(author: "Алекс", text: "На связи. Как тебе новый Connect?", time: "12:40", isOwn: false)
                PreviewBubble(author: "Вы", text: "Теперь всё в моём стиле.", time: "12:41 · Прочитано", isOwn: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background { ChatBackdrop() }

            HStack {
                Text("Написать сообщение…").foregroundStyle(Palette.textSecondary)
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(Palette.accent)
            }
            .font(.subheadline)
            .padding(12)
            .background(Palette.chrome)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
        .overlay { RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Palette.divider) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Предпросмотр чата")
    }
}

private struct PreviewBubble: View {
    let author: String
    let text: String
    let time: String
    let isOwn: Bool

    var body: some View {
        HStack {
            if isOwn { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 3) {
                Text(author).font(.caption.weight(.semibold)).foregroundStyle(isOwn ? Palette.ownMessageName : Palette.messageName)
                Text(text).font(.subheadline).foregroundStyle(isOwn ? Palette.onOwnBubble : Palette.onOtherBubble)
                Text(time).font(.caption2).foregroundStyle((isOwn ? Palette.onOwnBubble : Palette.onOtherBubble).opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isOwn ? Palette.ownBubble : Palette.otherBubble, in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3, bottomTrailingRadius: 10, topTrailingRadius: 10))
            if !isOwn { Spacer(minLength: 40) }
        }
    }
}

extension Color {
    /// `#RRGGBB` в sRGB для сохранения цвета из системной палитры.
    var hexString: String? {
        guard let components = UIColor(self).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              components.count >= 3 else { return nil }
        return HexColor.make(Int((components[0] * 255).rounded()), Int((components[1] * 255).rounded()), Int((components[2] * 255).rounded()))
    }
}
