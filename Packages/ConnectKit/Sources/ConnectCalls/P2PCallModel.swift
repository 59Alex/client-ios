import ConnectCore
import Foundation
import Observation

/// Участник звонка с нашей стороны.
public struct CallParticipant: Sendable, Equatable {
    public var userId: String
    public var name: String
    public var username: String

    public init(userId: String, name: String, username: String) {
        self.userId = userId
        self.name = name
        self.username = username
    }

    public init(_ contact: Contact) {
        self.init(userId: contact.userId, name: contact.displayName, username: contact.handle)
    }
}

/// Личный аудиозвонок, совместимый с `useP2pCall.ts` веб-клиента.
///
/// Вызывающий создаёт звонок, сразу входит в комнату и ждёт аудиопоток собеседника;
/// принимающий записывает время начала и входит в ту же комнату. Отдельного API
/// «принять» нет, завершение — `DELETE /api/p2pcall/delete` и уход из комнаты.
@MainActor
@Observable
public final class P2PCallModel {
    public enum Direction: Sendable, Equatable {
        case outgoing
        case incoming
    }

    public enum Phase: Sendable, Equatable {
        case idle
        /// Входящий вызов ждёт ответа.
        case incoming
        /// Микрофон, звонок и комната: «Соединение...».
        case connecting
        /// Мы в комнате, собеседника ещё нет: «Вызов...».
        case ringing
        case active(startedAt: Date)
        case reconnecting(startedAt: Date?)
        /// Звонок не состоялся; сообщение показывается, пока пользователь не закроет экран.
        case failed(String)
    }

    public static let connectAttempts = 3
    public static let connectBudget: TimeInterval = 15
    /// После отказа тот же вызов повторно не показывается, пока сервис не догонит состояние.
    public static let declineCooldown: TimeInterval = 5

    public private(set) var phase: Phase = .idle
    public private(set) var direction: Direction?
    public private(set) var peer: CallParticipant?
    public private(set) var isMuted = false
    public private(set) var isSpeakerOn = false
    public private(set) var isRemoteMuted = false
    public private(set) var isRemoteSpeaking = false

    private let me: CallParticipant
    private let api: any P2PCallAPI
    private let rtcUrl: URL
    private let makeRoom: @MainActor () -> any CallRoom
    private let sessionId: @Sendable () async -> String?
    private let requestMicrophone: @MainActor () async -> Bool
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    private var generation = 0
    private var callId: String?
    private var callerUserId: String?
    private var room: (any CallRoom)?
    private var roomEvents: Task<Void, Never>?
    private var tracker = RemoteStreamTracker()
    private var remoteAudioStream: RemoteCallStream?
    private var localSpeaking = false
    private var cancelledCallIds: Set<String> = []
    private var declinedUntil: [String: Date] = [:]
    private var acceptedAt: Date?
    private var trackKey = UUID().uuidString.lowercased()

    public init(
        me: CallParticipant,
        api: any P2PCallAPI,
        rtcUrl: URL,
        makeRoom: @escaping @MainActor () -> any CallRoom,
        sessionId: @escaping @Sendable () async -> String?,
        requestMicrophone: @escaping @MainActor () async -> Bool,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.me = me
        self.api = api
        self.rtcUrl = rtcUrl
        self.makeRoom = makeRoom
        self.sessionId = sessionId
        self.requestMicrophone = requestMicrophone
        self.now = now
        self.sleep = sleep
    }

    public var isInCall: Bool { phase != .idle }

    public var statusText: String {
        switch phase {
        case .idle: ""
        case .incoming: "Входящий звонок"
        case .connecting: "Соединение..."
        case .ringing: "Вызов..."
        case .active: "Вызов активен"
        case .reconnecting: "Переподключение..."
        case let .failed(message): message
        }
    }

    // MARK: - Исходящий

    public func call(_ contact: Contact) async {
        guard phase == .idle || isFailed else { return }
        let peer = CallParticipant(contact)
        let generation = begin(direction: .outgoing, peer: peer)
        phase = .connecting

        guard await requestMicrophone() else {
            fail("Разрешите доступ к микрофону в настройках, чтобы позвонить")
            return
        }
        guard isCurrent(generation) else { return }

        do {
            let roomId = try await api.roomId(userId: me.userId, peerUserId: peer.userId)
            let session = await sessionId()
            guard isCurrent(generation) else { return }

            let id: String
            do {
                id = try await api.createCall(callerUserId: me.userId, calleeUserId: peer.userId, sessionId: session)
            } catch P2PCallAPIError.busy {
                if isCurrent(generation) { fail("Занят") }
                return
            }
            guard isCurrent(generation) else {
                // Пользователь положил трубку, пока создавался звонок.
                try? await api.deleteCall(callerUserId: me.userId, calleeUserId: peer.userId, callId: id, sessionId: session)
                return
            }
            callId = id
            if cancelledCallIds.remove(id) != nil {
                await finish(notifyServer: true)
                return
            }

            try await connect(roomId: roomId, sessionId: session, generation: generation)
            if isCurrent(generation), phase == .connecting {
                phase = .ringing
            }
        } catch {
            guard isCurrent(generation) else { return }
            await dropCall(message: "Не удалось подключиться к звонку")
        }
    }

    // MARK: - Входящий

    /// Слушает события звонков, пока задача не отменена; обрывы потока переподключаются.
    public func runIncomingCalls() async {
        var delay = 1.5
        while !Task.isCancelled {
            if let pending = try? await api.incomingCall(calleeUserId: me.userId) {
                await handle(pending)
            }
            do {
                for try await event in api.events(userId: me.userId) {
                    delay = 1.5
                    await handle(event)
                }
            } catch {
                // Переподключение ниже.
            }
            do {
                try await sleep(.milliseconds(Int(delay * 1000)))
            } catch {
                return
            }
            delay = min(delay * 1.6, 10)
        }
    }

    public func handle(_ event: P2PCallEvent) async {
        switch event {
        case let .call(id, caller, callee):
            guard callee == me.userId, caller != me.userId else { return }
            await receiveCall(callId: id, callerUserId: caller)
        case let .cancel(id, caller, callee):
            guard caller == me.userId || callee == me.userId else { return }
            await receiveCancel(callId: id, callerUserId: caller, calleeUserId: callee)
        }
    }

    public func accept() async {
        guard phase == .incoming, let callId, let peer else { return }
        let generation = self.generation
        phase = .connecting

        guard await requestMicrophone() else {
            await dropCall(message: "Разрешите доступ к микрофону в настройках, чтобы ответить")
            return
        }
        guard isCurrent(generation) else { return }

        do {
            let roomId = try await api.roomId(userId: me.userId, peerUserId: peer.userId)
            let session = await sessionId()
            let startedAt = now()
            acceptedAt = startedAt
            // Время начала пишется до входа: по нему вызывающий запускает таймер.
            try? await api.setCallTime(callId: callId, time: startedAt, sessionId: session)
            guard isCurrent(generation) else { return }
            try await connect(roomId: roomId, sessionId: session, generation: generation)
            if isCurrent(generation), phase == .connecting {
                phase = .ringing
            }
        } catch {
            guard isCurrent(generation) else { return }
            await dropCall(message: "Не удалось подключиться к звонку")
        }
    }

    public func decline() async {
        guard phase == .incoming, let peer else { return }
        declinedUntil[peer.userId] = now().addingTimeInterval(Self.declineCooldown)
        await finish(notifyServer: true)
    }

    // MARK: - Управление

    public func hangUp() async {
        guard phase != .idle else { return }
        if isFailed {
            reset()
            return
        }
        await finish(notifyServer: true)
    }

    public func toggleMute() async {
        isMuted.toggle()
        try? await room?.setMicrophoneMuted(isMuted)
        if isMuted { await updateLocalSpeaking(false) }
        await send(.microphoneMuted(userId: me.userId, muted: isMuted))
    }

    public func toggleSpeaker() {
        isSpeakerOn.toggle()
        room?.setSpeakerOutput(isSpeakerOn)
    }

    // MARK: - Комната

    private func connect(roomId: String, sessionId: String?, generation: Int) async throws {
        let deadline = now().addingTimeInterval(Self.connectBudget)
        for attempt in 0..<Self.connectAttempts {
            do {
                let token = try await api.connectionToken(userId: me.userId, roomId: roomId)
                guard isCurrent(generation) else { return }
                let room = makeRoom()
                self.room = room
                listen(to: room, generation: generation)
                room.setSpeakerOutput(isSpeakerOn)
                try await room.connect(url: rtcUrl, token: token)
                guard isCurrent(generation) else { return }

                let name = TrackName(
                    key: trackKey,
                    clientData: clientData(sessionId: sessionId),
                    createdAtMilliseconds: Int64(now().timeIntervalSince1970 * 1000),
                    hasAudio: true,
                    hasVideo: false
                )
                try await room.publishMicrophone(trackName: name.encoded(), muted: isMuted)
                self.clientDataString = name.clientData
                await send(.microphoneMuted(userId: me.userId, muted: isMuted))
                await send(.speakerOff(userId: me.userId, muted: false))
                return
            } catch {
                await closeRoom()
                let outOfBudget = now() >= deadline
                if attempt == Self.connectAttempts - 1 || outOfBudget || !isCurrent(generation) {
                    throw error
                }
                try await sleep(.milliseconds(300 * (attempt + 1)))
            }
        }
    }

    private var clientDataString = ""

    private func clientData(sessionId: String?) -> String {
        CallClientData(userId: me.userId, username: me.username, sessionId: sessionId).encoded()
    }

    private func listen(to room: any CallRoom, generation: Int) {
        roomEvents?.cancel()
        tracker = RemoteStreamTracker()
        let events = room.events
        roomEvents = Task { [weak self] in
            for await event in events {
                guard let self, self.isCurrent(generation) else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: CallRoomEvent) async {
        for change in tracker.handle(event) {
            switch change {
            case let .added(stream):
                guard stream.hasAudio, !stream.hasVideo, stream.clientData?.userId != me.userId else { continue }
                remoteAudioStream = stream
                await peerJoined()
            case let .removed(stream):
                guard stream == remoteAudioStream else { continue }
                remoteAudioStream = nil
                // Собеседник снял аудиопоток — так веб-клиент кладёт трубку.
                await finish(notifyServer: true)
                return
            }
        }

        switch event {
        case let .data(topic, payload):
            guard topic == CallProtocol.signalTopic, let packet = SignalPacket.decode(payload), let signal = CallSignal(packet: packet) else { return }
            guard signal.userId != me.userId else { return }
            switch signal {
            case let .microphoneMuted(_, muted):
                isRemoteMuted = muted
                if muted { isRemoteSpeaking = false }
            case let .speaking(_, speaking):
                isRemoteSpeaking = speaking && !isRemoteMuted
            case .speakerOff:
                break
            }
        case let .localSpeakingChanged(speaking):
            await updateLocalSpeaking(speaking && !isMuted)
        case .reconnecting:
            if case let .active(startedAt) = phase {
                phase = .reconnecting(startedAt: startedAt)
            } else if phase == .ringing {
                phase = .reconnecting(startedAt: nil)
            }
        case .reconnected:
            if case let .reconnecting(startedAt) = phase {
                phase = startedAt.map { .active(startedAt: $0) } ?? .ringing
            }
        case .disconnected:
            await finish(notifyServer: true)
        default:
            break
        }
    }

    private func peerJoined() async {
        switch phase {
        case .connecting, .ringing, .reconnecting(startedAt: nil):
            break
        default:
            return
        }
        let generation = self.generation
        let startedAt = await callStartTime()
        guard isCurrent(generation) else { return }
        phase = .active(startedAt: startedAt)
    }

    /// Время начала из outbox, как у вызывающего в веб-клиенте; иначе локальные часы.
    private func callStartTime() async -> Date {
        if direction == .incoming, let acceptedAt { return acceptedAt }
        guard let callId else { return now() }
        for attempt in 0..<5 {
            if let time = try? await api.callTime(callId: callId) { return time }
            if attempt < 4 { try? await sleep(.milliseconds(200)) }
        }
        return now()
    }

    private func updateLocalSpeaking(_ speaking: Bool) async {
        guard localSpeaking != speaking else { return }
        localSpeaking = speaking
        await send(.speaking(userId: me.userId, speaking: speaking))
    }

    private func send(_ signal: CallSignal) async {
        guard let room, !clientDataString.isEmpty else { return }
        try? await room.send(signal.packet(client: clientDataString).encoded(), topic: CallProtocol.signalTopic)
    }

    // MARK: - События сервиса

    private func receiveCall(callId: String?, callerUserId: String) async {
        if let until = declinedUntil[callerUserId], until > now() { return }

        var callId = callId
        if callId == nil, case let .call(foundId, foundCaller, _)? = try? await api.incomingCall(calleeUserId: me.userId), foundCaller == callerUserId {
            callId = foundId
        }
        guard let callId else { return }
        if self.callId == callId { return }

        guard phase == .idle || isFailed else {
            // Уже разговариваем — отклоняем, как веб-клиент в групповом звонке.
            let session = await sessionId()
            try? await api.deleteCall(callerUserId: callerUserId, calleeUserId: me.userId, callId: callId, sessionId: session)
            return
        }

        let generation = begin(direction: .incoming, peer: CallParticipant(userId: callerUserId, name: "", username: ""))
        self.callId = callId
        self.callerUserId = callerUserId
        phase = .incoming

        if let contact = try? await api.contact(userId: callerUserId), isCurrent(generation) {
            peer = CallParticipant(contact)
        }
    }

    private func receiveCancel(callId: String?, callerUserId: String, calleeUserId: String) async {
        let peerUserId = callerUserId == me.userId ? calleeUserId : callerUserId
        guard phase != .idle, !isFailed, peer?.userId == peerUserId else { return }

        guard let current = self.callId else {
            // Отмена пришла раньше ответа на создание звонка.
            if let callId { cancelledCallIds.insert(callId) }
            return
        }
        guard callId == nil || callId == current else { return }
        await finish(notifyServer: false)
    }

    // MARK: - Завершение

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation
    }

    private func begin(direction: Direction, peer: CallParticipant) -> Int {
        reset()
        self.direction = direction
        self.peer = peer
        callerUserId = direction == .outgoing ? me.userId : peer.userId
        return generation
    }

    private func fail(_ message: String) {
        let peer = peer
        let direction = direction
        reset()
        self.peer = peer
        self.direction = direction
        phase = .failed(message)
    }

    private func dropCall(message: String) async {
        await deleteCurrentCall()
        await closeRoom()
        fail(message)
    }

    private func finish(notifyServer: Bool) async {
        if notifyServer { await deleteCurrentCall() }
        await closeRoom()
        reset()
    }

    private func deleteCurrentCall() async {
        guard let callId, let peer, let callerUserId else { return }
        let callee = callerUserId == me.userId ? peer.userId : me.userId
        let session = await sessionId()
        try? await api.deleteCall(callerUserId: callerUserId, calleeUserId: callee, callId: callId, sessionId: session)
    }

    private func closeRoom() async {
        roomEvents?.cancel()
        roomEvents = nil
        let room = room
        self.room = nil
        await room?.disconnect()
    }

    /// Сбрасывает состояние и делает устаревшими все незавершённые операции прошлого звонка.
    private func reset() {
        generation += 1
        roomEvents?.cancel()
        roomEvents = nil
        if let room {
            self.room = nil
            Task { await room.disconnect() }
        }
        phase = .idle
        direction = nil
        peer = nil
        callId = nil
        callerUserId = nil
        acceptedAt = nil
        remoteAudioStream = nil
        tracker = RemoteStreamTracker()
        isMuted = false
        isRemoteMuted = false
        isRemoteSpeaking = false
        localSpeaking = false
        clientDataString = ""
        trackKey = UUID().uuidString.lowercased()
    }
}
