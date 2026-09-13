import Foundation

public enum UserStatus: String, Codable, Sendable {
    case online = "ONLINE"
    case hidden = "HIDDEN"
    case offline = "OFFLINE"
}

public struct UserContact: Codable, Sendable, Equatable {
    public var name: String
    public var username: String

    public init(name: String, username: String) {
        self.name = name
        self.username = username
    }
}

/// Карточка текущего пользователя: `GET /api/user-card/get-by-jwt` в `connect`.
public struct User: Codable, Sendable, Equatable, Identifiable {
    public var userId: String
    public var phoneNumber: String?
    public var name: String
    public var email: String
    public var username: String
    public var status: UserStatus
    public var contacts: [UserContact]

    public var id: String { userId }

    public init(
        userId: String,
        phoneNumber: String? = nil,
        name: String,
        email: String,
        username: String,
        status: UserStatus,
        contacts: [UserContact] = []
    ) {
        self.userId = userId
        self.phoneNumber = phoneNumber
        self.name = name
        self.email = email
        self.username = username
        self.status = status
        self.contacts = contacts
    }
}
