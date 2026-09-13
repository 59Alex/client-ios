import ConnectAuth
import ConnectCalls
import ConnectChat
import ConnectCore
import ConnectFeatures
import ConnectFiles
import ConnectInbox
import ConnectNetworking
import Foundation
#if DEBUG
import ConnectTestSupport
#endif

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
    private let notificationClient: HTTPClient
    private let s3Client: HTTPClient
    private let eventStream: any EventStreamTransport
    private let overrides: Overrides

    /// Подмены для офлайн-стаба XCUITest: звонки и чаты без сети и WebRTC.
    struct Overrides {
        var makeCallModel: (@MainActor (CallParticipant) -> P2PCallModel)?
        var chatAPI: (any ChatAPI)?
        var makeSignalRoom: (@MainActor () -> any SignalRoom)?
        var fileAPI: (any FileAPI)?
        var contacts: (any ContactsRepository)?
        var inbox: (any InboxAPI)?
    }

    init(
        config: AppConfig,
        transport: any HTTPTransport,
        eventStream: any EventStreamTransport,
        tokenStore: any TokenStore,
        overrides: Overrides = Overrides()
    ) {
        self.config = config
        self.eventStream = eventStream
        self.overrides = overrides
        auth = AuthService(userApiUrl: config.userApiUrl, transport: transport, store: tokenStore)
        mainClient = HTTPClient(baseURL: config.mainApiUrl, transport: transport, tokenProvider: auth)
        // Токен звонку выдаётся дольше обычного запроса (get-token ждёт медиасервер).
        eventsClient = HTTPClient(baseURL: config.eventsApiUrl, transport: transport, tokenProvider: auth, timeout: 20)
        outboxClient = HTTPClient(baseURL: config.eventsOutboxApiUrl, transport: transport, tokenProvider: auth)
        statusClient = HTTPClient(baseURL: config.statusApiUrl, transport: transport, tokenProvider: auth, timeout: 8)
        notificationClient = HTTPClient(baseURL: config.notificationApiUrl, transport: transport, tokenProvider: auth)
        s3Client = HTTPClient(baseURL: config.s3ApiUrl, transport: transport, tokenProvider: auth, timeout: 60)
        session = SessionModel(auth: auth, users: RemoteUserRepository(client: mainClient))
    }

    /// Зависимости экранов вошедшего пользователя; живут, пока он не выйдет.
    func makeSignedIn(user: User) -> SignedInDependencies {
        let status = StatusService(client: statusClient)
        let me = CallParticipant(userId: user.userId, name: user.name, username: user.username)
        let calls = overrides.makeCallModel?(me) ?? P2PCallModel(
            me: me,
            api: RemoteP2PCallAPI(main: mainClient, events: eventsClient, outbox: outboxClient, eventStream: eventStream),
            rtcUrl: config.rtcWebSocketUrl,
            makeRoom: { LiveKitCallRoom() },
            sessionId: { await status.currentSessionId(userId: user.userId) },
            requestMicrophone: { await MicrophonePermission.request() }
        )
        let chatAPI = overrides.chatAPI ?? RemoteChatAPI(main: mainClient, notifications: notificationClient, eventStream: eventStream)
        let unread = UnreadModel(api: chatAPI)
        let makeSignalRoom = overrides.makeSignalRoom ?? { LiveKitCallRoom() }
        let chatUser = ChatUser(userId: user.userId, username: user.username)
        let inbox = overrides.inbox ?? RemoteInboxAPI(main: mainClient, notifications: notificationClient)
        let files = overrides.fileAPI ?? RemoteFileAPI(client: s3Client)
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("connect-media", isDirectory: true)
        let rtcUrl = config.rtcWebSocketUrl
        return SignedInDependencies(
            user: user,
            status: status,
            contacts: ContactsModel(userId: user.userId, repository: overrides.contacts ?? RemoteContactsRepository(client: mainClient)),
            calls: calls,
            users: RemoteUserRepository(client: mainClient),
            files: files,
            mediaLoader: MediaLoader(api: files, cacheDirectory: overrides.fileAPI == nil ? cacheDirectory : nil),
            unread: unread,
            inbox: inbox,
            notifications: NotificationCenterModel(api: inbox),
            invitations: InvitationsModel(me: user.userId, api: inbox),
            p2pChats: ChatListModel(kind: .p2p, api: chatAPI),
            groupChats: ChatListModel(kind: .group, api: chatAPI),
            makeChat: { route in
                ChatModel(
                    kind: route.kind,
                    roomId: route.roomId,
                    title: route.title,
                    me: chatUser,
                    api: chatAPI,
                    unread: unread,
                    rtcUrl: rtcUrl,
                    makeRoom: makeSignalRoom,
                    files: files
                )
            }
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
                overrides: Overrides(
                    makeCallModel: { UITestStub.makeCallModel(me: $0, arguments: arguments) },
                    chatAPI: UITestStub.makeChatAPI(),
                    makeSignalRoom: { FakeCallRoom() },
                    fileAPI: UITestStub.makeFileAPI(),
                    contacts: UITestStub.makeContactsRepository(),
                    inbox: UITestStub.makeInboxAPI()
                )
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
    let users: any UserRepository
    let files: any FileAPI
    let mediaLoader: MediaLoader
    let unread: UnreadModel
    let inbox: any InboxAPI
    let notifications: NotificationCenterModel
    let invitations: InvitationsModel
    let p2pChats: ChatListModel
    let groupChats: ChatListModel
    let makeChat: @MainActor (ChatRoute) -> ChatModel

    init(
        user: User,
        status: StatusService,
        contacts: ContactsModel,
        calls: P2PCallModel,
        users: any UserRepository,
        files: any FileAPI,
        mediaLoader: MediaLoader,
        unread: UnreadModel,
        inbox: any InboxAPI,
        notifications: NotificationCenterModel,
        invitations: InvitationsModel,
        p2pChats: ChatListModel,
        groupChats: ChatListModel,
        makeChat: @escaping @MainActor (ChatRoute) -> ChatModel
    ) {
        self.user = user
        self.status = status
        self.contacts = contacts
        self.calls = calls
        self.users = users
        self.files = files
        self.mediaLoader = mediaLoader
        self.unread = unread
        self.inbox = inbox
        self.notifications = notifications
        self.invitations = invitations
        self.p2pChats = p2pChats
        self.groupChats = groupChats
        self.makeChat = makeChat
    }
}
