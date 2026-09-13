import XCTest

/// Регистрация, настройки и приветствие на офлайн-стабе.
final class SettingsFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRegistrationLeadsToEmailVerification() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-stub"]
        app.launch()

        let mode = app.segmentedControls["login.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        mode.buttons["Регистрация"].tap()

        let name = app.textFields["register.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Новый Пользователь")
        let username = app.textFields["register.username"]
        username.tap()
        username.typeText("newbie")
        let email = app.textFields["register.email"]
        email.tap()
        email.typeText("new@example.com")
        XCTAssertFalse(app.buttons["register.submit"].isEnabled)

        app.buttons["Показать пароль"].tap()
        let password = app.textFields["register.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        password.typeText("Passw0rd!")
        attachScreenshot("60-registration")

        XCTAssertTrue(app.buttons["register.submit"].isEnabled)
        app.buttons["register.submit"].tap()

        XCTAssertTrue(app.textFields["login.code"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["login.resend"].exists)
        attachScreenshot("61-registration-verify")
    }

    @MainActor
    func testSettingsAccountAndSounds() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-stub", "-ui-test-signed-in"]
        app.launch()

        let profile = app.buttons["profile.open"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()

        let account = app.buttons["settings.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(app.staticTexts["account.value.email"].waitForExistence(timeout: 5))
        app.buttons["account.edit.username"].tap()

        let field = app.textFields["account.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("@qa_wallpaper_2")
        XCTAssertTrue(app.staticTexts["account.error"].waitForExistence(timeout: 5))
        attachScreenshot("62-account-taken")
        field.buttons.firstMatch.tap()
        let clear = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20)
        field.typeText(clear + "@qa_new_login")
        app.buttons["account.save"].tap()
        XCTAssertTrue(app.staticTexts["account.pending.username"].waitForExistence(timeout: 5))
        attachScreenshot("63-account-pending")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings.sounds"].tap()
        let toggle = app.switches["sounds.toggle.0"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.switches.firstMatch.tap()
        let off = NSPredicate(format: "value == '0'")
        expectation(for: off, evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        attachScreenshot("64-sounds")
    }

    @MainActor
    func testGreetingInEmptyChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-stub", "-ui-test-signed-in"]
        app.launch()

        let row = app.buttons["chats.row.room-qa-3"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let greeting = app.buttons["chat.greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        attachScreenshot("65-greeting")
        greeting.tap()

        XCTAssertTrue(app.buttons["Приветствие.png"].waitForExistence(timeout: 10))
        XCTAssertFalse(greeting.exists)
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
