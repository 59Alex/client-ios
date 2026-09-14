import ConnectNetworking
import Foundation
import Observation

/// Вход в звонок гостем по ссылке (`useGuestMeeting.ts`): без аккаунта, сессия в заголовке `X-Meeting-Session`.
public struct GuestMeetingJoin: Decodable, Sendable, Equatable {
    public let sessionToken: String
    public let guestId: String
    public let groupId: String
    public let callId: String
    public let name: String?
    public let voiceToken: String
    public let textToken: String?

    public init(sessionToken: String, guestId: String, groupId: String, callId: String, name: String?, voiceToken: String, textToken: String?) {
        self.sessionToken = sessionToken
        self.guestId = guestId
        self.groupId = groupId
        self.callId = callId
        self.name = name
        self.voiceToken = voiceToken
        self.textToken = textToken
    }
}

public struct GuestMeetingState: Decodable, Sendable, Equatable {
    public let active: Bool

    public init(active: Bool) {
        self.active = active
    }
}

public struct GuestMeetingMessage: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let message: String
    public let createdAt: String?
    public let guestId: String?
    public let displayName: String?

    public init(id: String, message: String, createdAt: String?, guestId: String?, displayName: String?) {
        self.id = id
        self.message = message
        self.createdAt = createdAt
        self.guestId = guestId
        self.displayName = displayName
    }
}

public protocol GuestMeetingAPI: Sendable {
    func preview(code: String) async throws -> String?
    func join(code: String, displayName: String, sessionToken: String?) async throws -> GuestMeetingJoin
    func heartbeat(sessionToken: String) async throws -> GuestMeetingState
    func leave(sessionToken: String) async
    func messages(sessionToken: String) async throws -> [GuestMeetingMessage]
    func send(message: String, sessionToken: String) async throws
}

/// Публичные адреса встреч: клиент без токена пользователя.
public struct RemoteGuestMeetingAPI: GuestMeetingAPI {
    private let client: HTTPClient

    public init(client: HTTPClient) {
        self.client = client
    }

    public func preview(code: String) async throws -> String? {
        let response = try await client.post("/api/meetings/preview", json: ["code": code])
        guard response.isSuccess else { throw MeetingError.from(status: response.statusCode, creating: false) }
        return (try? JSONDecoder().decode(Preview.self, from: response.body))?.name
    }

    public func join(code: String, displayName: String, sessionToken: String?) async throws -> GuestMeetingJoin {
        let response = try await client.post("/api/meetings/join", json: JoinBody(code: code, displayName: displayName, sessionToken: sessionToken))
        guard response.isSuccess else { throw MeetingError.from(status: response.statusCode, creating: false) }
        return try HTTPClient.decode(response)
    }

    public func heartbeat(sessionToken: String) async throws -> GuestMeetingState {
        let response = try await client.send(method: "POST", path: "/api/meetings/heartbeat", body: nil, headers: ["X-Meeting-Session": sessionToken])
        guard response.isSuccess else { throw MeetingError.from(status: response.statusCode, creating: false) }
        return try HTTPClient.decode(response)
    }

    public func leave(sessionToken: String) async {
        _ = try? await client.send(method: "POST", path: "/api/meetings/leave", body: nil, headers: ["X-Meeting-Session": sessionToken])
    }

    public func messages(sessionToken: String) async throws -> [GuestMeetingMessage] {
        let response = try await client.send(method: "GET", path: "/api/meetings/messages?page=0", body: nil, headers: ["X-Meeting-Session": sessionToken])
        guard response.isSuccess else { throw MeetingError.from(status: response.statusCode, creating: false) }
        return try HTTPClient.decode(response)
    }

    public func send(message: String, sessionToken: String) async throws {
        let body = try JSONEncoder().encode(MessageBody(message: message, clientMessageId: UUID().uuidString.lowercased()))
        let response = try await client.send(method: "POST", path: "/api/meetings/messages", body: body, headers: ["X-Meeting-Session": sessionToken])
        guard response.isSuccess else { throw MeetingError.from(status: response.statusCode, creating: false) }
    }

    private struct Preview: Decodable { let name: String? }

    private struct JoinBody: Encodable, Sendable {
        let code: String
        let displayName: String
        let sessionToken: String?
    }

    private struct MessageBody: Encodable, Sendable {
        let message: String
        let clientMessageId: String
    }
}

/// Гость в звонке: голосовая сессия, пульс раз в 10 с, сообщения чата встречи, выход.
@MainActor
@Observable
public final class GuestMeetingModel {
    public enum Phase: Sendable, Equatable {
        case idle
        case joining
        case active
        case ended(String)
    }

    public static let heartbeatInterval: Duration = .seconds(10)
    public static let maxNameLength = 80

    public private(set) var phase: Phase = .idle
    public private(set) var title = ""
    public private(set) var session: VoiceRoomSession?
    public private(set) var messages: [GuestMeetingMessage] = []
    public private(set) var guestId: String?
    public var draft = ""

    private let api: any GuestMeetingAPI
    private let rtcUrl: URL
    private let makeRoom: @MainActor () -> any CallRoom
    private let requestMicrophone: @MainActor () async -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void
    private var sessionToken: String?
    private var eventsTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    public init(api: any GuestMeetingAPI, rtcUrl: URL, makeRoom: @escaping @MainActor () -> any CallRoom, requestMicrophone: @escaping @MainActor () async -> Bool, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.api = api
        self.rtcUrl = rtcUrl
        self.makeRoom = makeRoom
        self.requestMicrophone = requestMicrophone
        self.sleep = sleep
    }

    public var isInMeeting: Bool { phase == .joining || phase == .active }

    /// Возвращает текст ошибки или `nil`, если вход начался.
    public func join(link: String, displayName: String) async -> String? {
        guard let code = MeetingLinks.code(from: link) else { return "Вставьте ссылку на встречу" }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Укажите, как вас называть" }
        guard name.count <= Self.maxNameLength, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return "Имя не длиннее \(Self.maxNameLength) символов"
        }
        phase = .joining
        do {
            let joined = try await api.join(code: code, displayName: name, sessionToken: nil)
            sessionToken = joined.sessionToken
            guestId = joined.guestId
            title = joined.name ?? "Встреча"
            let microphone = await requestMicrophone()
            let clientData = CallClientData(userId: joined.guestId, username: name, sessionId: nil).encoded()
            let voice = VoiceRoomSession(me: joined.guestId, clientData: clientData, room: makeRoom(), muted: !microphone)
            try await voice.connect(url: rtcUrl, token: joined.voiceToken)
            session = voice
            phase = .active
            startLoops(voice)
            return nil
        } catch let error as MeetingError {
            await finish(.ended(error.message))
            return error.message
        } catch {
            await finish(.ended("Не удалось подключиться к встрече"))
            return "Не удалось подключиться к встрече"
        }
    }

    public func toggleMute() async {
        guard let session else { return }
        await session.setMuted(!session.isMuted)
    }

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sessionToken else { return }
        draft = ""
        do {
            try await api.send(message: text, sessionToken: sessionToken)
            await refreshMessages()
        } catch {
            draft = text
        }
    }

    public func leave() async {
        await finish(.idle)
    }

    public func refreshMessages() async {
        guard let sessionToken, let fresh = try? await api.messages(sessionToken: sessionToken) else { return }
        messages = fresh
    }

    private func startLoops(_ voice: VoiceRoomSession) {
        eventsTask?.cancel()
        heartbeatTask?.cancel()
        let events = voice.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                if await voice.handle(event) {
                    await self.finish(.ended("Соединение со встречей потеряно"))
                    return
                }
            }
        }
        let api = api
        let sleep = sleep
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let token = self.sessionToken else { return }
                if let state = try? await api.heartbeat(sessionToken: token), !state.active {
                    await self.finish(.ended("Звонок завершён"))
                    return
                }
                await self.refreshMessages()
                do { try await sleep(Self.heartbeatInterval) } catch { return }
            }
        }
    }

    private func finish(_ next: Phase) async {
        eventsTask?.cancel()
        heartbeatTask?.cancel()
        eventsTask = nil
        heartbeatTask = nil
        let token = sessionToken
        sessionToken = nil
        let voice = session
        session = nil
        await voice?.disconnect()
        if let token { await api.leave(sessionToken: token) }
        phase = next
    }
}
