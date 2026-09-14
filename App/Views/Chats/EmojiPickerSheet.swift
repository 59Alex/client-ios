import ConnectChat
import SwiftUI

/// Смайлики (`ChatEmojiPicker.tsx`): поиск, настроения и сетка; выбор добавляет символ в поле ввода.
struct EmojiPickerSheet: View {
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var categoryId: String?

    private var category: EmojiCategory? {
        categoryId.flatMap { id in EmojiCatalog.categories.first { $0.id == id } }
    }

    private let columns = [GridItem(.adaptive(minimum: 48), spacing: 6)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
                    TextField("Найти смайлик", text: $query)
                        .foregroundStyle(Palette.textPrimary)
                        .accessibilityIdentifier("emoji.search")
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Palette.chrome, in: RoundedRectangle(cornerRadius: Radius.button))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip(id: nil, title: "Все")
                        ForEach(EmojiCatalog.categories) { category in
                            chip(id: category.id, title: "\(category.icon) \(category.label)")
                        }
                    }
                }

                ScrollView {
                    let emojis = EmojiCatalog.filter(query: query, category: category)
                    if emojis.isEmpty {
                        Text("Ничего не найдено")
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.top, 24)
                    }
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(emojis) { emoji in
                            Button {
                                onSelect(emoji.symbol)
                            } label: {
                                Text(emoji.symbol)
                                    .font(.system(size: 30))
                                    .frame(width: 48, height: 48)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressHighlightStyle())
                            .accessibilityLabel(emoji.label)
                            .accessibilityIdentifier("emoji.\(emoji.symbol)")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .background(Palette.canvas)
            .navigationTitle("Смайлики")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .accessibilityIdentifier("emoji.done")
                }
            }
        }
    }

    private func chip(id: String?, title: String) -> some View {
        let active = categoryId == id
        return Button {
            categoryId = id
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(active ? Palette.textPrimary : Palette.textSecondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(active ? Palette.selected : Palette.chrome, in: Capsule())
                .overlay { if active { Capsule().strokeBorder(Palette.accent) } }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
