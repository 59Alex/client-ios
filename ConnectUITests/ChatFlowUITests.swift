import XCTest

/// Списки чатов и переписка на офлайн-стабе: реальная логика ChatModel, фейковые API и комната.
final class ChatFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchSignedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-stub", "-ui-test-signed-in"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Чаты"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testOpenChatAndSendMessage() throws {
        let app = launchSignedIn()

        let row = app.buttons["chats.row.room-qa-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Да, скинул файл"].exists)
        attachScreenshot("20-chats")

        row.tap()
        XCTAssertTrue(app.staticTexts["Новые сообщения"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["chat.callSummary"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Созвон завершён'")).firstMatch.exists)
        attachScreenshot("21-chat-open")

        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        input.tap()
        input.typeText("Сообщение с iPhone")
        app.buttons["chat.send"].tap()

        let sent = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Сообщение с iPhone'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        attachScreenshot("22-chat-sent")
    }

    @MainActor
    func testGroupsTabAndEmptyChat() throws {
        let app = launchSignedIn()

        app.tabBars.buttons["Группы"].tap()
        let group = app.buttons["chats.row.group-1"]
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 изображения"].exists)
        attachScreenshot("23-groups")

        group.tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
