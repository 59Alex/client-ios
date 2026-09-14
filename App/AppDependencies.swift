import ConnectAuth
import ConnectCalls
import ConnectChat
import ConnectCore
import ConnectFeatures
import ConnectFiles
import ConnectInbox
import ConnectRooms
import ConnectSettings
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
    private let settingsClient: HTTPClient
    private let usersClient: HTTPClient
    private let eventStream: any EventStreamTransport
    private let overrides: Overrides

    /// Подмены для офлайн-стаба XCUITest: звонки и чаты без сети и WebRTC.
    struct Overrides {
        var makeCallModel: (@MainActor (CallParticipant) -> P2PCallModel)?
        var chatAPI: (any ChatAPI)?
        var makeSignalRoom: (@MainActor () -> any SignalRoom)?
        /// Медиакомната для групповых звонков и голосовых каналов.
        var makeCallRoom: (@MainActor () -> any CallRoom)?
        var fileAPI: (any FileAPI)?
        var contacts: (any ContactsRepository)?
        var inbox: (any InboxAPI)?
        var rooms: (any RoomsAPI)?
        var settings: (any SettingsAPI)?
        var groupCalls: (any GroupCallAPI)?
        var roomVoice: (any RoomVoiceAPI)?
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
        settingsClient = HTTPClient(baseURL: config.settingsApiUrl, transport: transport, tokenProvider: auth, timeout: 10)
        usersClient = HTTPClient(baseURL: config.userApiUrl, transport: transport, tokenProvider: auth)
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
        let contactsRepository = overrides.contacts ?? RemoteContactsRepository(client: mainClient)
        let roomsAPI = overrides.rooms ?? RemoteRoomsAPI(main: mainClient)
        let settingsAPI = overrides.settings ?? RemoteSettingsAPI(settings: settingsClient, users: usersClient, main: mainClient)
        let groupCallAPI = overrides.groupCalls ?? RemoteGroupCallAPI(main: mainClient, events: eventsClient, outbox: outboxClient, eventStream: eventStream)
        let roomVoiceAPI = overrides.roomVoice ?? RemoteRoomVoiceAPI(main: mainClient, events: eventsClient, outbox: outboxClient, eventStream: eventStream)
        let callRoom: @MainActor () -> any CallRoom = overrides.makeCallRoom ?? { LiveKitCallRoom() }
        let usesStubRooms = overrides.makeCallRoom != nil
        let files = overrides.fileAPI ?? RemoteFileAPI(client: s3Client)
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("connect-media", isDirectory: true)
        let rtcUrl = config.rtcWebSocketUrl
        return SignedInDependencies(
            user: user,
            status: status,
            contacts: ContactsModel(userId: user.userId, repository: contactsRepository),
            calls: calls,
            users: RemoteUserRepository(client: mainClient),
            files: files,
            mediaLoader: MediaLoader(api: files, cacheDirectory: overrides.fileAPI == nil ? cacheDirectory : nil),
            unread: unread,
            inbox: inbox,
            notifications: NotificationCenterModel(api: inbox),
            invitations: InvitationsModel(me: user.userId, api: inbox),
            rooms: RoomsModel(me: user.userId, api: roomsAPI),
            feeds: FeedsModel(me: user.userId, api: roomsAPI),
            uiOrigin: config.uiOrigin,
            settings: settingsAPI,
            deviceId: Self.deviceId(),
            groupCallAPI: groupCallAPI,
            directory: UserDirectory(repository: contactsRepository),
            summaries: CallSummaryPublisher(me: chatUser, api: chatAPI, rtcUrl: config.rtcWebSocketUrl, makeRoom: makeSignalRoom),
            groupCalls: GroupCallModel(me: me, api: groupCallAPI, rtcUrl: config.rtcWebSocketUrl, makeRoom: callRoom, sessionId: { await status.currentSessionId(userId: user.userId) }, requestMicrophone: { usesStubRooms ? true : await MicrophonePermission.request() }),
            roomVoice: RoomVoiceModel(me: me, api: roomVoiceAPI, rtcUrl: config.rtcWebSocketUrl, makeRoom: callRoom, sessionId: { await status.currentSessionId(userId: user.userId) }, requestMicrophone: { usesStubRooms ? true : await MicrophonePermission.request() }),
            makeRoom: { RoomModel(roomId: $0, me: user.userId, api: roomsAPI) },
            makeCalendar: { RoomCalendarModel(roomId: $0, api: roomsAPI) },
            makeFeed: { FeedModel(feedId: $0, me: chatUser, api: roomsAPI) },
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

    /// Идентификатор устройства для настроек голоса: строчный UUID, живёт до удаления приложения.
    static func deviceId(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: "deviceId"), !stored.isEmpty { return stored }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: "deviceId")
        return created
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
                    makeCallRoom: { UITestStub.makeGroupRoom() },
                    fileAPI: UITestStub.makeFileAPI(),
                    contacts: UITestStub.makeContactsRepository(),
                    inbox: UITestStub.makeInboxAPI(),
                    rooms: UITestStub.makeRoomsAPI(),
                    settings: FakeSettingsAPI(userId: "qa-1", name: "QA Wallpaper", username: "@qa_wallpaper_1", email: "qa@example.com", takenUsernames: ["@qa_wallpaper_2"], sticker: GreetingSticker(urlS3: "user-gallery/qa-3/greeting.png", extension: ".png")),
                    groupCalls: UITestStub.makeGroupCallAPI(arguments: arguments),
                    roomVoice: FakeRoomVoiceAPI(connected: [ChannelParticipantEvent(userId: "qa-2", channelId: "channel-voice", muted: true, kind: .connect)])
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
    let rooms: RoomsModel
    let feeds: FeedsModel
    let uiOrigin: URL
    let settings: any SettingsAPI
    let deviceId: String
    let groupCallAPI: any GroupCallAPI
    let directory: UserDirectory
    let summaries: CallSummaryPublisher
    let groupCalls: GroupCallModel
    let roomVoice: RoomVoiceModel
    let makeRoom: @MainActor (String) -> RoomModel
    let makeCalendar: @MainActor (String) -> RoomCalendarModel
    let makeFeed: @MainActor (String) -> FeedModel
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
        rooms: RoomsModel,
        feeds: FeedsModel,
        uiOrigin: URL,
        settings: any SettingsAPI,
        deviceId: String,
        groupCallAPI: any GroupCallAPI,
        directory: UserDirectory,
        summaries: CallSummaryPublisher,
        groupCalls: GroupCallModel,
        roomVoice: RoomVoiceModel,
        makeRoom: @escaping @MainActor (String) -> RoomModel,
        makeCalendar: @escaping @MainActor (String) -> RoomCalendarModel,
        makeFeed: @escaping @MainActor (String) -> FeedModel,
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
        self.rooms = rooms
        self.feeds = feeds
        self.uiOrigin = uiOrigin
        self.settings = settings
        self.deviceId = deviceId
        self.groupCallAPI = groupCallAPI
        self.directory = directory
        self.summaries = summaries
        self.groupCalls = groupCalls
        self.roomVoice = roomVoice
        self.makeRoom = makeRoom
        self.makeCalendar = makeCalendar
        self.makeFeed = makeFeed
        self.p2pChats = p2pChats
        self.groupChats = groupChats
        self.makeChat = makeChat
    }
}
