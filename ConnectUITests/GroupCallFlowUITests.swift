import XCTest

/// Групповые звонки и голосовые каналы на офлайн-стабе: собеседник появляется в фейковой комнате.
final class GroupCallFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-stub", "-ui-test-signed-in"] + extra
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Группы"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testStartGroupCallFromChat() throws {
        let app = launch()
        app.tabBars.buttons["Группы"].tap()
        let group = app.buttons["chats.row.group-1"]
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        group.tap()

        let call = app.buttons["chat.groupCall"]
        XCTAssertTrue(call.waitForExistence(timeout: 10))
        call.tap()

        XCTAssertTrue(app.buttons["group.call.hangup"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["group.call.participant.qa-2"].waitForExistence(timeout: 10))
        attachScreenshot("70-group-call")

        app.buttons["group.call.mute"].tap()
        XCTAssertTrue(app.buttons["Включить микрофон"].waitForExistence(timeout: 5))
        app.buttons["group.call.hangup"].tap()
        XCTAssertTrue(call.waitForExistence(timeout: 10))
    }

    @MainActor
    func testIncomingGroupCall() throws {
        let app = launch(["-ui-test-incoming-group-call"])
        let accept = app.buttons["group.call.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 15))
        attachScreenshot("71-group-incoming")
        accept.tap()
        XCTAssertTrue(app.buttons["group.call.hangup"].waitForExistence(timeout: 10))
        app.buttons["group.call.hangup"].tap()
        XCTAssertFalse(app.buttons["group.call.hangup"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testJoinVoiceChannel() throws {
        let app = launch()
        app.tabBars.buttons["Комнаты"].tap()
        app.buttons["rooms.row.room-1"].tap()

        let voice = app.buttons["room.voice.channel-voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["room.voice.participant.qa-2"].waitForExistence(timeout: 10))
        voice.tap()

        XCTAssertTrue(app.buttons["voice.leave"].waitForExistence(timeout: 10))
        attachScreenshot("72-voice-channel")
        app.buttons["voice.mute"].tap()
        app.buttons["voice.leave"].tap()
        XCTAssertFalse(app.buttons["voice.leave"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
