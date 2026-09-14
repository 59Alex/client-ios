import ConnectCalls
import Foundation

/// Отправляет итог звонка в чат так же, как веб-клиент: сообщение с `callInfo` и сигнал `chat`
/// через временную текстовую сессию, чтобы открытые чаты собеседников сразу его показали.
@MainActor
public final class CallSummaryPublisher {
    private let me: ChatUser
    private let api: any ChatAPI
    private let rtcUrl: URL
    private let makeRoom: @MainActor () -> any SignalRoom
    private let now: @Sendable () -> Date

    public init(me: ChatUser, api: any ChatAPI, rtcUrl: URL, makeRoom: @escaping @MainActor () -> any SignalRoom, now: @escaping @Sendable () -> Date = Date.init) {
        self.me = me
        self.api = api
        self.rtcUrl = rtcUrl
        self.makeRoom = makeRoom
        self.now = now
    }

    public func publish(_ report: CallSummaryReport) async {
        let kind: ChatKind = report.isGroup ? .group : .p2p
        let timestamp = Int64(now().timeIntervalSince1970 * 1000)
        let text = CallSummary.messageText(isGroup: report.isGroup, durationSeconds: report.durationSeconds, startedAt: report.startedAt)
        let outgoing = OutgoingMessage(userId: me.userId, roomId: report.roomId, message: text, dateTimeCreateTimestamp: timestamp, callInfo: true)
        guard let id = try? await api.send(kind, message: outgoing) else { return }

        let message = ChatMessage(id: id, clientMessageId: id, text: text, createdAtMilliseconds: timestamp, authorId: me.userId, username: me.username)
        let room = makeRoom()
        do {
            let token = try await api.textToken(kind, userId: me.userId, roomId: report.roomId)
            try await room.connect(url: rtcUrl, token: token)
            let client = String(decoding: (try? JSONEncoder().encode(["clientData": me.username])) ?? Data(), as: UTF8.self)
            try await room.send(ChatSignal.message(message).packet(client: client).encoded(), topic: CallProtocol.signalTopic)
        } catch {
            // Сообщение сохранено: собеседники увидят его при следующей синхронизации.
        }
        await room.disconnect()
    }
}
