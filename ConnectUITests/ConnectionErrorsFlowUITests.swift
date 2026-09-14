import XCTest

/// Панель ошибок подключения: недоступный медиасервер и запрет микрофона с подсказкой настроек.
final class ConnectionErrorsFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMediaServerDownShowsPanel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-stub", "-ui-test-signed-in", "-ui-test-media-down"]
        app.launch()

        let button = app.buttons["connection.errors"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.staticTexts["Медиасервер недоступен"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connection.retry.mediaServer"].exists)
        attachScreenshot("90-media-server-down")
    }

    @MainActor
    func testMicrophoneDeniedShowsSettingsGuide() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-stub", "-ui-test-signed-in", "-ui-test-mic-denied"]
        app.launch()
        XCTAssertFalse(app.buttons["connection.errors"].waitForExistence(timeout: 3))

        let room = app.buttons["rail.room.room-1"]
        XCTAssertTrue(room.waitForExistence(timeout: 10))
        room.tap()
        let voice = app.buttons["room.voice.channel-voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        voice.tap()

        XCTAssertTrue(app.staticTexts["Нет доступа к микрофону"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["connection.microphone.guide"].exists)
        let action = app.buttons["connection.microphone.settings"].exists || app.buttons["connection.microphone.request"].exists
        XCTAssertTrue(action)
        attachScreenshot("91-microphone-guide")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
