import ConnectCore
import ConnectNetworking
import Foundation

public protocol UserRepository: Sendable {
    func currentUser() async throws -> User
    /// Добавляет загруженное фото в профиль; `isAvatar` делает его аватаром.
    func addPhoto(userId: String, urlS3: String, name: String, extension: String, isAvatar: Bool) async throws
    /// Карточка с аватаром и галереей (`get-fast-info-by-user-id`).
    func card(userId: String) async throws -> Contact
}

/// Карточка пользователя из основного backend `connect`.
public struct RemoteUserRepository: UserRepository {
    private let client: HTTPClient

    public init(client: HTTPClient) {
        self.client = client
    }

    public func currentUser() async throws -> User {
        try await client.getDecoded("/api/user-card/get-by-jwt")
    }

    public func addPhoto(userId: String, urlS3: String, name: String, extension: String, isAvatar: Bool) async throws {
        let body = AddPhotoRequest(userId: userId, images: [.init(fileInfo: .init(urlS3: urlS3, name: name, extension: `extension`), displayIndex: 0, isAvatar: isAvatar)])
        try HTTPClient.requireSuccess(try await client.post("/api/user-card/add-photo", json: body))
    }

    public func card(userId: String) async throws -> Contact {
        let encoded = userId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? userId
        return try await client.getDecoded("/api/user-card/get-fast-info-by-user-id/\(encoded)")
    }
}

private struct AddPhotoRequest: Encodable, Sendable {
    struct Image: Encodable, Sendable {
        struct FileInfo: Encodable, Sendable {
            let urlS3: String
            let name: String
            let `extension`: String
        }

        let fileInfo: FileInfo
        let displayIndex: Int
        let isAvatar: Bool
    }

    let userId: String
    let images: [Image]
}
