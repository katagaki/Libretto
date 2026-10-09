import XCTest

/// Stages and captures the App Store screenshots.
///
/// Driven by `Assets/App Store/capture.sh`, which seeds the documents these
/// open and says where to write through `SCREENSHOT_DIR` and which language to
/// use through `SCREENSHOT_LANGUAGE`. Without them the tests skip, so they stay
/// out of the way of an ordinary test run.
@MainActor
final class AppStoreScreenshots: XCTestCase {
    private enum Mode {
        case page, reader, code
    }

    private struct Shot {
        let name: String
        /// The file name as the browser shows it, keyed by language.
        let document: [String: String]
        var mode = Mode.page
        /// Where on the screen to tap first, as a fraction of the window.
        var tap: CGVector?
        /// Whether that tap is a double tap, which picks out a word.
        var selectsWord = false
        /// A key on the floating bar to press once the document is open.
        var key: String?
        var isDark = false
    }

    private static let report = ["en": "Schale Activity Report", "ja": "シャーレ活動報告書"]
    private static let proposal = ["en": "Festival Proposal", "ja": "合同祭企画書"]
    private static let notes = ["en": "Railgun Notes", "ja": "レールガン調整ノート"]
    private static let code = ["en": "Battle", "ja": "Battle"]

    private static let iPhoneShots = [
        Shot(name: "01-document", document: report),
        Shot(name: "02-reader", document: report, mode: .reader),
        Shot(
            name: "03-format", document: report, tap: CGVector(dx: 0.2, dy: 0.2), selectsWord: true,
            key: "action.paintpalette"
        ),
        // The bar learns that changes are tracked once the selection moves, so the text is tapped first.
        Shot(name: "04-review", document: proposal, tap: CGVector(dx: 0.5, dy: 0.31), key: "trackingOn"),
        Shot(name: "05-equations", document: notes),
        Shot(name: "06-code", document: code, mode: .code),
        Shot(name: "07-dark", document: proposal, isDark: true),
    ]

    private static let iPadShots = [
        Shot(name: "01-document", document: report),
        Shot(
            name: "02-format", document: report, tap: CGVector(dx: 0.3, dy: 0.155), selectsWord: true,
            key: "action.paintpalette"
        ),
        Shot(name: "03-review", document: proposal, tap: CGVector(dx: 0.5, dy: 0.31), key: "trackingOn"),
        Shot(name: "04-equations", document: notes),
        Shot(name: "05-code", document: code, mode: .code),
        Shot(name: "06-dark", document: proposal, isDark: true),
    ]

    private var directory: URL!
    private var language = "en"
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("run through Assets/App Store/capture.sh")
        }
        directory = URL(fileURLWithPath: path)
        language = environment["SCREENSHOT_LANGUAGE"] ?? "en"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testScreens() throws {
        defer { XCUIDevice.shared.appearance = .light }
        // A comma-separated list of screenshots to retake, rather than all of them.
        let only = (ProcessInfo.processInfo.environment["SCREENSHOT_ONLY"] ?? "").split(separator: ",").map(String.init)
        try capture(shots.filter { only.isEmpty || only.contains($0.name) })
    }

    private var shots: [Shot] {
        UIDevice.current.userInterfaceIdiom == .pad ? Self.iPadShots : Self.iPhoneShots
    }

    private func capture(_ shots: [Shot]) throws {
        for shot in shots {
            let appearance: XCUIDevice.Appearance = shot.isDark ? .dark : .light
            if XCUIDevice.shared.appearance != appearance {
                // The system takes a while to go over, and an app open across it, or launched
                // before it has, can stay as it was.
                app?.terminate()
                XCUIDevice.shared.appearance = appearance
                sleep(5)
            }
            launch()
            open(try XCTUnwrap(shot.document[language]), mode: shot.mode)
            if let tap = shot.tap {
                let point = app.windows.firstMatch.coordinate(withNormalizedOffset: tap)
                if shot.selectsWord { point.doubleTap() } else { point.tap() }
                sleep(1)
            }
            if let key = shot.key {
                let button = app.buttons[key].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 5), "missing \(key) key")
                // On iPhone the bar is wider than the screen, and its far end is scrolled to.
                let bar = app.scrollViews.containing(.button, identifier: "action.bold").firstMatch
                let window = app.windows.firstMatch.frame
                for _ in 0..<3 where !window.contains(button.frame) {
                    bar.swipeLeft()
                }
                button.tap()
            }
            // Let the pages, and any panel, finish drawing and animating in.
            Thread.sleep(forTimeInterval: 2.5)
            let file = directory.appendingPathComponent("\(shot.name).png")
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
        }
    }

    // MARK: - Steps

    private func launch() {
        app = XCUIApplication()
        let locale = language == "ja" ? "ja_JP" : "en_US"
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
    }

    /// Opens a document from the app's folder in the document browser, in the mode given.
    private func open(_ name: String, mode: Mode) {
        let browse = app.buttons[language == "ja" ? "ブラウズ" : "Browse"].firstMatch
        if !browse.waitForExistence(timeout: 30) {
            // The app put back the document it last had open; go back to the browser.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(browse.waitForExistence(timeout: 10), "the document browser never appeared")
        }
        if !browse.isSelected {
            browse.tap()
        }

        // The cell, not its name: a tap on the name label does not open the file. Its label
        // starts with the name, which for some types still has its extension on the end.
        let file = app.collectionViews.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "\(name) is not in the browser")
        // On iPhone the browser starts as a sheet that only shows its first rows.
        if !file.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        file.tap()

        let pages = app.scrollViews["pages"]
        let reader = app.scrollViews["mobileReader"]
        let code = app.textViews["codeText"]
        let opened = NSPredicate { _, _ in pages.exists || reader.exists || code.exists }
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation(for: opened, evaluatedWith: nil)], timeout: 20), .completed,
            "\(name) never opened"
        )

        switch mode {
        case .page:
            if !pages.exists {
                app.buttons["editInPageView"].tap()
                XCTAssertTrue(pages.waitForExistence(timeout: 5), "\(name) never went to the pages")
            }
        case .reader:
            XCTAssertTrue(reader.exists, "\(name) did not open in the reader")
        case .code:
            XCTAssertTrue(code.exists, "\(name) did not open as code")
        }
    }
}
