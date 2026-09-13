import Foundation

/// Сложность пароля как в `AuthGate.tsx`: четыре требования по порядку.
public struct PasswordStrength: Sendable, Equatable {
    public static let labels = ["Слишком слабый", "Слабый", "Средний", "Хороший", "Сложный"]

    public let missing: [String]

    public init(_ password: String) {
        var missing: [String] = []
        if password.count < 8 { missing.append("Добавьте минимум 8 символов") }
        if password.range(of: "[a-zа-яё]", options: [.regularExpression, .caseInsensitive]) == nil { missing.append("Добавьте буквы") }
        if password.range(of: "\\d", options: .regularExpression) == nil { missing.append("Добавьте цифры") }
        if password.range(of: "[^a-zа-яё\\d\\s]", options: [.regularExpression, .caseInsensitive]) == nil { missing.append("Добавьте спецсимвол") }
        self.missing = missing
    }

    /// Выполненные требования, 0–4.
    public var score: Int { 4 - missing.count }
    public var label: String { Self.labels[score] }
    public var isStrongEnough: Bool { missing.isEmpty }
    public var hint: String { missing.isEmpty ? "Требования выполнены" : missing.joined(separator: ". ") }
}

/// Российский телефон в формате `+7 (AAA) BBB-CC-DD`.
public enum PhoneMask {
    /// Цифры номера: первая 8 становится 7, без 7 в начале она добавляется; не больше 11 цифр.
    public static func digits(_ raw: String) -> String {
        var digits = raw.filter(\.isASCII).filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        if digits.hasPrefix("8") {
            digits = "7" + digits.dropFirst()
        } else if !digits.hasPrefix("7") {
            digits = "7" + digits
        }
        return String(digits.prefix(11))
    }

    /// Форматирует по мере ввода: `+7 (999`, `+7 (999) 12`, `+7 (999) 123-45-67`.
    public static func format(_ raw: String) -> String {
        let digits = Array(digits(raw))
        guard !digits.isEmpty else { return "" }
        let rest = digits.dropFirst()
        var result = "+7"
        for (index, digit) in rest.enumerated() {
            switch index {
            case 0: result += " (\(digit)"
            case 3: result += ") \(digit)"
            case 6, 8: result += "-\(digit)"
            default: result.append(digit)
            }
        }
        return result
    }

    public static func isComplete(_ raw: String) -> Bool {
        digits(raw).count == 11
    }
}

public enum EmailRule {
    public static func isValid(_ email: String) -> Bool {
        email.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil
    }
}
