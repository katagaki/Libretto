import XCTest

/// Drives a new document end to end: typing on the page, formatting from the
/// floating bar, and reading it back in the mobile view.
@MainActor
final class DocumentUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Gets to an open document, whether the app restored one or the
    /// document browser is waiting for us to make a new one.
    private func openDocument(_ app: XCUIApplication) {
        let pages = app.scrollViews["pages"]
        let reader = app.scrollViews["mobileReader"]
        if pages.waitForExistence(timeout: 5) || reader.exists { return }
        let create = app.buttons["Create Document"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), "the document browser never appeared")
        create.tap()
        XCTAssertTrue(
            pages.waitForExistence(timeout: 20) || reader.waitForExistence(timeout: 5),
            "the new document never opened"
        )
    }

    private func switchMode(_ app: XCUIApplication, to label: String) {
        app.navigationBars.buttons["More"].firstMatch.tap()
        let picker = app.buttons["View"]
        if picker.waitForExistence(timeout: 3) { picker.tap() }
        app.buttons[label].firstMatch.tap()
    }

    func testTypeFormatAndRead() throws {
        let app = XCUIApplication.launchedInEnglish()
        openDocument(app)
        if !app.scrollViews["pages"].exists {
            app.buttons["editInPageView"].tap()
        }

        let text = app.textViews["documentText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeText("Libretto keeps your words.")
        capture(app, "typed")

        // A tap synthesised the moment typing stops is dropped before it
        // reaches the bar; one a moment later, as a finger's would be, is not.
        sleep(1)
        let bold = app.buttons["action.bold"]
        bold.tap()
        let lit = NSPredicate(format: "isSelected == true")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: lit, evaluatedWith: bold)], timeout: 3), .completed,
                       "Bold did not light up")
        text.typeText(" Bold words.")
        capture(app, "bold")

        switchMode(app, to: "Mobile View")
        XCTAssertTrue(app.scrollViews["mobileReader"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Libretto keeps your words. Bold words."].waitForExistence(timeout: 5))
        capture(app, "mobile")
    }
}
