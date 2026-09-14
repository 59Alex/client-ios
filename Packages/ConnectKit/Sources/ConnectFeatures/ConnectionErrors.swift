import ConnectNetworking
import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Сбои, о которых сообщает панель ошибок веб-клиента (`features/errors/connectionErrors.ts`).
public enum ConnectionErrorKind: String, Sendable, CaseIterable, Identifiable {
    case mediaServer = "media-server"
    case mediaConnection = "media-connection"
    case microphone

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mediaServer: "Медиасервер недоступен"
        case .mediaConnection: "Не удалось подключиться к медиасерверу"
        case .microphone: "Нет доступа к микрофону"
        }
    }

    public var description: String {
        switch self {
        case .mediaServer:
            "Звонки и сообщения в чатах могут не работать. Если включён VPN или прокси, попробуйте отключить его или добавить cnnect.ru в исключения."
        case .mediaConnection:
            "Сервер отвечает, но соединение для звонка или чата не установилось. Звонки и сообщения в чатах могут не работать. Часто мешает VPN или прокси: отключите его или добавьте cnnect.ru в исключения и попробуйте снова."
        case .microphone:
            "Вы можете слушать звонок. Разрешите Connect доступ к микрофону в настройках iPhone и попробуйте снова."
        }
    }

    public var resolvedTitle: String {
        switch self {
        case .mediaServer: "Медиасервер снова доступен"
        case .mediaConnection: "Подключение к медиасерверу восстановлено"
        case .microphone: "Микрофон доступен"
        }
    }

    public var retryLabel: String {
        switch self {
        case .mediaServer: "Повторить"
        case .mediaConnection: "Понятно"
        case .microphone: "Открыть настройки"
        }
    }
}

public struct ConnectionErrorEntry: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case active
        /// Доступ восстановлен: запись догорает зелёным и пропадает.
        case resolved
    }

    public let kind: ConnectionErrorKind
    public var state: State
    public var retrying: Bool

    public var id: ConnectionErrorKind { kind }
}

/// Проверка медиасервера: корень OpenVidu 3 отвечает по HTTP, достаточно любого ответа.
public protocol MediaServerProbe: Sendable {
    func isReachable() async -> Bool
}

public struct HTTPMediaServerProbe: MediaServerProbe {
    public static let timeout: TimeInterval = 4

    private let url: URL
    private let transport: any HTTPTransport

    /// `rtcUrl` — адрес медиасервера (`wss://…`), проверяется `https://…/`.
    public init(rtcUrl: URL, transport: any HTTPTransport) {
        var components = URLComponents(url: rtcUrl, resolvingAgainstBaseURL: false)
        components?.scheme = rtcUrl.scheme == "ws" ? "http" : "https"
        components?.path = "/"
        url = components?.url ?? rtcUrl
        self.transport = transport
    }

    public var probeURL: URL { url }

    public func isReachable() async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        return (try? await transport.send(request)) != nil
    }
}

/// Панель ошибок подключения: красная, пока есть активные сбои, зелёная, пока догорают восстановленные.
@MainActor
@Observable
public final class ConnectionErrorsModel {
    public enum Tone: Sendable, Equatable {
        case none, error, resolved
    }

    public static let resolvedLinger: Duration = .seconds(4)

    public private(set) var entries: [ConnectionErrorEntry] = []

    private let probe: any MediaServerProbe
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(probe: any MediaServerProbe, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.probe = probe
        self.sleep = sleep
    }

    public var tone: Tone {
        if entries.isEmpty { return .none }
        return entries.contains { $0.state == .active } ? .error : .resolved
    }

    public var activeCount: Int { entries.filter { $0.state == .active }.count }

    public func report(_ kind: ConnectionErrorKind) {
        if let index = entries.firstIndex(where: { $0.kind == kind }) {
            entries[index].state = .active
            entries[index].retrying = false
        } else {
            entries.append(ConnectionErrorEntry(kind: kind, state: .active, retrying: false))
        }
    }

    /// Восстановление видно только для уже показанного сбоя; через несколько секунд запись исчезает.
    public func resolve(_ kind: ConnectionErrorKind) {
        guard let index = entries.firstIndex(where: { $0.kind == kind }), entries[index].state == .active else { return }
        entries[index].state = .resolved
        entries[index].retrying = false
        let sleep = sleep
        Task { [weak self] in
            try? await sleep(Self.resolvedLinger)
            self?.forget(kind)
        }
    }

    public func forget(_ kind: ConnectionErrorKind) {
        entries.removeAll { $0.kind == kind && $0.state == .resolved }
    }

    /// «Понятно» закрывает сбой соединения без проверки.
    public func dismiss(_ kind: ConnectionErrorKind) {
        entries.removeAll { $0.kind == kind }
    }

    /// Проверка при входе и по «Повторить»: результат попадает в панель.
    @discardableResult
    public func checkMediaServer() async -> Bool {
        setRetrying(.mediaServer, true)
        let reachable = await probe.isReachable()
        if reachable {
            resolve(.mediaServer)
        } else {
            report(.mediaServer)
        }
        return reachable
    }

    /// Не удалось войти в комнату: если сервер отвечает по HTTP, соединение режет сеть клиента.
    public func reportMediaConnectionFailure() async {
        if await checkMediaServer() {
            report(.mediaConnection)
        }
    }

    /// Успешный вход в комнату снимает оба сбоя медиасервера.
    public func mediaConnected() {
        resolve(.mediaServer)
        resolve(.mediaConnection)
    }

    /// Сообщение сбоя звонка о соединении, а не о занятости или отказе собеседника.
    public nonisolated static func isConnectionFailure(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("подключиться")
    }

    public func microphone(granted: Bool) {
        if granted { resolve(.microphone) } else { report(.microphone) }
    }

    private func setRetrying(_ kind: ConnectionErrorKind, _ retrying: Bool) {
        guard let index = entries.firstIndex(where: { $0.kind == kind }) else { return }
        entries[index].retrying = retrying
    }
}
