import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Источник bearer-токена для авторизованных запросов.
public protocol AccessTokenProvider: Sendable {
    func validAccessToken() async -> String?
    func handleUnauthorized() async
}

/// JSON-клиент одного сервиса Connect.
public struct HTTPClient: Sendable {
    public let baseURL: URL
    private let transport: any HTTPTransport
    private let tokenProvider: (any AccessTokenProvider)?
    private let timeout: TimeInterval

    public init(
        baseURL: URL,
        transport: any HTTPTransport,
        tokenProvider: (any AccessTokenProvider)? = nil,
        timeout: TimeInterval = 15
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.timeout = timeout
    }

    public func get(_ path: String) async throws -> HTTPResponse {
        try await send(method: "GET", path: path, body: nil)
    }

    public func post(_ path: String, json body: some Encodable & Sendable) async throws -> HTTPResponse {
        try await send(method: "POST", path: path, body: JSONEncoder().encode(body))
    }

    public func getDecoded<Response: Decodable>(_ path: String, as type: Response.Type = Response.self) async throws -> Response {
        let response = try await get(path)
        guard response.isSuccess else {
            throw APIError.http(statusCode: response.statusCode, body: try? JSONDecoder().decode(APIErrorBody.self, from: response.body))
        }
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Отправляет запрос. Для авторизованного клиента 401 очищает сессию и
    /// превращается в `APIError.unauthorized`; остальные статусы возвращаются как есть.
    public func send(method: String, path: String, body: Data?) async throws -> HTTPResponse {
        var request = URLRequest(url: Self.join(baseURL, path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let tokenProvider, let token = await tokenProvider.validAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let response = try await transport.send(request)
        if response.statusCode == 401, let tokenProvider {
            await tokenProvider.handleUnauthorized()
            throw APIError.unauthorized
        }
        return response
    }

    static func join(_ baseURL: URL, _ path: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var tail = path[...]
        while tail.hasPrefix("/") { tail.removeFirst() }
        return URL(string: "\(base)/\(tail)") ?? baseURL
    }
}
