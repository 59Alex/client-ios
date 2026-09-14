import ConnectChat
import ConnectNetworking
import ConnectTestSupport
import Foundation
import Testing
@testable import ConnectRooms
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
@Suite("Модерация каналов-лент")
struct FeedModerationTests {
    let me = ChatUser(userId: "me", username: "me")
    let feedId = "7f1c2a4e-0000-4000-8000-000000000001"

    private func members() -> FeedMembers {
        FeedMembers(
            admin: .init(userId: "owner", username: "owner"),
            moderators: [.init(userId: "mod", username: "mod"), .init(userId: "bad-mod", username: "bad-mod")],
            subscribers: [.init(userId: "owner", username: "owner"), .init(userId: "mod", username: "mod"), .init(userId: "sub", username: "sub"), .init(userId: "banned", username: "banned")],
            bannedUsers: [.init(userId: "banned", username: "banned"), .init(userId: "bad-mod", username: "bad-mod")]
        )
    }

    @Test("права: админ всё, модератор по флагам, подписчик ничего; секции без забаненных")
    func permissionsAndSections() async {
        let api = FakeRoomsAPI(feedRoles: [feedId: .moderator])
        await api.setMembers(members(), feedId: feedId)
        await api.setPrivileges(FeedPrivileges(canBanUsers: true), feedId: feedId)
        let model = FeedModel(feedId: feedId, me: me, api: api)
        await model.load()
        #expect(model.canBan)
        #expect(!model.canUnban)
        #expect(!model.canAssignModerators)

        await model.loadMembers()
        #expect(model.visibleModerators.map(\.userId) == ["mod"])
        #expect(model.visibleSubscribers.map(\.userId) == ["sub"])

        let subscriber = FeedModel(feedId: feedId, me: me, api: FakeRoomsAPI(feedRoles: [feedId: .subscriber]))
        await subscriber.load()
        #expect(!subscriber.canBan && !subscriber.canUnban && !subscriber.canAssignModerators)
    }

    @Test("админ назначает и снимает модератора, банит и разбанивает; модератор без прав ничего не отправляет")
    func adminActions() async {
        let api = FakeRoomsAPI(feedRoles: [feedId: .admin])
        await api.setMembers(members(), feedId: feedId)
        let model = FeedModel(feedId: feedId, me: me, api: api)
        await model.load()

        await model.makeModerator("sub", privileges: FeedPrivileges(canBanUsers: true))
        await model.removeModerator("mod")
        await model.setBanned(true, userId: "sub")
        await model.setBanned(false, userId: "banned")
        #expect(await api.moderationLog == ["moderator+:sub:true", "moderator-:mod", "ban:sub", "unban:banned"])
        #expect(model.memberList?.bannedUsers.map(\.userId).contains("banned") == false)

        let moderatorApi = FakeRoomsAPI(feedRoles: [feedId: .moderator])
        let moderator = FeedModel(feedId: feedId, me: me, api: moderatorApi)
        await moderator.load()
        await moderator.setBanned(true, userId: "sub")
        await moderator.makeModerator("sub", privileges: FeedPrivileges())
        #expect(await moderatorApi.moderationLog.isEmpty)
    }

    @Test("модератор при отписке сначала снимает с себя права")
    func moderatorUnsubscribe() async {
        let api = FakeRoomsAPI(feedRoles: [feedId: .moderator])
        let model = FeedModel(feedId: feedId, me: me, api: api)
        await model.load()
        await model.setSubscribed(false)
        #expect(await api.moderationLog == ["moderator-:me"])
        #expect(model.role == nil)
    }

    @Test("просмотр поста один раз и только для UUID")
    func views() async throws {
        let api = FakeRoomsAPI(feedRoles: [feedId: .subscriber])
        let model = FeedModel(feedId: feedId, me: me, api: api)
        let uuid = "11111111-2222-4333-8444-555555555555"
        model.markViewed(uuid)
        model.markViewed(uuid)
        model.markViewed("post-new-1")
        for _ in 0..<100 where await api.viewedPosts.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await api.viewedPosts == [uuid])
    }

    @Test("ссылка-приглашение: base64 и URL-safe, только UUID; ошибки сервиса по статусу")
    func inviteLinks() async {
        let origin = URL(string: "https://cnnect.ru")!
        let link = InviteLinks.feedURL(origin: origin, feedId: feedId).absoluteString
        #expect(InviteLinks.feedId(from: link) == feedId)
        let urlSafe = Data(feedId.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(InviteLinks.feedId(from: "https://cnnect.ru/post-feed-invite/\(urlSafe)") == feedId)
        #expect(InviteLinks.feedId(from: "https://cnnect.ru/post-feed-invite/\(Data("not-a-uuid".utf8).base64EncodedString())") == nil)
        #expect(InviteLinks.feedId(from: "https://cnnect.ru/invite/abc") == nil)

        let api = FakeRoomsAPI()
        let feeds = FeedsModel(me: "me", api: api)
        #expect(await feeds.join(link: link) == .success(feedId))
        #expect(feeds.feeds.contains { $0.id == feedId })
        #expect(await feeds.join(link: "мусор/ссылка") == .failure(.broken))
        await api.setJoinStatus(404)
        #expect(await feeds.join(link: link) == .failure(.notFound))
        await api.setJoinStatus(403)
        #expect(await feeds.join(link: link) == .failure(.forbidden))
    }

    @Test("комментарии: оптимистично, удалить можно только свои")
    func comments() async {
        let api = FakeRoomsAPI()
        await api.setComments([PostComment(id: "c1", postId: "p", text: "чужой", createdAtMilliseconds: 1, userId: "other", username: "other")], postId: "p")
        let model = PostCommentsModel(postId: "p", me: me, api: api, now: { Date(timeIntervalSince1970: 10) })
        await model.load()
        #expect(model.comments.map(\.id) == ["c1"])

        model.draft = "  мой  "
        await model.send()
        #expect(model.comments.last?.text == "мой")
        #expect(model.comments.last?.id.hasPrefix("comment-") == true)
        #expect(model.draft.isEmpty)

        await model.delete(model.comments[0])
        #expect(model.comments.count == 2)
        await model.delete(model.comments[1])
        #expect(model.comments.map(\.id) == ["c1"])
    }

    @Test("тела запросов модерации и разбор комментария")
    func remoteBodies() async throws {
        let transport = StubTransport()
        transport.on("/api/post-feed/moderator/add", json: "")
        transport.on("/api/post-feed/post/p1/comments", json: #"[{"id":5,"postId":"p1","message":"hi","dateTimeCreateTimestamp":1757800000000,"userId":"u","username":"ivan"}]"#)
        let api = RemoteRoomsAPI(main: HTTPClient(baseURL: URL(string: "https://main.example")!, transport: transport))

        try await api.addModerator(feedId: "f", userId: "u", privileges: FeedPrivileges(canCreatePosts: true, canManageComments: true))
        let body = String(decoding: try #require(transport.requests.last?.httpBody), as: UTF8.self)
        #expect(transport.requests.last?.httpMethod == "PUT")
        for fragment in [#""postFeedId":"f""#, #""userId":"u""#, #""canCreatePosts":true"#, #""canManageComments":true"#, #""canUnbanUsers":false"#] {
            #expect(body.contains(fragment))
        }

        let comments = try await api.comments(postId: "p1")
        #expect(comments == [PostComment(id: "5", postId: "p1", text: "hi", createdAtMilliseconds: 1_757_800_000_000, userId: "u", username: "ivan")])
    }
}
