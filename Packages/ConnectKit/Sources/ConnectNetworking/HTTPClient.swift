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

    public func post(_ path: String, json body: some Encodable & Sendable, headers: [String: String]) async throws -> HTTPResponse {
        try await send(method: "POST", path: path, body: JSONEncoder().encode(body), headers: headers)
    }

    public func delete(_ path: String, json body: some Encodable & Sendable, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await send(method: "DELETE", path: path, body: JSONEncoder().encode(body), headers: headers)
    }

    public func getDecoded<Response: Decodable>(_ path: String, as type: Response.Type = Response.self) async throws -> Response {
        try Self.decode(try await get(path))
    }

    public func postDecoded<Response: Decodable>(
        _ path: String,
        json body: some Encodable & Sendable,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try Self.decode(try await post(path, json: body))
    }

    /// Успешный ответ или `APIError.http` со статусом и телом ошибки сервиса.
    public static func requireSuccess(_ response: HTTPResponse) throws {
        guard response.isSuccess else {
            throw APIError.http(statusCode: response.statusCode, body: try? JSONDecoder().decode(APIErrorBody.self, from: response.body))
        }
    }

    public static func decode<Response: Decodable>(_ response: HTTPResponse, as type: Response.Type = Response.self) throws -> Response {
        try requireSuccess(response)
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Отправляет запрос. Для авторизованного клиента 401 очищает сессию и
    /// превращается в `APIError.unauthorized`; остальные статусы возвращаются как есть.
    public func send(
        method: String,
        path: String,
        body: Data?,
        contentType: String = "application/json",
        headers: [String: String] = [:],
        timeout requestTimeout: TimeInterval? = nil
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: Self.join(baseURL, path), timeoutInterval: requestTimeout ?? timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
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

    /// Токен текущей сессии для запросов, которые авторизуются не заголовком (SSE).
    public func accessToken() async -> String? {
        await tokenProvider?.validAccessToken()
    }

    public static func join(_ baseURL: URL, _ path: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var tail = path[...]
        while tail.hasPrefix("/") { tail.removeFirst() }
        return URL(string: "\(base)/\(tail)") ?? baseURL
    }
}
