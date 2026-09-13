import Foundation

/// Протокол комнаты поверх LiveKit, общий с фасадом `connect-ui/src/calls/rtc/openvidu.ts`.
/// Веб-клиент видит только дорожки с JSON-именем и понимает сигналы в топике `ov-signal`.
public enum CallProtocol {
    public static let signalTopic = "ov-signal"
    /// Надёжный data-канал ограничен ~15 КиБ; крупнее — текстовым потоком.
    public static let maxDataPacketBytes = 14_000
}

/// Имя дорожки: все дорожки одного «потока» OpenVidu несут одинаковое имя.
/// `k` — ключ потока, `c` — клиентские данные, `t` — время создания (мс), `a`/`v` — есть ли звук и видео.
public struct TrackName: Codable, Sendable, Equatable {
    public var key: String
    public var clientData: String
    public var createdAtMilliseconds: Int64
    public var hasAudio: Bool
    public var hasVideo: Bool

    public init(key: String, clientData: String, createdAtMilliseconds: Int64, hasAudio: Bool, hasVideo: Bool) {
        self.key = key
        self.clientData = clientData
        self.createdAtMilliseconds = createdAtMilliseconds
        self.hasAudio = hasAudio
        self.hasVideo = hasVideo
    }

    enum CodingKeys: String, CodingKey {
        case key = "k", clientData = "c", createdAtMilliseconds = "t", hasAudio = "a", hasVideo = "v"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        clientData = try container.decodeIfPresent(String.self, forKey: .clientData) ?? ""
        createdAtMilliseconds = (try? container.decodeIfPresent(Int64.self, forKey: .createdAtMilliseconds))
            ?? (try? container.decodeIfPresent(Double.self, forKey: .createdAtMilliseconds)).map { Int64($0) }
            ?? 0
        hasAudio = (try? container.decodeIfPresent(Bool.self, forKey: .hasAudio)) ?? false
        hasVideo = (try? container.decodeIfPresent(Bool.self, forKey: .hasVideo)) ?? false
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `nil` для дорожек не из протокола Connect: веб-клиент их тоже игнорирует.
    public static func decode(_ raw: String) -> TrackName? {
        try? JSONDecoder().decode(TrackName.self, from: Data(raw.utf8))
    }
}

/// Клиентские данные участника. Веб-клиент передаёт в фасад объект `{clientData: "<json>"}`,
/// поэтому в имени дорожки и в сигналах лежит строка `{"clientData":"{\"userId\":…}"}`.
public struct CallClientData: Codable, Sendable, Equatable {
    public var userId: String
    public var username: String?
    public var sessionId: String?

    public init(userId: String, username: String?, sessionId: String?) {
        self.userId = userId
        self.username = username
        self.sessionId = sessionId
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard
            let inner = try? encoder.encode(self),
            let outer = try? encoder.encode(Envelope(clientData: String(decoding: inner, as: UTF8.self)))
        else { return "" }
        return String(decoding: outer, as: UTF8.self)
    }

    /// Разбирает и обёрнутую, и плоскую форму, а также `CLIENT%/%SERVER`.
    public static func decode(_ raw: String) -> CallClientData? {
        let candidate = raw.components(separatedBy: "%/%").first ?? raw
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope.self, from: Data(candidate.utf8)),
           let inner = try? decoder.decode(CallClientData.self, from: Data(envelope.clientData.utf8)) {
            return inner
        }
        return try? decoder.decode(CallClientData.self, from: Data(candidate.utf8))
    }

    private struct Envelope: Codable {
        let clientData: String
    }
}

/// Сигнал в топике `ov-signal`: `{"type":"mute","data":"<json>","client":"<client data>"}`.
public struct SignalPacket: Codable, Sendable, Equatable {
    public var type: String
    public var data: String
    public var client: String

    public init(type: String, data: String, client: String) {
        self.type = type
        self.data = data
        self.client = client
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> SignalPacket? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return SignalPacket(
            type: object["type"] as? String ?? "",
            data: object["data"] as? String ?? "",
            client: object["client"] as? String ?? ""
        )
    }
}

/// Сигналы личного звонка (`useP2pCall.ts`).
public enum CallSignal: Sendable, Equatable {
    /// `mute`: микрофон собеседника выключен.
    case microphoneMuted(userId: String, muted: Bool)
    /// `speakerOff`: собеседник выключил у себя звук.
    case speakerOff(userId: String, muted: Bool)
    /// `speak`: собеседник говорит.
    case speaking(userId: String, speaking: Bool)

    public var userId: String {
        switch self {
        case let .microphoneMuted(userId, _), let .speakerOff(userId, _), let .speaking(userId, _): userId
        }
    }

    public func packet(client: String) -> SignalPacket {
        switch self {
        case let .microphoneMuted(userId, muted):
            SignalPacket(type: "mute", data: Self.json(MuteBody(userId: userId, muted: muted, type: "MIC")), client: client)
        case let .speakerOff(userId, muted):
            SignalPacket(type: "speakerOff", data: Self.json(MuteBody(userId: userId, muted: muted, type: "SPEAK")), client: client)
        case let .speaking(userId, speaking):
            SignalPacket(type: "speak", data: Self.json(SpeakBody(userId: userId, speak: speaking)), client: client)
        }
    }

    public init?(packet: SignalPacket) {
        let data = Data(packet.data.utf8)
        switch packet.type {
        case "mute":
            guard let body = try? JSONDecoder().decode(MuteBody.self, from: data), body.type == "MIC" else { return nil }
            self = .microphoneMuted(userId: body.userId, muted: body.muted)
        case "speakerOff":
            guard let body = try? JSONDecoder().decode(MuteBody.self, from: data), body.type == "SPEAK" else { return nil }
            self = .speakerOff(userId: body.userId, muted: body.muted)
        case "speak":
            guard let body = try? JSONDecoder().decode(SpeakBody.self, from: data) else { return nil }
            self = .speaking(userId: body.userId, speaking: body.speak)
        default:
            return nil
        }
    }

    private static func json(_ value: some Encodable) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct MuteBody: Codable {
        let userId: String
        let muted: Bool
        let type: String
    }

    private struct SpeakBody: Codable {
        let userId: String
        let speak: Bool
    }
}
