import ConnectCore
import Foundation

public enum ChatKind: String, Sendable, Equatable, Hashable, Codable {
    case p2p = "P2P"
    case group = "GROUP"
    /// Текстовый канал комнаты; в сводке непрочитанного у него тип `ROOM`.
    case channel = "ROOM"

    /// Префикс оптимистичного id сообщения, как у веб-клиента.
    var localIdPrefix: String {
        switch self {
        case .p2p: "p2p"
        case .group: "group"
        case .channel: "channel"
        }
    }
}

/// Вложение сообщения: `FileInfo` веб-клиента. Типа MIME нет — вид определяется по имени и расширению.
public struct ChatAttachment: Codable, Sendable, Equatable, Hashable {
    public var urlS3: String
    public var previewUrlS3: String?
    public var name: String
    public var `extension`: String

    public init(urlS3: String, previewUrlS3: String? = nil, name: String, extension: String) {
        self.urlS3 = urlS3
        self.previewUrlS3 = previewUrlS3
        self.name = name
        self.extension = `extension`
    }

    public enum Kind: Sendable, Equatable {
        case voiceMessage, videoMessage, image, video, audio, pdf, document, spreadsheet, archive, file
    }

    /// Классификация `attachmentTypes.ts`.
    public var kind: Kind {
        let ext = `extension`.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let lowerName = name.lowercased()
        let audio: Set = ["mp3", "wav", "ogg", "flac", "aac", "webm"]
        let video: Set = ["mp4", "mov", "avi", "mkv", "webm"]
        // Голосовые iOS и Safari пишутся в AAC: `.m4a` и `.mp4` тоже голосовые при таком имени.
        if lowerName.hasPrefix("voice-message-"), audio.contains(ext) || ext == "m4a" || ext == "mp4" { return .voiceMessage }
        if lowerName.hasPrefix("video-message-"), video.contains(ext) { return .videoMessage }
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "svg": return .image
        case _ where video.contains(ext): return .video
        case _ where audio.contains(ext) || ext == "m4a": return .audio
        case "pdf": return .pdf
        case "doc", "docx", "rtf", "txt": return .document
        case "xls", "xlsx", "csv": return .spreadsheet
        case "zip", "rar", "7z", "tar", "gz": return .archive
        default: return .file
        }
    }

    public var displayName: String {
        let ext = `extension`.hasPrefix(".") || `extension`.isEmpty ? `extension` : "." + `extension`
        return name.lowercased().hasSuffix(ext.lowercased()) ? name : name + ext
    }

    enum CodingKeys: String, CodingKey {
        case urlS3, previewUrlS3, name, `extension`
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlS3 = try container.decodeIfPresent(String.self, forKey: .urlS3) ?? ""
        previewUrlS3 = try container.decodeIfPresent(String.self, forKey: .previewUrlS3)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        `extension` = try container.decodeIfPresent(String.self, forKey: .extension) ?? ""
    }
}

/// Выделение цветом части текста (`markeredTexts`). Границы включительно, в UTF-16.
public struct MarkerRange: Codable, Sendable, Equatable, Hashable {
    public var id: String?
    public var from: Int
    public var to: Int
    public var color: String

    public init(id: String?, from: Int, to: Int, color: String) {
        self.id = id
        self.from = from
        self.to = to
        self.color = color
    }
}

/// Начертание части текста (`weightTexts`): `BOLD` — жирный, `SKINY` — подчёркнутый.
public struct WeightRange: Codable, Sendable, Equatable, Hashable {
    public enum State: String, Codable, Sendable {
        case bold = "BOLD"
        case underline = "SKINY"
        case regular = "REGULAR"
    }

    public var id: String?
    public var from: Int
    public var to: Int
    public var state: State

    public init(id: String?, from: Int, to: Int, state: State) {
        self.id = id
        self.from = from
        self.to = to
        self.state = state
    }
}

/// Сообщение личного или группового чата.
public struct ChatMessage: Sendable, Equatable, Identifiable {
    public enum Delivery: Sendable, Equatable {
        case sent
        case sending
        case failed
    }

    public var id: String
    public var clientMessageId: String?
    public var text: String
    /// Время создания в миллисекундах epoch, как у сервиса.
    public var createdAtMilliseconds: Int64
    public var authorId: String?
    public var username: String
    public var guestName: String?
    public var attachments: [ChatAttachment]
    public var markers: [MarkerRange]
    public var weights: [WeightRange]
    public var delivery: Delivery

    public init(
        id: String,
        clientMessageId: String? = nil,
        text: String,
        createdAtMilliseconds: Int64,
        authorId: String? = nil,
        username: String,
        guestName: String? = nil,
        attachments: [ChatAttachment] = [],
        markers: [MarkerRange] = [],
        weights: [WeightRange] = [],
        delivery: Delivery = .sent
    ) {
        self.id = id
        self.clientMessageId = clientMessageId
        self.text = text
        self.createdAtMilliseconds = createdAtMilliseconds
        self.authorId = authorId
        self.username = username
        self.guestName = guestName
        self.attachments = attachments
        self.markers = markers
        self.weights = weights
        self.delivery = delivery
    }

    public var createdAt: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAtMilliseconds) / 1000)
    }

    /// Своё ли сообщение: веб сравнивает логины без регистра и ведущих `@`.
    public func isOwn(username me: String) -> Bool {
        Self.normalize(username) == Self.normalize(me)
    }

    public var callSummary: CallSummary? {
        CallSummary(text: text)
    }

    /// Сообщение из одних круглых видео показывается кружком.
    public var isVideoCircle: Bool {
        text.isEmpty && !attachments.isEmpty && attachments.allSatisfy { $0.kind == .videoMessage }
    }

    static func normalize(_ username: String) -> String {
        String(username.drop { $0 == "@" }).lowercased()
    }
}

extension ChatMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, clientMessageId, message, dateTimeCreateTimestamp, userCardId, userId, username
        case guestId, guestDisplayName, attachedFiles, markeredTexts, weightTexts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let username = try container.decodeIfPresent(String.self, forKey: .username)
        let guestName = try container.decodeIfPresent(String.self, forKey: .guestDisplayName)
        let isGuest = try container.decodeIfPresent(String.self, forKey: .guestId) != nil
        let timestamp = (try? container.decodeIfPresent(Int64.self, forKey: .dateTimeCreateTimestamp))
            ?? (try? container.decodeIfPresent(Double.self, forKey: .dateTimeCreateTimestamp)).map { Int64($0) }
            ?? 0
        let resolvedUsername = username ?? (isGuest ? (guestName ?? "Гость") : "")
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "\(resolvedUsername)-\(timestamp)",
            clientMessageId: try container.decodeIfPresent(String.self, forKey: .clientMessageId),
            text: try container.decodeIfPresent(String.self, forKey: .message) ?? "",
            createdAtMilliseconds: timestamp,
            authorId: try container.decodeIfPresent(String.self, forKey: .userCardId)
                ?? container.decodeIfPresent(String.self, forKey: .userId),
            username: resolvedUsername,
            guestName: isGuest ? (guestName ?? "Гость") : nil,
            attachments: (try? container.decodeIfPresent([ChatAttachment].self, forKey: .attachedFiles)) ?? [],
            markers: (try? container.decodeIfPresent([MarkerRange].self, forKey: .markeredTexts)) ?? [],
            weights: (try? container.decodeIfPresent([WeightRange].self, forKey: .weightTexts)) ?? []
        )
    }
}

/// Итог звонка: `__P2P_CALL_SUMMARY__:<сек>|<начало, мс>` или `GROUP_CALL_SUMMARY…`.
public struct CallSummary: Sendable, Equatable {
    public var isGroup: Bool
    public var durationSeconds: Int
    public var startedAt: Date?

    public init?(text: String) {
        let body: Substring
        if text.hasPrefix("__P2P_CALL_SUMMARY__:") {
            isGroup = false
            body = text.dropFirst("__P2P_CALL_SUMMARY__:".count)
        } else if let prefix = ["GROUP_CALL_SUMMARY", "GROUP_CALL_SUMMURY"].first(where: text.hasPrefix) {
            isGroup = true
            var rest = text.dropFirst(prefix.count)
            if rest.hasPrefix(":") { rest = rest.dropFirst() }
            body = rest
        } else {
            return nil
        }
        let parts = body.split(separator: "|", omittingEmptySubsequences: false)
        let duration = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        if isGroup {
            durationSeconds = max(1, duration)
        } else {
            guard duration > 0 else { return nil }
            durationSeconds = duration
        }
        startedAt = parts.dropFirst().first
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Текст сообщения-итога, как его отправляют веб-клиенты.
    public static func messageText(isGroup: Bool, durationSeconds: Int, startedAt: Date) -> String {
        let seconds = max(1, durationSeconds)
        let started = max(1, Int64(startedAt.timeIntervalSince1970 * 1000))
        return (isGroup ? "GROUP_CALL_SUMMARY:" : "__P2P_CALL_SUMMARY__:") + "\(seconds)|\(started)"
    }

    /// `m:ss` или `h:mm:ss`.
    public var durationText: String {
        let hours = durationSeconds / 3600
        let minutes = durationSeconds / 60 % 60
        let seconds = durationSeconds % 60
        return hours > 0
            ? "\(hours):\(Self.twoDigits(minutes)):\(Self.twoDigits(seconds))"
            : "\(minutes):\(Self.twoDigits(seconds))"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

/// Страница сообщений `PageDto`.
public struct MessagePage: Decodable, Sendable, Equatable {
    public var content: [ChatMessage]
    public var number: Int
    public var last: Bool
    public var totalElements: Int

    public init(content: [ChatMessage], number: Int, last: Bool, totalElements: Int) {
        self.content = content
        self.number = number
        self.last = last
        self.totalElements = totalElements
    }

    enum CodingKeys: String, CodingKey {
        case content, number, last, totalElements
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent([ChatMessage].self, forKey: .content) ?? []
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        last = try container.decodeIfPresent(Bool.self, forKey: .last) ?? true
        totalElements = try container.decodeIfPresent(Int.self, forKey: .totalElements) ?? content.count
    }

    /// Есть что догружать: страница не пустая и не последняя.
    public var hasMore: Bool {
        !content.isEmpty && !last
    }
}

/// Превью последнего сообщения в списке чатов.
public struct ChatPreview: Decodable, Sendable, Equatable {
    public struct FileCount: Decodable, Sendable, Equatable {
        public var fileType: String
        public var count: Int

        public init(fileType: String, count: Int) {
            self.fileType = fileType
            self.count = count
        }
    }

    public var text: String?
    public var createdAtMilliseconds: Int64?
    public var fileInfos: [FileCount]

    public init(text: String?, createdAtMilliseconds: Int64?, fileInfos: [FileCount] = []) {
        self.text = text
        self.createdAtMilliseconds = createdAtMilliseconds
        self.fileInfos = fileInfos
    }

    enum CodingKeys: String, CodingKey {
        case text, dateTimeCreateTimestamp, fileInfos
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        createdAtMilliseconds = (try? container.decodeIfPresent(Int64.self, forKey: .dateTimeCreateTimestamp))
            ?? (try? container.decodeIfPresent(Double.self, forKey: .dateTimeCreateTimestamp)).map { Int64($0) }
        fileInfos = (try? container.decodeIfPresent([FileCount].self, forKey: .fileInfos)) ?? []
    }

    /// Текст превью `HomeRoomItem.tsx`: текст, итог звонка или «2 изображения, 1 файл».
    public var summaryText: String {
        if let text, !text.isEmpty {
            if let call = CallSummary(text: text) {
                return call.isGroup ? "Групповой созвон завершён" : "Созвон завершён"
            }
            return text
        }
        return fileInfos.compactMap { info -> String? in
            guard info.count > 0 else { return nil }
            switch info.fileType {
            case "IMAGE": return "\(info.count) \(Self.plural(info.count, "изображение", "изображения", "изображений"))"
            case "VIDEO": return "\(info.count) видео"
            case "VIDEO_MESSAGE": return "\(info.count) \(Self.plural(info.count, "видеосообщение", "видеосообщения", "видеосообщений"))"
            default: return "\(info.count) \(Self.plural(info.count, "файл", "файла", "файлов"))"
            }
        }.joined(separator: ", ")
    }

    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }
}

/// Строка списка чатов.
public struct ChatSummary: Sendable, Equatable, Identifiable {
    public var kind: ChatKind
    public var roomId: String
    public var title: String
    /// Собеседник личного чата.
    public var partnerUserId: String?
    public var partnerUsername: String?
    public var avatarKey: String?
    public var preview: ChatPreview?

    public var id: String { "\(kind.rawValue):\(roomId)" }

    public init(kind: ChatKind, roomId: String, title: String, partnerUserId: String? = nil, partnerUsername: String? = nil, avatarKey: String? = nil, preview: ChatPreview? = nil) {
        self.kind = kind
        self.roomId = roomId
        self.title = title
        self.partnerUserId = partnerUserId
        self.partnerUsername = partnerUsername
        self.avatarKey = avatarKey
        self.preview = preview
    }
}

struct P2PRoomDTO: Decodable {
    struct Partner: Decodable {
        let userId: String?
        let id: String?
    }

    let id: String
    let name: String?
    let username: String?
    let avatar: String?
    let userId: String?
    let chatPartner: Partner?
    let previewMessage: ChatPreview?

    var summary: ChatSummary {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ChatSummary(
            kind: .p2p,
            roomId: id,
            title: trimmedName.isEmpty ? trimmedUsername : trimmedName,
            partnerUserId: chatPartner?.userId ?? chatPartner?.id ?? userId,
            partnerUsername: trimmedUsername.isEmpty ? nil : trimmedUsername,
            avatarKey: avatar,
            preview: previewMessage
        )
    }
}

struct GroupRoomDTO: Decodable {
    struct Avatar: Decodable {
        let urlS3: String?
    }

    let id: String
    let name: String?
    let avatar: Avatar?
    let previewMessage: ChatPreview?

    var summary: ChatSummary {
        ChatSummary(kind: .group, roomId: id, title: name ?? "", avatarKey: avatar?.urlS3, preview: previewMessage)
    }
}

/// Снимок комнаты: `GET /api/p2p-room/get/{id}` или `/api/group-room/get/{id}`.
public struct ChatSnapshot: Decodable, Sendable, Equatable {
    public enum Role: String, Decodable, Sendable {
        case admin = "ADMIN"
        case moderator = "MODERATOR"
        case subscriber = "SUBSCRIBER"
    }

    public var id: String
    public var name: String?
    public var username: String?
    public var partnerUserId: String?
    public var partnerBanned: Bool
    public var banned: Bool
    public var role: Role?
    public var meetingsAllowed: Bool
    public var memberCount: Int
    public var members: [Contact]
    public var messages: MessagePage

    enum CodingKeys: String, CodingKey {
        case id, name, username, userId, chatPartnerBanned, banned, roomRole, meetingsAllowed, members, messages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        partnerUserId = try container.decodeIfPresent(String.self, forKey: .userId)
        partnerBanned = try container.decodeIfPresent(Bool.self, forKey: .chatPartnerBanned) ?? false
        banned = try container.decodeIfPresent(Bool.self, forKey: .banned) ?? false
        role = try? container.decodeIfPresent(Role.self, forKey: .roomRole)
        meetingsAllowed = try container.decodeIfPresent(Bool.self, forKey: .meetingsAllowed) ?? false
        members = (try? container.decodeIfPresent([Contact].self, forKey: .members)) ?? []
        memberCount = members.count
        messages = try container.decodeIfPresent(MessagePage.self, forKey: .messages)
            ?? MessagePage(content: [], number: 0, last: true, totalElements: 0)
    }

    public init(id: String, name: String? = nil, partnerUserId: String? = nil, messages: MessagePage) {
        self.id = id
        self.name = name
        username = nil
        self.partnerUserId = partnerUserId
        partnerBanned = false
        banned = false
        role = nil
        meetingsAllowed = false
        memberCount = 0
        members = []
        self.messages = messages
    }
}
