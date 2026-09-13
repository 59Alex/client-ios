import XCTest

/// Сценарии входа на офлайн-стабе сервисов (`-ui-test-stub`), со скриншотами в .xcresult.
final class LoginFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-stub"]
        return app
    }

    @MainActor
    func testLoginOpensHome() throws {
        let app = makeApp()
        app.launch()
        let username = app.textFields["login.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["login.submit"].isEnabled)
        attachScreenshot("01-login")

        username.tap()
        username.typeText("@qa_wallpaper_1")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("password")
        app.buttons["login.submit"].tap()

        XCTAssertTrue(app.tabBars.buttons["Профиль"].waitForExistence(timeout: 10))
        attachScreenshot("02-home-chats")
    }

    @MainActor
    func testProfileAndLogoutReturnsToLogin() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-test-signed-in")
        app.launch()

        let profileTab = app.tabBars.buttons["Профиль"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 10))
        profileTab.tap()
        XCTAssertTrue(app.staticTexts["profile.name"].waitForExistence(timeout: 5))
        attachScreenshot("03-profile")

        app.buttons["profile.logout"].tap()
        XCTAssertTrue(app.textFields["login.username"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testWrongPasswordShowsError() throws {
        let app = makeApp()
        app.launch()
        let username = app.textFields["login.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))

        username.tap()
        username.typeText("@qa_wallpaper_1")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("wrong")
        app.buttons["login.submit"].tap()

        let error = app.staticTexts["login.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "Неверный логин или пароль")
        attachScreenshot("04-login-error")
    }

    @MainActor
    func testEmailVerificationFlow() throws {
        let app = makeApp()
        app.launch()
        let username = app.textFields["login.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))

        username.tap()
        username.typeText("@verify")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("password")
        app.buttons["login.submit"].tap()

        let code = app.textFields["login.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["login.verify"].isEnabled)
        code.typeText("123456")
        attachScreenshot("05-email-verification")

        app.buttons["login.verify"].tap()
        XCTAssertTrue(app.tabBars.buttons["Профиль"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLoginScreenWithLargeDynamicType() throws {
        let app = makeApp()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCTAssertTrue(app.textFields["login.username"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["login.submit"].exists)
        attachScreenshot("06-login-large-type")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
