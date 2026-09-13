import Foundation

/// Карточка контакта: `UserCardLightDto` из `GET /api/user-card/get-contacts/{userId}`
/// и `get-fast-info-by-user-id` (`connect-ui/src/types/user.ts`).
public struct Contact: Decodable, Sendable, Equatable, Identifiable {
    public var userId: String
    public var name: String
    public var username: String
    public var status: UserStatus
    /// Время последнего выхода из сети; сервис не отдаёт его для скрытых профилей.
    public var lastSeenAt: Date?
    /// Ключ аватара в connect-s3, а не публичный URL.
    public var avatarKey: String?

    public var id: String { userId }

    public init(
        userId: String,
        name: String,
        username: String,
        status: UserStatus = .offline,
        lastSeenAt: Date? = nil,
        avatarKey: String? = nil
    ) {
        self.userId = userId
        self.name = name
        self.username = username
        self.status = status
        self.lastSeenAt = lastSeenAt
        self.avatarKey = avatarKey
    }

    /// Имя для показа: как в веб-клиенте, пустое имя заменяется логином.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? handle : trimmed
    }

    /// Логин с одним ведущим `@`.
    public var handle: String {
        "@" + String(username.drop { $0 == "@" })
    }

    enum CodingKeys: String, CodingKey {
        case userId, id, name, username, status, lastSeenAt, avatarUrl, avatarUrlS3
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let userId = try container.decodeIfPresent(String.self, forKey: .userId)
            ?? container.decodeIfPresent(String.self, forKey: .id)
        else {
            throw DecodingError.keyNotFound(CodingKeys.userId, .init(codingPath: decoder.codingPath, debugDescription: "userId и id отсутствуют"))
        }
        self.userId = userId
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        status = (try? container.decodeIfPresent(UserStatus.self, forKey: .status)) ?? .offline
        lastSeenAt = (try? container.decodeIfPresent(String.self, forKey: .lastSeenAt)).flatMap(Self.parseDate)
        let s3Key = try container.decodeIfPresent(String.self, forKey: .avatarUrlS3)
        let url = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
        avatarKey = [s3Key, url].compactMap { $0 }.first { !$0.isEmpty }
    }

    static func parseDate(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
