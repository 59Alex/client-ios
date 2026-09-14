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
        XCTAssertTrue(app.buttons["home.tab.chats"].waitForExistence(timeout: 10))
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
    func testEmojiSelectionFormatAndDelete() throws {
        let app = launchSignedIn()
        let row = app.buttons["chats.row.room-qa-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Смайл ")
        app.buttons["chat.emoji"].tap()
        let search = app.textFields["emoji.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("пицца")
        let pizza = app.buttons["emoji.🍕"]
        XCTAssertTrue(pizza.waitForExistence(timeout: 5))
        attachScreenshot("24-emoji")
        pizza.tap()
        app.buttons["emoji.done"].tap()
        XCTAssertEqual(input.value as? String, "Смайл 🍕")
        app.buttons["chat.send"].tap()

        let sent = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Смайл 🍕'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        sent.press(forDuration: 1.0)
        let select = app.buttons["Выделить"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()

        let count = app.staticTexts["chat.selection.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "Выбрано: 1")
        app.buttons["chat.format.bold"].tap()
        attachScreenshot("25-selection")
        app.buttons["chat.selection.delete"].tap()
        let confirm = app.buttons["Удалить: 1"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(sent.waitForExistence(timeout: 2))
    }

    @MainActor
    func testRestoresLastOpenChatAfterRelaunch() throws {
        let app = launchSignedIn()
        app.buttons["home.tab.groups"].tap()
        let group = app.buttons["chats.row.group-1"]
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        group.tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 10))
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-ui-test-stub", "-ui-test-signed-in", "-ui-test-keep-navigation"]
        relaunched.launch()
        XCTAssertTrue(relaunched.textFields["chat.input"].waitForExistence(timeout: 10))
        XCTAssertTrue(relaunched.buttons["chat.members"].exists)
        attachScreenshot("26-restored-group-chat")
        relaunched.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(relaunched.buttons["home.tab.groups"].waitForExistence(timeout: 5))
        XCTAssertTrue(relaunched.buttons["home.tab.groups"].isSelected)
    }

    @MainActor
    func testGroupsTabAndEmptyChat() throws {
        let app = launchSignedIn()

        app.buttons["home.tab.groups"].tap()
        let group = app.buttons["chats.row.group-1"]
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 изображения"].exists)
        attachScreenshot("23-groups")

        group.tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testFindAddContactAndOpenChat() throws {
        let app = launchSignedIn()
        app.buttons["home.tab.contacts"].tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("qa_wallpaper_4\n")

        let add = app.buttons["contacts.search.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        attachScreenshot("30-contact-found")
        add.tap()
        XCTAssertTrue(app.staticTexts["QA Wallpaper Four"].waitForExistence(timeout: 5))
        XCTAssertFalse(add.exists)

        let contact = app.buttons["contacts.call.qa_wallpaper_2"]
        if !contact.waitForExistence(timeout: 3) {
            app.buttons["Cancel"].firstMatch.tap()
        }
        XCTAssertTrue(contact.waitForExistence(timeout: 5))
        app.staticTexts["QA Wallpaper Two"].press(forDuration: 1.0)
        let write = app.buttons["Написать"]
        XCTAssertTrue(write.waitForExistence(timeout: 5))
        attachScreenshot("31-contact-menu")
        write.tap()

        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.tab.contacts"].exists)
        attachScreenshot("32-chat-from-contact")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
