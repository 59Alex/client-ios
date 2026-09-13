import ConnectCalls
import Foundation

/// Сигналы текстовой сессии чата в топике `ov-signal` (`TextSessionHolder.tsx`).
public enum ChatSignal: Sendable, Equatable {
    /// Новое сообщение целиком: получатели вставляют его без перезапроса.
    case message(ChatMessage)
    case delete(messageId: String)
    case edit(messageId: String, diapason: TextDiapason)

    public func packet(client: String) -> SignalPacket {
        switch self {
        case let .message(message):
            SignalPacket(type: "chat", data: Self.json(MessagePayload(message)), client: client)
        case let .delete(messageId):
            SignalPacket(type: "chat:delete:\(messageId)", data: messageId, client: client)
        case let .edit(messageId, diapason):
            SignalPacket(type: "chat:edit:\(messageId)", data: Self.json(EditPayload(messageId: messageId, diapason: DiapasonPayload(diapason))), client: client)
        }
    }

    public init?(packet: SignalPacket) {
        if packet.type == "chat" {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(packet.data.utf8)) as? [String: Any],
                object["message"] is String,
                object["username"] is String,
                object["dateTimeCreateTimestamp"] is NSNumber,
                let message = try? JSONDecoder().decode(ChatMessage.self, from: Data(packet.data.utf8))
            else { return nil }
            self = .message(message)
        } else if packet.type == "chat:delete" || packet.type.hasPrefix("chat:delete:") {
            let id = packet.type.hasPrefix("chat:delete:") ? String(packet.type.dropFirst("chat:delete:".count)) : packet.data
            guard !id.isEmpty else { return nil }
            self = .delete(messageId: id)
        } else if packet.type.hasPrefix("chat:edit:") {
            guard
                let payload = try? JSONDecoder().decode(EditPayload.self, from: Data(packet.data.utf8)),
                let diapason = payload.diapason.value
            else { return nil }
            self = .edit(messageId: payload.messageId, diapason: diapason)
        } else {
            return nil
        }
    }

    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    struct MessagePayload: Encodable {
        let id: String
        let clientMessageId: String?
        let userId: String?
        let username: String
        let message: String
        let dateTimeCreateTimestamp: Int64
        let attachedFiles: [ChatAttachment]

        init(_ message: ChatMessage) {
            id = message.id
            clientMessageId = message.clientMessageId
            userId = message.authorId
            username = message.username
            self.message = message.text
            dateTimeCreateTimestamp = message.createdAtMilliseconds
            attachedFiles = message.attachments
        }
    }

    struct EditPayload: Codable {
        let messageId: String
        let diapason: DiapasonPayload
    }

    struct DiapasonPayload: Codable {
        let id: String?
        let type: String
        let from: Int
        let to: Int
        let color: String?
        let state: WeightRange.State?

        init(_ diapason: TextDiapason) {
            switch diapason {
            case let .marker(range):
                id = range.id; type = "MARKERED_TEXT"; from = range.from; to = range.to; color = range.color; state = nil
            case let .weight(range):
                id = range.id; type = "WEIGHT_TEXT"; from = range.from; to = range.to; color = nil; state = range.state
            }
        }

        var value: TextDiapason? {
            switch type {
            case "MARKERED_TEXT": color.map { .marker(MarkerRange(id: id, from: from, to: to, color: $0)) }
            case "WEIGHT_TEXT": state.map { .weight(WeightRange(id: id, from: from, to: to, state: $0)) }
            default: nil
            }
        }
    }
}
