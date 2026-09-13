import Foundation

/// Список сообщений чата от новых к старым. Слияние повторяет `messageDeduplication.ts`:
/// одно и то же сообщение приходит из снимка, истории, сигнала и ответа на отправку.
public struct MessageTimeline: Sendable, Equatable {
    public private(set) var messages: [ChatMessage] = []
    /// Удалённые локально идентификаторы: запоздавшая страница не должна их вернуть.
    private var deletedIds: Set<String> = []

    public init(_ messages: [ChatMessage] = []) {
        merge(messages)
    }

    public mutating func merge(_ incoming: [ChatMessage]) {
        for message in incoming where !deletedIds.contains(message.id) {
            if let index = messages.firstIndex(where: { Self.isSame($0, message) }) {
                let existing = messages[index]
                var merged = message
                merged.clientMessageId = existing.clientMessageId ?? message.clientMessageId
                if merged.markers.isEmpty { merged.markers = existing.markers }
                if merged.weights.isEmpty { merged.weights = existing.weights }
                messages[index] = merged
            } else {
                messages.append(message)
            }
        }
        messages.sort { lhs, rhs in
            lhs.createdAtMilliseconds != rhs.createdAtMilliseconds
                ? lhs.createdAtMilliseconds > rhs.createdAtMilliseconds
                : lhs.id > rhs.id
        }
    }

    public mutating func remove(id: String) {
        deletedIds.insert(id)
        messages.removeAll { $0.id == id }
    }

    public mutating func update(id: String, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id || $0.clientMessageId == id }) else { return }
        change(&messages[index])
    }

    /// Вставляет или заменяет диапазон оформления по `id`, без `id` — добавляет.
    public mutating func apply(_ diapason: TextDiapason, to messageId: String) {
        update(id: messageId) { message in
            switch diapason {
            case let .marker(range):
                if let id = range.id, let index = message.markers.firstIndex(where: { $0.id == id }) {
                    message.markers[index] = range
                } else {
                    message.markers.append(range)
                }
            case let .weight(range):
                if let id = range.id, let index = message.weights.firstIndex(where: { $0.id == id }) {
                    message.weights[index] = range
                } else {
                    message.weights.append(range)
                }
            }
        }
    }

    static func isSame(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.id == rhs.id { return true }
        if let l = lhs.clientMessageId, let r = rhs.clientMessageId, l == r { return true }
        if lhs.id == rhs.clientMessageId || lhs.clientMessageId == rhs.id { return true }
        return ChatMessage.normalize(lhs.username) == ChatMessage.normalize(rhs.username)
            && lhs.text == rhs.text
            && lhs.createdAtMilliseconds == rhs.createdAtMilliseconds
            && lhs.attachments == rhs.attachments
    }
}

/// Диапазон оформления текста сообщения.
public enum TextDiapason: Sendable, Equatable {
    case marker(MarkerRange)
    case weight(WeightRange)
}
