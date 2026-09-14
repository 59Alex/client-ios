import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectFeatures
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Поток heartbeat, отдающий заданные кадры и затем висящий до отмены.
private struct HeartbeatStream: EventStreamTransport {
    let frames: [String]

    func events(for request: URLRequest) -> AsyncThrowingStream<ServerSentEvent, any Error> {
        let frames = frames
        return AsyncThrowingStream { continuation in
            for frame in frames { continuation.yield(ServerSentEvent(data: frame)) }
        }
    }
}

private struct TokenSource: AccessTokenProvider {
    func validAccessToken() async -> String? { "token" }
    func handleUnauthorized() async {}
}

@Suite("Сессия устройства")
struct StatusServiceTests {
    @Test("кадр heartbeat разбирается, пустой id отбрасывается")
    func decode() {
        let event = HeartbeatEvent.decode(#"{"heartbeatId":"h1","expiresAt":"2030-01-01T00:00:00.000Z"}"#)
        #expect(event?.heartbeatId == "h1")
        #expect(event?.expiresAt != nil)
        #expect(HeartbeatEvent.decode(#"{"heartbeatId":""}"#) == nil)
    }

    @Test("на heartbeat уходит ack, expired пропускается, после подтверждения пульс не нужен")
    func acknowledgesAndSkipsPulse() async throws {
        let transport = StubTransport()
        transport.on("/api/status/login", json: #"{"sessionId":"s1"}"#)
        transport.on("/api/status/heartbeat/ack", json: "")
        transport.on("/api/status/heartbeat/pulse", json: "")
        let client = HTTPClient(baseURL: URL(string: "https://status.example")!, transport: transport, tokenProvider: TokenSource())
        let stream = HeartbeatStream(frames: [#"{"heartbeatId":"expired"}"#, #"{"heartbeatId":"h1","expiresAt":"2999-01-01T00:00:00Z"}"#])
        let service = StatusService(client: client, eventStream: stream, sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })

        let task = Task { await service.keepAlive(userId: "u1") }
        for _ in 0..<200 where transport.requests(to: "/api/status/heartbeat/ack").isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()

        let acks = transport.requests(to: "/api/status/heartbeat/ack")
        #expect(acks.count == 1)
        let body = String(decoding: try #require(acks.first?.httpBody), as: UTF8.self)
        #expect(body.contains(#""heartbeatId":"h1""#))
        #expect(body.contains(#""sessionId":"s1""#))
        let pulsesAfterAck = transport.requests.drop { $0.url?.path != "/api/status/heartbeat/ack" }.filter { $0.url?.path == "/api/status/heartbeat/pulse" }
        // Пульс, начатый одновременно с подтверждением, допустим; дальше за шесть интервалов новых нет.
        #expect(pulsesAfterAck.count <= 1)
        #expect(transport.requests(to: "/api/status/login").count == 1)
    }

    @Test("без heartbeat-потока сессию держит пульс")
    func pulseWithoutStream() async throws {
        let transport = StubTransport()
        transport.on("/api/status/login", json: #"{"sessionId":"s1"}"#)
        transport.on("/api/status/heartbeat/pulse", json: "")
        let client = HTTPClient(baseURL: URL(string: "https://status.example")!, transport: transport)
        let service = StatusService(client: client, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) })

        let task = Task { await service.keepAlive(userId: "u1") }
        for _ in 0..<200 where transport.requests(to: "/api/status/heartbeat/pulse").count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        #expect(transport.requests(to: "/api/status/heartbeat/pulse").count >= 2)
    }
}
