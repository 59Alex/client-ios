import ConnectNetworking
import Foundation

/// Гостевая ссылка на идущий групповой звонок (`meetingRoute.ts`): `<origin>/share/meet/<code>`,
/// код — 43 символа base64url.
public enum MeetingLinks {
    public static func url(origin: URL, code: String) -> URL {
        origin.appendingPathComponent("share").appendingPathComponent("meet").appendingPathComponent(code)
    }

    /// Код из ссылки или сам код; `nil`, если это не ссылка на встречу.
    public static func code(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: Substring
        if let range = trimmed.range(of: "/share/meet/") {
            candidate = trimmed[range.upperBound...].split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first ?? ""
        } else {
            candidate = Substring(trimmed)
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard candidate.count == 43, candidate.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return String(candidate)
    }
}

public struct MeetingInvitation: Decodable, Sendable, Equatable {
    public let code: String
    public let expiresAt: String?

    public init(code: String, expiresAt: String?) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

public struct MeetingAcceptance: Decodable, Sendable, Equatable {
    public let groupId: String
    public let callId: String?
    public let active: Bool

    public init(groupId: String, callId: String?, active: Bool) {
        self.groupId = groupId
        self.callId = callId
        self.active = active
    }
}

public enum MeetingError: Error, Equatable {
    case disabled
    case forbidden
    case expired
    case tooMany
    case other

    public var message: String {
        switch self {
        case .disabled: "Гостевые встречи для этой группы выключены"
        case .forbidden: "Ссылку для гостей может создать владелец или модератор группы, который начал звонок"
        case .expired: "Ссылка недействительна или звонок уже завершён"
        case .tooMany: "Слишком много активных ссылок или гостей, попробуйте позже"
        case .other: "Не удалось выполнить действие со встречей"
        }
    }

    static func from(status: Int, creating: Bool) -> MeetingError {
        switch status {
        case 401, 403: creating ? .forbidden : .expired
        case 404: creating ? .disabled : .expired
        case 409, 410: .expired
        case 429: .tooMany
        default: .other
        }
    }
}

public protocol MeetingsAPI: Sendable {
    /// Ссылка для гостей: `POST /api/meetings/invitations` ведущим идущего звонка.
    func createInvitation(groupId: String, callId: String) async throws -> MeetingInvitation
    /// Вошедший пользователь открывает ссылку: вступает в группу (`POST /api/meetings/accept`).
    func accept(code: String) async throws -> MeetingAcceptance
}

public struct RemoteMeetingsAPI: MeetingsAPI {
    private let main: HTTPClient

    public init(main: HTTPClient) {
        self.main = main
    }

    public func createInvitation(groupId: String, callId: String) async throws -> MeetingInvitation {
        let response = try await main.post("/api/meetings/invitations", json: InvitationBody(groupId: groupId, callId: callId))
        guard response.isSuccess else { throw MeetingError.from(status: response.statusCode, creating: true) }
        return try HTTPClient.decode(response)
    }

    public func accept(code: String) async throws -> MeetingAcceptance {
        let response = try await main.post("/api/meetings/accept", json: AcceptBody(code: code))
        guard response.isSuccess else { throw MeetingError.from(status: response.statusCode, creating: false) }
        return try HTTPClient.decode(response)
    }

    private struct InvitationBody: Encodable, Sendable {
        let groupId: String
        let callId: String
    }

    private struct AcceptBody: Encodable, Sendable {
        let code: String
    }
}
