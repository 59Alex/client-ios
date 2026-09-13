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
        XCTAssertTrue(app.tabBars.buttons["Комнаты"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testRoomChannelChatAndCalendar() throws {
        let app = launchSignedIn()
        app.tabBars.buttons["Комнаты"].tap()

        let room = app.buttons["rooms.row.room-1"]
        XCTAssertTrue(room.waitForExistence(timeout: 10))
        room.tap()

        let channel = app.buttons["room.channel.channel-general"]
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Голосовой"].exists)
        attachScreenshot("50-room")

        app.buttons["room.menu"].tap()
        app.buttons["Календарь"].tap()
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
        app.tabBars.buttons["Комнаты"].tap()
        app.buttons["rooms.row.room-1"].tap()

        let menu = app.buttons["room.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Текстовый канал"].tap()

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
        app.tabBars.buttons["Каналы"].tap()

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
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
