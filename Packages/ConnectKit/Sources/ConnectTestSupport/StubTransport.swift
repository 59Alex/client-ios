import ConnectNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Транспорт без сети: ответы по пути запроса. Используется в юнит-тестах и UI-стабе приложения.
public final class StubTransport: HTTPTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) async throws -> HTTPResponse

    // NSLock защищает словарь обработчиков и журнал запросов.
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var recorded: [URLRequest] = []

    public init() {}

    public func on(_ path: String, handler: @escaping Handler) {
        lock.withLock { handlers[path] = handler }
    }

    public func on(_ path: String, status: Int = 200, json: String) {
        on(path) { _ in HTTPResponse(statusCode: status, body: Data(json.utf8)) }
    }

    public var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    public func requests(to path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let path = request.url?.path ?? ""
        let handler = lock.withLock {
            recorded.append(request)
            return handlers[path]
        }
        guard let handler else {
            return HTTPResponse(statusCode: 404, body: Data())
        }
        return try await handler(request)
    }
}

public enum TestJWT {
    /// Неподписанный JWT с заданным `exp` — сервисы его не проверяют, только клиентская логика.
    public static func make(expiresAt: Date, subject: String = "user-1") -> String {
        func encode(_ object: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = encode(["alg": "none", "typ": "JWT"])
        let payload = encode(["exp": Int(expiresAt.timeIntervalSince1970), "sub": subject])
        return "\(header).\(payload).signature"
    }
}
