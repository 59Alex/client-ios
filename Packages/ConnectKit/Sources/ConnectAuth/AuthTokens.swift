import Foundation

public struct AuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var createdAt: Date

    public init(accessToken: String, refreshToken: String? = nil, idToken: String? = nil, createdAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.createdAt = createdAt
    }

    /// Разбирает Keycloak token response, который user-service отдаёт в
    /// snake_case или camelCase (`toStoredAuthTokens` веб-клиента).
    public init?(tokenResponse: [String: Any], createdAt: Date) {
        func string(_ snakeCase: String, _ camelCase: String) -> String? {
            let value = tokenResponse[snakeCase] ?? tokenResponse[camelCase]
            guard let value = value as? String, !value.isEmpty else { return nil }
            return value
        }

        guard let accessToken = string("access_token", "accessToken") else { return nil }
        self.init(
            accessToken: accessToken,
            refreshToken: string("refresh_token", "refreshToken"),
            idToken: string("id_token", "idToken"),
            createdAt: createdAt
        )
    }

    /// Время истечения access token из claim `exp`; `nil`, если claim не читается.
    public var accessTokenExpiresAt: Date? {
        JWT.expiration(of: accessToken)
    }

    public func isAccessTokenExpired(now: Date) -> Bool {
        guard let expiresAt = accessTokenExpiresAt else { return false }
        return expiresAt <= now
    }
}

enum JWT {
    static func expiration(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)

        guard
            let data = Data(base64Encoded: base64),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = payload["exp"] as? NSNumber
        else { return nil }

        return Date(timeIntervalSince1970: exp.doubleValue)
    }
}
