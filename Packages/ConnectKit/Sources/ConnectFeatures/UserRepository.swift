import ConnectCore
import ConnectNetworking
import Foundation

public protocol UserRepository: Sendable {
    func currentUser() async throws -> User
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
}
