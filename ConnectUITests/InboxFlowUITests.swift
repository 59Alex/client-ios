import XCTest

/// Уведомления, приглашения и создание группы на офлайн-стабе.
final class InboxFlowUITests: XCTestCase {
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
    func testNotificationOpensChat() throws {
        let app = launchSignedIn()
        let bell = app.buttons["inbox.open"]
        XCTAssertTrue(bell.waitForExistence(timeout: 10))
        bell.tap()

        let notification = app.buttons["inbox.notification.7"]
        XCTAssertTrue(notification.waitForExistence(timeout: 10))
        attachScreenshot("40-notifications")
        notification.tap()

        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAcceptGroupInvitation() throws {
        let app = launchSignedIn()
        app.buttons["inbox.open"].tap()

        let section = app.segmentedControls["inbox.section"]
        XCTAssertTrue(section.waitForExistence(timeout: 10))
        section.buttons.element(boundBy: 1).tap()

        let accept = app.buttons["inbox.accept.inv-1"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        attachScreenshot("41-invitations")
        accept.tap()

        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Группы"].isSelected)
        XCTAssertTrue(app.buttons["chat.members"].exists)
        app.buttons["chat.members"].tap()
        XCTAssertTrue(app.buttons["group.invite.qa_wallpaper_2"].waitForExistence(timeout: 5))
        app.buttons["group.invite.qa_wallpaper_2"].tap()
        XCTAssertTrue(app.staticTexts["Отправлено"].waitForExistence(timeout: 5))
        attachScreenshot("42-group-members")
    }

    @MainActor
    func testCreateGroup() throws {
        let app = launchSignedIn()
        app.tabBars.buttons["Группы"].tap()

        let create = app.buttons["groups.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()

        let name = app.textFields["group.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["group.create"].isEnabled)
        name.tap()
        name.typeText("Новая группа")
        app.buttons["group.member.qa_wallpaper_2"].tap()
        attachScreenshot("43-create-group")
        app.buttons["group.create"].tap()

        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertFalse(name.exists)
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
