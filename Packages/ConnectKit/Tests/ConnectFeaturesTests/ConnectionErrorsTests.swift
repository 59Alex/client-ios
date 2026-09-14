import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectFeatures
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class ProbeStub: MediaServerProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
    func isReachable() async -> Bool { lock.withLock { value } }
}

@MainActor
@Suite("Ошибки подключения")
struct ConnectionErrorsTests {
    @Test("сбой красный, восстановление зелёное и исчезает, повторный сбой снова активен")
    func lifecycle() async throws {
        let model = ConnectionErrorsModel(probe: ProbeStub(true), sleep: { _ in })
        #expect(model.tone == .none)
        model.report(.microphone)
        model.report(.microphone)
        #expect(model.entries.count == 1)
        #expect(model.tone == .error)

        model.microphone(granted: true)
        #expect(model.tone == .resolved)
        for _ in 0..<100 where !model.entries.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.entries.isEmpty)

        model.resolve(.mediaServer)
        #expect(model.entries.isEmpty)
    }

    @Test("медиасервер: недоступен — сбой сервера; отвечает, но комната не открылась — сбой соединения")
    func mediaServer() async {
        let probe = ProbeStub(false)
        let model = ConnectionErrorsModel(probe: probe, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        #expect(await model.checkMediaServer() == false)
        #expect(model.entries.map(\.kind) == [.mediaServer])

        await model.reportMediaConnectionFailure()
        #expect(model.entries.map(\.kind) == [.mediaServer])

        probe.set(true)
        await model.reportMediaConnectionFailure()
        #expect(model.entries.first { $0.kind == .mediaServer }?.state == .resolved)
        #expect(model.entries.first { $0.kind == .mediaConnection }?.state == .active)
        #expect(model.tone == .error)

        model.dismiss(.mediaConnection)
        #expect(model.activeCount == 0)
        model.mediaConnected()
        #expect(model.tone == .resolved)
    }

    @Test("проба стучится в https-корень медиасервера, ошибка сети — недоступен")
    func probe() async {
        let transport = StubTransport()
        transport.on("/", json: "")
        let probe = HTTPMediaServerProbe(rtcUrl: URL(string: "wss://rtc.cnnect.ru/rtc")!, transport: transport)
        #expect(probe.probeURL.absoluteString == "https://rtc.cnnect.ru/")
        #expect(await probe.isReachable())

        struct Failing: HTTPTransport {
            func send(_ request: URLRequest) async throws -> HTTPResponse { throw URLError(.timedOut) }
        }
        #expect(await HTTPMediaServerProbe(rtcUrl: URL(string: "wss://rtc.cnnect.ru")!, transport: Failing()).isReachable() == false)
    }

    @Test("тексты веба и подписи кнопок")
    func texts() {
        #expect(ConnectionErrorKind.mediaServer.title == "Медиасервер недоступен")
        #expect(ConnectionErrorKind.mediaConnection.retryLabel == "Понятно")
        #expect(ConnectionErrorKind.microphone.resolvedTitle == "Микрофон доступен")
        #expect(ConnectionErrorsModel.isConnectionFailure("Не удалось подключиться к звонку"))
        #expect(!ConnectionErrorsModel.isConnectionFailure("Занят"))
    }
}
