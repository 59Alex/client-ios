import Foundation

/// Тело ошибки сервисов Connect: `{ code, errMessage, message }`.
public struct APIErrorBody: Decodable, Sendable, Equatable {
    public var code: Int?
    public var errMessage: String?
    public var message: String?

    public var displayMessage: String? { errMessage ?? message }

    enum CodingKeys: String, CodingKey {
        case code, errMessage, message
    }

    public init(code: Int? = nil, errMessage: String? = nil, message: String? = nil) {
        self.code = code
        self.errMessage = errMessage
        self.message = message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = container.decodeFlexibleInt(forKey: .code)
        errMessage = try container.decodeIfPresent(String.self, forKey: .errMessage)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}

public enum APIError: Error, Sendable, Equatable {
    case invalidResponse
    case unauthorized
    case http(statusCode: Int, body: APIErrorBody?)
    case decoding(String)
}

extension KeyedDecodingContainer {
    /// Сервисы отдают `code` то числом, то строкой — как и в веб-клиенте, принимаем оба варианта.
    public func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}
