import XCTest

/// Темы оформления: выбор в настройках и главный экран в каждой из шести тем.
final class AppearanceFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSelectThemeInSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-stub", "-ui-test-signed-in"]
        app.launch()

        let settings = app.buttons["profile.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        attachScreenshot("80-home-dark")
        settings.tap()

        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        attachScreenshot("81-settings")
        appearance.tap()

        let light = app.buttons["appearance.theme.light"]
        XCTAssertTrue(light.waitForExistence(timeout: 5))
        light.tap()
        XCTAssertTrue(light.isSelected)
        let saved = app.staticTexts["Все изменения сохранены"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        attachScreenshot("82-appearance-light")

        app.buttons["appearance.theme.dracula"].tap()
        XCTAssertTrue(app.buttons["appearance.theme.dracula"].isSelected)
        attachScreenshot("83-appearance-dracula")

        let plain = app.buttons["appearance.background.plain"]
        let draculaDefault = app.buttons["appearance.background.pin1031605858416701164"]
        XCTAssertTrue(draculaDefault.waitForExistence(timeout: 5))
        XCTAssertTrue(draculaDefault.isSelected)
        plain.tap()
        XCTAssertTrue(plain.isSelected)
        XCTAssertFalse(draculaDefault.isSelected)
        attachScreenshot("87-appearance-backgrounds")
    }

    @MainActor
    func testHomeInEveryTheme() throws {
        for theme in ["monochrome", "dracula", "light", "dark", "gothic", "cathedral"] {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-test-stub", "-ui-test-signed-in", "-ui-test-theme", theme]
            app.launch()

            let row = app.buttons["chats.row.room-qa-2"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            attachScreenshot("84-home-\(theme)")

            app.buttons["rail.room.room-1"].tap()
            XCTAssertTrue(app.buttons["room.channel.channel-general"].waitForExistence(timeout: 10))
            attachScreenshot("85-room-\(theme)")

            app.buttons["rail.home"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 10))
            attachScreenshot("86-chat-\(theme)")
            app.terminate()
        }
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
