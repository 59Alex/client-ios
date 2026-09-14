import Foundation

/// Эмодзи веб-клиента (`emojiCatalog.ts`, `ChatEmojiPicker.tsx`): каталог, настроения и поиск по-русски.
public struct EmojiEntry: Sendable, Equatable, Identifiable {
    public let symbol: String
    public let label: String
    public let keywords: [String]
    public var id: String { symbol }
}

public struct EmojiCategory: Sendable, Identifiable {
    public let id: String
    public let icon: String
    public let label: String
    let searchTerms: [String]
    let keywords: [String]
    let symbols: [String]

    public func matches(_ emoji: EmojiEntry) -> Bool {
        symbols.contains(emoji.symbol) || keywords.contains { emoji.keywords.contains($0) }
    }
}

public enum EmojiCatalog {
    /// Эмодзи категории (или все) с фильтром по подписи, ключевым словам и названиям подходящих категорий.
    public static func filter(query: String, category: EmojiCategory?) -> [EmojiEntry] {
        let base = category.map { category in entries.filter(category.matches) } ?? entries
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return base }
        return base.filter { emoji in
            let terms = categories.filter { $0.matches(emoji) }.flatMap { [$0.label] + $0.searchTerms }
            return ([emoji.label] + emoji.keywords + terms).joined(separator: " ").lowercased().contains(normalized)
        }
    }

    public static let entries: [EmojiEntry] = [
        EmojiEntry(symbol: "😀", label: "Радость", keywords: ["позитивный", "улыбка", "радость", "счастье", "happy"]),
        EmojiEntry(symbol: "😄", label: "Широкая улыбка", keywords: ["позитивный", "улыбка", "смех", "радость"]),
        EmojiEntry(symbol: "😁", label: "Улыбка с зубами", keywords: ["позитивный", "улыбка", "радость"]),
        EmojiEntry(symbol: "😆", label: "Смех", keywords: ["позитивный", "смех", "смешно", "улыбка"]),
        EmojiEntry(symbol: "🤣", label: "Сильный смех", keywords: ["позитивный", "смех", "ржу", "смешно"]),
        EmojiEntry(symbol: "😂", label: "Слёзы радости", keywords: ["позитивный", "смех", "слезы", "смешно"]),
        EmojiEntry(symbol: "🙂", label: "Лёгкая улыбка", keywords: ["позитивный", "улыбка", "спокойный"]),
        EmojiEntry(symbol: "😊", label: "Смущённая улыбка", keywords: ["позитивный", "улыбка", "милый"]),
        EmojiEntry(symbol: "😇", label: "Ангел", keywords: ["позитивный", "добрый", "милый"]),
        EmojiEntry(symbol: "😍", label: "Влюблённость", keywords: ["любовь", "сердце", "позитивный", "нравится"]),
        EmojiEntry(symbol: "🥰", label: "Нежность", keywords: ["любовь", "сердце", "милый", "позитивный"]),
        EmojiEntry(symbol: "😘", label: "Поцелуй", keywords: ["любовь", "поцелуй", "сердце"]),
        EmojiEntry(symbol: "😋", label: "Вкусно", keywords: ["еда", "вкусно", "весёлый"]),
        EmojiEntry(symbol: "😎", label: "Крутой", keywords: ["крутой", "серьезный", "спокойный", "очки"]),
        EmojiEntry(symbol: "🤩", label: "В восторге", keywords: ["позитивный", "восторг", "звезды"]),
        EmojiEntry(symbol: "🥳", label: "Праздник", keywords: ["праздник", "вечеринка", "позитивный"]),
        EmojiEntry(symbol: "😉", label: "Подмигивание", keywords: ["флирт", "улыбка", "намёк"]),
        EmojiEntry(symbol: "🤗", label: "Объятия", keywords: ["поддержка", "добрый", "позитивный"]),
        EmojiEntry(symbol: "🤭", label: "Смешок", keywords: ["смех", "смешно", "хихи"]),
        EmojiEntry(symbol: "😏", label: "Самодовольный", keywords: ["хитрый", "серьезный", "ухмылка"]),
        EmojiEntry(symbol: "😐", label: "Нейтральный", keywords: ["серьезный", "нейтральный", "покер", "poker face"]),
        EmojiEntry(symbol: "😑", label: "Без эмоций", keywords: ["серьезный", "покер", "безэмоциональный"]),
        EmojiEntry(symbol: "😶", label: "Молчание", keywords: ["серьезный", "молчание", "покер"]),
        EmojiEntry(symbol: "🫥", label: "Растворение", keywords: ["серьезный", "неловко", "тихо"]),
        EmojiEntry(symbol: "🤨", label: "Сомнение", keywords: ["серьезный", "подозрение", "скепсис"]),
        EmojiEntry(symbol: "🧐", label: "Изучает", keywords: ["серьезный", "внимательно", "скепсис"]),
        EmojiEntry(symbol: "🙄", label: "Закатывание глаз", keywords: ["серьезный", "скука", "раздражение"]),
        EmojiEntry(symbol: "😒", label: "Недовольство", keywords: ["серьезный", "недовольный", "раздражение"]),
        EmojiEntry(symbol: "😬", label: "Неловкость", keywords: ["неловко", "серьезный", "зажатость"]),
        EmojiEntry(symbol: "😮‍💨", label: "Выдох", keywords: ["усталость", "серьезный", "облегчение"]),
        EmojiEntry(symbol: "😴", label: "Сонный", keywords: ["сон", "усталость", "скучно"]),
        EmojiEntry(symbol: "🤔", label: "Размышление", keywords: ["думать", "серьезный", "вопрос"]),
        EmojiEntry(symbol: "🤐", label: "На замке", keywords: ["молчание", "секрет", "серьезный"]),
        EmojiEntry(symbol: "😷", label: "В маске", keywords: ["болею", "маска", "серьезный"]),
        EmojiEntry(symbol: "😵", label: "Головокружение", keywords: ["шок", "усталость", "в шоке"]),
        EmojiEntry(symbol: "🤯", label: "Взорван мозг", keywords: ["шок", "удивление", "в шоке"]),
        EmojiEntry(symbol: "😱", label: "Ужас", keywords: ["страх", "шок", "крик"]),
        EmojiEntry(symbol: "😨", label: "Испуг", keywords: ["страх", "серьезный", "испуг"]),
        EmojiEntry(symbol: "😰", label: "Нервничаю", keywords: ["страх", "нервы", "стресс"]),
        EmojiEntry(symbol: "😭", label: "Сильный плач", keywords: ["грусть", "плач", "слезы"]),
        EmojiEntry(symbol: "😢", label: "Грусть", keywords: ["грусть", "печаль", "слезы"]),
        EmojiEntry(symbol: "☹️", label: "Печаль", keywords: ["грусть", "печаль", "негатив"]),
        EmojiEntry(symbol: "🙁", label: "Грустный", keywords: ["грусть", "печаль"]),
        EmojiEntry(symbol: "😔", label: "Уныние", keywords: ["грусть", "разочарование", "тихо"]),
        EmojiEntry(symbol: "😞", label: "Расстроен", keywords: ["грусть", "разочарование", "негатив"]),
        EmojiEntry(symbol: "😟", label: "Волнение", keywords: ["волнение", "серьезный", "тревога"]),
        EmojiEntry(symbol: "😕", label: "Озадачен", keywords: ["непонимание", "серьезный", "вопрос"]),
        EmojiEntry(symbol: "😤", label: "Фыркает", keywords: ["злость", "недовольный", "сильный"]),
        EmojiEntry(symbol: "😠", label: "Злость", keywords: ["злость", "сердитый", "агрессия"]),
        EmojiEntry(symbol: "😡", label: "Ярость", keywords: ["злость", "ярость", "агрессия"]),
        EmojiEntry(symbol: "🤬", label: "Ругательства", keywords: ["злость", "мат", "ярость"]),
        EmojiEntry(symbol: "👍", label: "Большой палец вверх", keywords: ["ок", "нравится", "позитивный", "согласен"]),
        EmojiEntry(symbol: "👎", label: "Большой палец вниз", keywords: ["нет", "негатив", "не согласен"]),
        EmojiEntry(symbol: "👏", label: "Аплодисменты", keywords: ["молодец", "поздравляю", "позитивный"]),
        EmojiEntry(symbol: "🙌", label: "Победа", keywords: ["ура", "позитивный", "успех"]),
        EmojiEntry(symbol: "🤝", label: "Рукопожатие", keywords: ["договор", "согласен", "дружба"]),
        EmojiEntry(symbol: "🙏", label: "Спасибо", keywords: ["спасибо", "пожалуйста", "молитва"]),
        EmojiEntry(symbol: "💪", label: "Сила", keywords: ["сила", "мощь", "поддержка"]),
        EmojiEntry(symbol: "🔥", label: "Огонь", keywords: ["круто", "жарко", "топ"]),
        EmojiEntry(symbol: "✨", label: "Искры", keywords: ["красиво", "позитивный", "магия"]),
        EmojiEntry(symbol: "🌟", label: "Звезда", keywords: ["класс", "топ", "звезда"]),
        EmojiEntry(symbol: "💯", label: "Сто", keywords: ["идеально", "топ", "согласен"]),
        EmojiEntry(symbol: "❤️", label: "Красное сердце", keywords: ["любовь", "сердце", "нравится"]),
        EmojiEntry(symbol: "🩵", label: "Голубое сердце", keywords: ["сердце", "дружба", "спокойный"]),
        EmojiEntry(symbol: "💔", label: "Разбитое сердце", keywords: ["грусть", "любовь", "боль"]),
        EmojiEntry(symbol: "🎉", label: "Конфетти", keywords: ["праздник", "ура", "вечеринка"]),
        EmojiEntry(symbol: "🎊", label: "Праздничный шар", keywords: ["праздник", "вечеринка", "радость"]),
        EmojiEntry(symbol: "🎁", label: "Подарок", keywords: ["подарок", "праздник", "сюрприз"]),
        EmojiEntry(symbol: "🚀", label: "Ракета", keywords: ["быстро", "запуск", "успех"]),
        EmojiEntry(symbol: "👀", label: "Смотрю", keywords: ["внимание", "смотрю", "интерес"]),
        EmojiEntry(symbol: "💬", label: "Диалог", keywords: ["чат", "разговор", "сообщение"]),
        EmojiEntry(symbol: "🤖", label: "Робот", keywords: ["бот", "робот", "техника"]),
        EmojiEntry(symbol: "🐱", label: "Кот", keywords: ["кот", "животное", "милый"]),
        EmojiEntry(symbol: "🐶", label: "Собака", keywords: ["собака", "животное", "милый"]),
        EmojiEntry(symbol: "🦊", label: "Лиса", keywords: ["лиса", "животное", "хитрый"]),
        EmojiEntry(symbol: "🐼", label: "Панда", keywords: ["панда", "животное", "милый"]),
        EmojiEntry(symbol: "🐸", label: "Лягушка", keywords: ["лягушка", "животное", "мем"]),
        EmojiEntry(symbol: "🍕", label: "Пицца", keywords: ["еда", "пицца", "вкусно"]),
        EmojiEntry(symbol: "☕", label: "Кофе", keywords: ["кофе", "напиток", "утро"]),
        EmojiEntry(symbol: "🍔", label: "Бургер", keywords: ["еда", "бургер", "вкусно"]),
        EmojiEntry(symbol: "🍿", label: "Попкорн", keywords: ["кино", "еда", "смотрю"]),
        EmojiEntry(symbol: "🎮", label: "Геймпад", keywords: ["игры", "гейминг", "игра"]),
        EmojiEntry(symbol: "🏆", label: "Кубок", keywords: ["победа", "топ", "успех"]),
    ]

    public static let categories: [EmojiCategory] = [
        EmojiCategory(id: "laughing", icon: "😂", label: "Смеющиеся", searchTerms: ["смех", "смешно", "ржу", "весело", "радостно", "смеющиеся"], keywords: ["смех", "смешно", "хихи"], symbols: ["😀", "😄", "😁", "😆", "🤣", "😂", "🤭"]),
        EmojiCategory(id: "surprised", icon: "😮", label: "Удивленные", searchTerms: ["удивление", "шок", "восторг", "удивлен", "удивленные"], keywords: ["удивление", "шок", "восторг", "звезды"], symbols: ["😮", "🤩", "🤯", "😵"]),
        EmojiCategory(id: "sad", icon: "😢", label: "Расстроенные", searchTerms: ["грусть", "печаль", "расстроен", "плохо", "обидно", "расстроенные"], keywords: ["грусть", "печаль", "разочарование", "слезы", "негатив"], symbols: ["😭", "😢", "☹️", "🙁", "😔", "😞"]),
        EmojiCategory(id: "angry", icon: "😡", label: "Злые", searchTerms: ["злость", "злой", "сердитый", "ярость", "злые"], keywords: ["злость", "сердитый", "агрессия", "ярость", "мат"], symbols: ["😤", "😠", "😡", "🤬"]),
        EmojiCategory(id: "scared", icon: "😱", label: "Испугавшиеся", searchTerms: ["страх", "испуг", "страшно", "боюсь", "испугавшиеся"], keywords: ["страх", "испуг", "нервы", "стресс", "крик"], symbols: ["😱", "😨", "😰"]),
        EmojiCategory(id: "serious", icon: "😐", label: "Серьезные", searchTerms: ["серьезный", "нейтрально", "спокойно", "покер", "серьезные"], keywords: ["серьезный", "нейтральный", "покер", "скепсис", "молчание"], symbols: ["😐", "😑", "😶", "🤨", "🧐", "🤔", "😏"]),
        EmojiCategory(id: "thumbs_up", icon: "👍", label: "Хорошо", searchTerms: ["хорошо", "отлично", "нравится", "ок", "согласен", "палец вверх"], keywords: ["ок", "нравится", "согласен", "идеально", "топ", "молодец", "успех"], symbols: ["👍", "👏", "🙌", "💪", "🔥", "✨", "🌟", "💯", "🏆"]),
        EmojiCategory(id: "thumbs_down", icon: "👎", label: "Плохо", searchTerms: ["плохо", "не нравится", "против", "нет", "палец вниз"], keywords: ["нет", "негатив", "не согласен", "недовольный", "раздражение"], symbols: ["👎", "😒", "🙄", "😕"]),
        EmojiCategory(id: "love", icon: "❤️", label: "Люблю", searchTerms: ["люблю", "любовь", "сердце", "интим", "поцелуй", "флирт"], keywords: ["любовь", "сердце", "поцелуй", "флирт", "милый", "нравится"], symbols: ["😍", "🥰", "😘", "😉", "❤️", "🩵", "💔"]),
    ]
}
