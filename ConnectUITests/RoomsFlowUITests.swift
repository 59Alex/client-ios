import XCTest

/// Комнаты с текстовыми каналами и календарём, каналы-ленты на офлайн-стабе.
final class RoomsFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchSignedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-stub", "-ui-test-signed-in"]
        app.launch()
        XCTAssertTrue(app.buttons["home.tab.chats"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testRoomChannelChatAndCalendar() throws {
        let app = launchSignedIn()
        let room = app.buttons["rail.room.room-1"]
        XCTAssertTrue(room.waitForExistence(timeout: 10))
        room.tap()

        let channel = app.buttons["room.channel.channel-general"]
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Голосовой"].exists)
        attachScreenshot("50-room")

        app.buttons["room.calendar"].tap()
        XCTAssertTrue(app.staticTexts["Планёрка"].waitForExistence(timeout: 10))
        attachScreenshot("51-calendar")
        app.buttons["Закрыть"].tap()

        XCTAssertTrue(channel.waitForExistence(timeout: 5))
        channel.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Добро пожаловать в комнату'")).firstMatch.waitForExistence(timeout: 10))
        let input = app.textFields["chat.input"]
        input.tap()
        input.typeText("Привет, комната")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Привет, комната'")).firstMatch.waitForExistence(timeout: 5))
        attachScreenshot("52-channel-chat")
    }

    @MainActor
    func testCreateRoomChannel() throws {
        let app = launchSignedIn()
        app.buttons["rail.room.room-1"].tap()

        let create = app.buttons["room.createText"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()

        let field = app.textFields["room.createChannel.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("новости")
        app.buttons["room.createChannel.submit"].tap()

        XCTAssertTrue(app.staticTexts["новости"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFeedPublishPost() throws {
        let app = launchSignedIn()
        app.buttons["home.tab.feeds"].tap()

        let feed = app.buttons["feeds.row.feed-1"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10))
        feed.tap()

        XCTAssertTrue(app.staticTexts["Первый пост"].waitForExistence(timeout: 10))
        let input = app.textFields["feed.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Второй пост с iPhone")
        app.buttons["feed.publish"].tap()
        XCTAssertTrue(app.staticTexts["Второй пост с iPhone"].waitForExistence(timeout: 5))
        attachScreenshot("53-feed")
    }

    @MainActor
    func testFeedCommentsAndModeration() throws {
        let app = launchSignedIn()
        app.buttons["home.tab.feeds"].tap()
        let feed = app.buttons["feeds.row.feed-1"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10))
        feed.tap()

        let comments = app.buttons["feed.comments.post-1"]
        XCTAssertTrue(comments.waitForExistence(timeout: 10))
        comments.tap()
        XCTAssertTrue(app.staticTexts["Отличная новость"].waitForExistence(timeout: 10))
        let input = app.textFields["comment.input"]
        input.tap()
        input.typeText("Спасибо!")
        app.buttons["comment.send"].tap()
        XCTAssertTrue(app.staticTexts["Спасибо!"].waitForExistence(timeout: 5))
        attachScreenshot("54-feed-comments")
        app.buttons["Готово"].firstMatch.tap()

        app.buttons["feed.menu"].tap()
        app.buttons["Участники"].tap()
        let subscriber = app.buttons["feed.member.subscriber.qa-2"]
        XCTAssertTrue(subscriber.waitForExistence(timeout: 10))
        attachScreenshot("55-feed-members")
        subscriber.tap()
        app.buttons["Сделать модератором"].tap()
        let ban = app.switches["moderator.ban"]
        XCTAssertTrue(ban.waitForExistence(timeout: 5))
        ban.switches.firstMatch.tap()
        app.buttons["moderator.submit"].tap()

        let moderator = app.buttons["feed.member.moderator.qa-2"]
        XCTAssertTrue(moderator.waitForExistence(timeout: 10))
        moderator.tap()
        app.buttons["Выдать бан"].tap()
        XCTAssertTrue(app.buttons["feed.member.banned.qa-2"].waitForExistence(timeout: 10))
        attachScreenshot("56-feed-banned")
    }

    @MainActor
    func testMeetingLinkOpensGroup() throws {
        let app = launchSignedIn()
        let add = app.buttons["rail.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        app.buttons["Войти по приглашению"].tap()

        let field = app.textFields["rooms.join.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://cnnect.ru/share/meet/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde")
        app.buttons["rooms.join.submit"].tap()

        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chat.members"].exists)
        attachScreenshot("57-meeting-group")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
