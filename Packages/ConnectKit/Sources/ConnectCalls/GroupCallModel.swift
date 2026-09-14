import Foundation
import Observation

/// Групповой звонок (`useGroupCall.ts`): вызов участников группы, входящий, вход в идущий звонок.
@MainActor
@Observable
public final class GroupCallModel {
    public enum Phase: Sendable, Equatable {
        case idle
        case incoming
        case connecting
        case active(startedAt: Date)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var callId: String?
    public private(set) var groupChatId: String?
    /// Ссылка для гостей, пока идёт этот звонок.
    public private(set) var guestLink: String?
    public private(set) var guestLinkError: String?

    /// Ведущий создаёт гостевую ссылку (`MeetingInviteButton.tsx`); права проверяет сервер.
    public func createGuestLink(api meetings: any MeetingsAPI, origin: URL) async {
        guard let callId, let groupChatId else { return }
        do {
            let invitation = try await meetings.createInvitation(groupId: groupChatId, callId: callId)
            guestLink = MeetingLinks.url(origin: origin, code: invitation.code).absoluteString
            guestLinkError = nil
        } catch let error as MeetingError {
            guestLinkError = error.message
        } catch {
            guestLinkError = MeetingError.other.message
        }
    }

    /// Своя камера отдельным подключением к комнате группового звонка.
    public let camera: CameraShare
    public private(set) var title = ""
    public private(set) var callerUserId: String?
    public private(set) var session: VoiceRoomSession?
    public private(set) var rosterUserIds: [String] = []
    public private(set) var pendingUserIds: [String] = []
    public private(set) var declinedUserIds: [String] = []

    private let me: CallParticipant
    private let api: any GroupCallAPI
    private let rtcUrl: URL
    private let makeRoom: @MainActor () -> any CallRoom
    private let sessionId: @Sendable () async -> String?
    private let requestMicrophone: @MainActor () async -> Bool
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var generation = 0
    private var roomEvents: Task<Void, Never>?
    private var callEvents: Task<Void, Never>?
    private var someoneJoined = false
    /// Занят ли пользователь личным звонком или голосовым каналом.
    public var isBusyElsewhere: @MainActor () -> Bool = { false }
    /// Итог звонка отправляет последний вышедший участник.
    public var onCallSummary: (@MainActor (CallSummaryReport) async -> Void)?

    public init(
        me: CallParticipant,
        api: any GroupCallAPI,
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
        camera = CameraShare(makeRoom: makeRoom, rtcUrl: rtcUrl, now: now)
        self.sleep = sleep
    }

    public var isInCall: Bool { phase != .idle }

    /// Участники для плиток: из состава звонка и из голосовых потоков.
    public var participants: [VoiceParticipant] {
        var result = session?.participants ?? []
        for userId in rosterUserIds where userId != me.userId && !result.contains(where: { $0.userId == userId }) {
            result.append(VoiceParticipant(userId: userId))
        }
        return result
    }

    // MARK: - Исходящий

    /// Звонок в группу: вызываются все участники, кроме себя; пустой список — «комната», где хост один.
    /// Участники последнего исходящего вызова: по ним «Позвонить снова» повторяет звонок в группу.
    private var lastMemberUserIds: [String] = []

    public var canCallAgain: Bool {
        if case .failed = phase { return groupChatId != nil && !lastMemberUserIds.isEmpty }
        return false
    }

    public func callAgain() async {
        guard canCallAgain, let groupChatId else { return }
        let members = lastMemberUserIds
        let name = title
        await hangUp()
        await start(groupChatId: groupChatId, name: name, memberUserIds: members)
    }

    public func start(groupChatId: String, name: String, memberUserIds: [String]) async {
        lastMemberUserIds = memberUserIds
        guard phase == .idle || isFailed else { return }
        let generation = begin(chatId: groupChatId, title: name)
        callerUserId = me.userId
        phase = .connecting
        guard await requestMicrophone() else {
            fail("Разрешите доступ к микрофону в настройках, чтобы позвонить")
            return
        }
        let session = await sessionId()
        do {
            let callees = memberUserIds.filter { $0 != me.userId }
            let id = try await api.createCall(callerUserId: me.userId, groupChatId: groupChatId, name: name, calleeUserIds: callees, sessionId: session)
            guard isCurrent(generation) else {
                try? await api.deleteCall(callId: id, sessionId: session)
                return
            }
            callId = id
            pendingUserIds = callees
            do {
                try await connect(callId: id, sessionId: session, generation: generation)
            } catch {
                try? await api.deleteCall(callId: id, sessionId: session)
                if isCurrent(generation) { fail("Не удалось подключиться к звонку") }
                return
            }
            watchCall(id, generation: generation)
            await refreshRoster()
        } catch GroupCallAPIError.busy {
            if isCurrent(generation) { fail("Занят") }
        } catch {
            if isCurrent(generation) { fail("Не удалось начать звонок") }
        }
    }

    // MARK: - Входящий и вход в идущий

    public func runIncomingCalls() async {
        var delay = 1.5
        while !Task.isCancelled {
            if let pending = try? await api.incomingCall(calleeUserId: me.userId) {
                await receive(pending)
            }
            do {
                for try await event in api.events(userId: me.userId) {
                    delay = 1.5
                    await handle(event)
                }
            } catch {}
            do { try await sleep(.milliseconds(Int(delay * 1000))) } catch { return }
            delay = min(delay * 1.6, 10)
        }
    }

    public func handle(_ event: GroupCallEvent) async {
        switch event.kind {
        case .call:
            guard event.calleeUserId == me.userId, event.callerUserId != me.userId else { return }
            if let record = try? await api.call(id: event.groupCallId) {
                await receive(record)
            }
        case .cancel:
            if event.calleeUserId == me.userId, event.groupCallId == callId, phase == .incoming {
                reset()
            }
        case .finish:
            if event.groupCallId == callId { await closeLocally() }
        case .join, .hangup:
            break
        }
    }

    private func receive(_ record: GroupCallRecord) async {
        guard record.callerUserId != me.userId else { return }
        let invited = record.callees.isEmpty || record.callees.contains { $0.userId == me.userId && !$0.canceled }
        guard invited else { return }
        guard (phase == .idle || isFailed), !isBusyElsewhere() else {
            if record.id != callId {
                try? await api.decline(callId: record.id, userId: me.userId, sessionId: await sessionId())
            }
            return
        }
        _ = begin(chatId: record.groupChatId, title: record.name)
        callId = record.id
        callerUserId = record.callerUserId
        apply(record)
        phase = .incoming
    }

    public func accept() async {
        guard phase == .incoming, let callId, let groupChatId else { return }
        await join(callId: callId, groupChatId: groupChatId, title: title)
    }

    /// Вход в уже идущий звонок группы (баннер в чате).
    public func join(callId: String, groupChatId: String, title: String) async {
        lastMemberUserIds = []
        guard phase == .idle || phase == .incoming || isFailed else { return }
        let generation = phase == .incoming ? self.generation : begin(chatId: groupChatId, title: title)
        self.callId = callId
        phase = .connecting
        guard await requestMicrophone() else {
            fail("Разрешите доступ к микрофону в настройках, чтобы ответить")
            return
        }
        let session = await sessionId()
        do {
            try await joinWithRetry(callId: callId, sessionId: session)
            guard isCurrent(generation) else { return }
            try await connect(callId: callId, sessionId: session, generation: generation)
        } catch {
            _ = try? await api.leave(callId: callId, userId: me.userId, sessionId: session)
            if isCurrent(generation) { fail("Не удалось подключиться к звонку") }
            return
        }
        watchCall(callId, generation: generation)
        await refreshRoster()
    }

    public func decline() async {
        guard phase == .incoming, let callId else { return }
        try? await api.decline(callId: callId, userId: me.userId, sessionId: await sessionId())
        reset()
    }

    // MARK: - Управление

    public func hangUp() async {
        guard phase != .idle else { return }
        if isFailed || phase == .incoming {
            if phase == .incoming { await decline() } else { reset() }
            return
        }
        if let callId {
            let session = await sessionId()
            // Хост, до которого никто не дошёл, удаляет звонок целиком.
            if callerUserId == me.userId, !someoneJoined, participants.isEmpty {
                try? await api.deleteCall(callId: callId, sessionId: session)
            } else if (try? await api.leave(callId: callId, userId: me.userId, sessionId: session)) == true,
                      case let .active(startedAt) = phase, let groupChatId {
                let report = CallSummaryReport(isGroup: true, roomId: groupChatId, durationSeconds: max(1, Int(now().timeIntervalSince(startedAt))), startedAt: startedAt)
                await closeLocally()
                await onCallSummary?(report)
                return
            }
        }
        await closeLocally()
    }

    public func toggleMute() async {
        guard let session else { return }
        await session.setMuted(!session.isMuted)
    }

    public func toggleSpeakerOff() async {
        guard let session else { return }
        await session.setSpeakerOff(!session.isSpeakerOff)
    }

    // MARK: - Внутреннее

    private func connect(callId: String, sessionId: String?, generation: Int) async throws {
        guard let groupChatId else { return }
        let token = try await api.token(userId: me.userId, groupChatId: groupChatId, callId: callId)
        guard isCurrent(generation) else { return }
        let clientData = CallClientData(userId: me.userId, username: me.username, sessionId: sessionId).encoded()
        let voice = VoiceRoomSession(me: me.userId, clientData: clientData, room: makeRoom(), muted: false, now: now)
        self.session = voice
        listen(voice, generation: generation)
        try await voice.connect(url: rtcUrl, token: token)
        guard isCurrent(generation) else {
            await voice.disconnect()
            return
        }
        phase = .active(startedAt: now())
    }

    private func joinWithRetry(callId: String, sessionId: String?) async throws {
        for attempt in 0..<4 {
            do {
                try await api.join(callId: callId, userId: me.userId, sessionId: sessionId)
                return
            } catch GroupCallAPIError.busy where attempt < 3 {
                // Висит прежнее участие этой сессии: выходим и пробуем снова (200/400/600 мс).
                _ = try? await api.leave(callId: callId, userId: me.userId, sessionId: sessionId)
                try await sleep(.milliseconds(200 * (attempt + 1)))
            }
        }
    }

    private func listen(_ voice: VoiceRoomSession, generation: Int) {
        roomEvents?.cancel()
        let events = voice.events
        roomEvents = Task { [weak self] in
            for await event in events {
                guard let self, self.isCurrent(generation) else { return }
                if await voice.handle(event) {
                    await self.closeLocally()
                    return
                }
                if !voice.participants.isEmpty { self.someoneJoined = true }
            }
        }
    }

    private func watchCall(_ callId: String, generation: Int) {
        callEvents?.cancel()
        let api = api
        callEvents = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    for try await event in api.callEvents(callId: callId) {
                        guard let self, self.isCurrent(generation) else { return }
                        await self.handleCallEvent(event)
                    }
                } catch {}
                guard let self, self.isCurrent(generation) else { return }
                try? await self.sleep(.seconds(2))
            }
        }
    }

    private func handleCallEvent(_ event: GroupCallEvent) async {
        let userId = event.participantUserId ?? event.calleeUserId
        switch event.kind {
        case .join:
            if let userId, userId != me.userId {
                someoneJoined = true
                pendingUserIds.removeAll { $0 == userId }
                declinedUserIds.removeAll { $0 == userId }
                if !rosterUserIds.contains(userId) { rosterUserIds.append(userId) }
            }
            await refreshRoster()
        case .hangup:
            if let userId { rosterUserIds.removeAll { $0 == userId } }
            await abandonIfNobodyCame()
        case .cancel:
            if let userId, userId != me.userId {
                pendingUserIds.removeAll { $0 == userId }
                if !declinedUserIds.contains(userId) { declinedUserIds.append(userId) }
                await abandonIfNobodyCame()
            } else if userId == me.userId {
                await closeLocally()
            }
        case .finish:
            await closeLocally()
        case .call:
            break
        }
    }

    /// Все вызванные отказались, а никто так и не вошёл — хост удаляет звонок.
    private func abandonIfNobodyCame() async {
        guard callerUserId == me.userId, !someoneJoined, pendingUserIds.isEmpty, participants.isEmpty, let callId else { return }
        try? await api.deleteCall(callId: callId, sessionId: await sessionId())
        await closeLocally()
    }

    private func refreshRoster() async {
        guard let callId, let record = try? await api.call(id: callId) else { return }
        apply(record)
    }

    private func apply(_ record: GroupCallRecord) {
        if !record.name.isEmpty { title = record.name }
        rosterUserIds = record.participantUserIds.filter { $0 != me.userId }
        pendingUserIds = record.pendingCallees(excluding: me.userId).filter { !rosterUserIds.contains($0) }
        declinedUserIds = record.declinedCallees(excluding: me.userId)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func isCurrent(_ generation: Int) -> Bool { self.generation == generation }

    private func begin(chatId: String, title: String) -> Int {
        reset()
        groupChatId = chatId
        self.title = title
        return generation
    }

    private func fail(_ message: String) {
        let chat = groupChatId
        let title = title
        reset()
        groupChatId = chat
        self.title = title
        phase = .failed(message)
    }

    private func closeLocally() async {
        let voice = session
        reset()
        await voice?.disconnect()
    }

    /// Камера в групповом звонке: после публикации участники узнают о ней сигналом `publish_stream`.
    public func toggleCamera() async {
        if camera.isActive {
            await camera.stop()
            return
        }
        guard let callId, let groupChatId, let session else { return }
        let api = api
        let me = me
        let started = await camera.start(token: { try await api.token(userId: me.userId, groupChatId: groupChatId, callId: callId) }) { streamId in
            CallClientData(userId: me.userId, username: me.username, sessionId: nil, streamType: "SHARE", streamId: streamId, shareType: RemoteShare.Kind.camera.rawValue).encoded()
        }
        if started, let streamId = camera.streamId {
            await session.announceStream(streamId: streamId)
        }
    }

    private func reset() {
        generation += 1
        let camera = camera
        Task { await camera.stop() }
        roomEvents?.cancel()
        callEvents?.cancel()
        roomEvents = nil
        callEvents = nil
        if let session {
            self.session = nil
            Task { await session.disconnect() }
        }
        phase = .idle
        callId = nil
        groupChatId = nil
        guestLink = nil
        guestLinkError = nil
        callerUserId = nil
        title = ""
        rosterUserIds = []
        pendingUserIds = []
        declinedUserIds = []
        someoneJoined = false
    }
}
