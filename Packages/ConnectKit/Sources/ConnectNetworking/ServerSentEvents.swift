import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Событие потока `text/event-stream`.
public struct ServerSentEvent: Sendable, Equatable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Разбор `text/event-stream` по байтам: событие заканчивается пустой строкой,
/// строки `data:` склеиваются через перевод строки, комментарии (`:`) пропускаются.
public struct ServerSentEventParser: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?
    private var lastByteWasCR = false

    public init() {}

    public mutating func feed(_ byte: UInt8) -> ServerSentEvent? {
        switch byte {
        case UInt8(ascii: "\n"):
            if lastByteWasCR {
                lastByteWasCR = false
                return nil
            }
            return endLine()
        case UInt8(ascii: "\r"):
            lastByteWasCR = true
            return endLine()
        default:
            lastByteWasCR = false
            line.append(byte)
            return nil
        }
    }

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [ServerSentEvent] {
        bytes.compactMap { feed($0) }
    }

    private mutating func endLine() -> ServerSentEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else { return dispatch() }

        let text = String(decoding: line, as: UTF8.self)
        guard !text.hasPrefix(":") else { return nil }

        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = text[...]
            value = ""
        }

        switch field {
        case "data": dataLines.append(String(value))
        case "event": eventName = String(value)
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            dataLines.removeAll()
            eventName = nil
        }
        guard !dataLines.isEmpty else { return nil }
        return ServerSentEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}

/// Долгий HTTP-ответ, прочитанный как поток байтов. Протокол позволяет подменять сеть в тестах.
public protocol EventStreamTransport: Sendable {
    func events(for request: URLRequest) -> AsyncThrowingStream<ServerSentEvent, any Error>
}

#if canImport(Darwin)
public struct URLSessionEventStreamTransport: EventStreamTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func events(for request: URLRequest) -> AsyncThrowingStream<ServerSentEvent, any Error> {
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = request
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = .infinity
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        throw APIError.http(statusCode: http.statusCode, body: nil)
                    }
                    var parser = ServerSentEventParser()
                    for try await byte in bytes {
                        if let event = parser.feed(byte) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
