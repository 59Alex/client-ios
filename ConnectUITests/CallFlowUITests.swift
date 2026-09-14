import XCTest

/// Контакты и личный звонок на офлайн-стабе: фейковая комната «берёт трубку» сама.
final class CallFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Сессия восстанавливается из хранилища: ввод пароля вызывал бы системное предложение
    /// сохранить пароль, окно которого перекрывает приложение в симуляторе.
    @MainActor
    private func launchSignedIn(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-stub", "-ui-test-signed-in"] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["home.tab.contacts"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testOutgoingCallFromContacts() throws {
        let app = launchSignedIn()
        app.buttons["home.tab.contacts"].tap()

        let callButton = app.buttons["contacts.call.qa_wallpaper_2"]
        XCTAssertTrue(callButton.waitForExistence(timeout: 10))
        attachScreenshot("10-contacts")

        callButton.tap()
        XCTAssertTrue(app.staticTexts["call.peer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["call.peer"].label, "QA Wallpaper Two")

        let status = app.staticTexts["call.status"]
        let active = NSPredicate(format: "label BEGINSWITH 'Вызов активен'")
        expectation(for: active, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        attachScreenshot("11-call-active")

        app.buttons["call.mute"].tap()
        XCTAssertTrue(app.buttons["Включить микрофон"].waitForExistence(timeout: 5))
        attachScreenshot("12-call-muted")

        app.buttons["call.hangup"].tap()
        XCTAssertTrue(callButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["call.hangup"].exists)
    }

    @MainActor
    func testIncomingCallAcceptAndHangUp() throws {
        let app = launchSignedIn(extraArguments: ["-ui-test-incoming-call"])

        let accept = app.buttons["call.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        let peer = app.staticTexts["call.peer"]
        expectation(for: NSPredicate(format: "label == 'QA Wallpaper Two'"), evaluatedWith: peer)
        waitForExpectations(timeout: 5)
        attachScreenshot("13-call-incoming")

        accept.tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Вызов активен'"), evaluatedWith: app.staticTexts["call.status"])
        waitForExpectations(timeout: 10)

        app.buttons["call.hangup"].tap()
        XCTAssertTrue(app.buttons["home.tab.contacts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["call.hangup"].exists)
    }

    @MainActor
    func testIncomingCallDecline() throws {
        let app = launchSignedIn(extraArguments: ["-ui-test-incoming-call"])

        let decline = app.buttons["call.decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 10))
        decline.tap()

        XCTAssertTrue(app.buttons["home.tab.contacts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["call.accept"].exists)
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
