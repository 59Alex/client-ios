import ConnectAuth
import ConnectCalls
import ConnectCore
import ConnectFeatures
import ConnectNetworking
import Foundation

/// Сборка зависимостей приложения. Вью получают их явно, без синглтонов.
@MainActor
final class AppDependencies {
    let config: AppConfig
    let auth: AuthService
    let session: SessionModel

    private let mainClient: HTTPClient
    private let eventsClient: HTTPClient
    private let outboxClient: HTTPClient
    private let statusClient: HTTPClient
    private let eventStream: any EventStreamTransport
    private let callOverride: (@MainActor (CallParticipant) -> P2PCallModel)?

    init(
        config: AppConfig,
        transport: any HTTPTransport,
        eventStream: any EventStreamTransport,
        tokenStore: any TokenStore,
        callOverride: (@MainActor (CallParticipant) -> P2PCallModel)? = nil
    ) {
        self.config = config
        self.eventStream = eventStream
        self.callOverride = callOverride
        auth = AuthService(userApiUrl: config.userApiUrl, transport: transport, store: tokenStore)
        mainClient = HTTPClient(baseURL: config.mainApiUrl, transport: transport, tokenProvider: auth)
        // Токен звонку выдаётся дольше обычного запроса (get-token ждёт медиасервер).
        eventsClient = HTTPClient(baseURL: config.eventsApiUrl, transport: transport, tokenProvider: auth, timeout: 20)
        outboxClient = HTTPClient(baseURL: config.eventsOutboxApiUrl, transport: transport, tokenProvider: auth)
        statusClient = HTTPClient(baseURL: config.statusApiUrl, transport: transport, tokenProvider: auth, timeout: 8)
        session = SessionModel(auth: auth, users: RemoteUserRepository(client: mainClient))
    }

    /// Зависимости экранов вошедшего пользователя; живут, пока он не выйдет.
    func makeSignedIn(user: User) -> SignedInDependencies {
        let status = StatusService(client: statusClient)
        let me = CallParticipant(userId: user.userId, name: user.name, username: user.username)
        let calls = callOverride?(me) ?? P2PCallModel(
            me: me,
            api: RemoteP2PCallAPI(main: mainClient, events: eventsClient, outbox: outboxClient, eventStream: eventStream),
            rtcUrl: config.rtcWebSocketUrl,
            makeRoom: { LiveKitCallRoom() },
            sessionId: { await status.currentSessionId(userId: user.userId) },
            requestMicrophone: { await MicrophonePermission.request() }
        )
        return SignedInDependencies(
            user: user,
            status: status,
            contacts: ContactsModel(userId: user.userId, repository: RemoteContactsRepository(client: mainClient)),
            calls: calls
        )
    }

    static func makeForLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppDependencies {
        #if DEBUG
        if arguments.contains(UITestStub.launchArgument) {
            return AppDependencies(
                config: .test,
                transport: UITestStub.makeTransport(),
                eventStream: UITestStub.SilentEventStream(),
                tokenStore: UITestStub.makeTokenStore(arguments: arguments),
                callOverride: { UITestStub.makeCallModel(me: $0, arguments: arguments) }
            )
        }
        #endif
        return AppDependencies(
            config: .test,
            transport: URLSessionTransport(),
            eventStream: URLSessionEventStreamTransport(),
            tokenStore: KeychainTokenStore()
        )
    }
}

@MainActor
final class SignedInDependencies {
    let user: User
    let status: StatusService
    let contacts: ContactsModel
    let calls: P2PCallModel

    init(user: User, status: StatusService, contacts: ContactsModel, calls: P2PCallModel) {
        self.user = user
        self.status = status
        self.contacts = contacts
        self.calls = calls
    }
}
