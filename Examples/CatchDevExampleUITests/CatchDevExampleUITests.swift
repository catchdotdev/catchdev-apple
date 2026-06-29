import XCTest

/// End-to-end UI tests for the CatchDev reporter, driven through the example app.
///
/// XCUITest is black-box: it can only see the screen, so it (a) opens the reporter via
/// the app's manual-trigger button (there is no public API to simulate a device shake),
/// and (b) relies on the app's in-process server under `-CatchDevUITest` so Send succeeds
/// deterministically. Elements are found by the identifiers in `CatchDevReporterAccessibility`.
final class CatchDevExampleUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-CatchDevUITest"]
        app.launch()
        return app
    }

    /// Tap the manual trigger and wait for the reporter; returns the message field.
    @discardableResult
    private func openReporter(_ app: XCUIApplication) -> XCUIElement {
        let trigger = app.buttons["example.sendFeedback"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 10), "Example app should launch")
        trigger.tap()
        let message = app.textViews["catchdev.reporter.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "Reporter should appear")
        return message
    }

    func testReporterSubmitsFeedback() {
        let app = launchApp()
        let message = openReporter(app)

        message.tap()
        message.typeText("The checkout button is misaligned on small screens.")

        app.buttons["catchdev.reporter.send"].tap()

        // On the stubbed 200 the reporter dismisses, so the message field disappears.
        assertDisappears(message, timeout: 5)
    }

    func testCancelDismissesReporter() {
        let app = launchApp()
        let message = openReporter(app)

        app.buttons["catchdev.reporter.cancel"].tap()
        assertDisappears(message, timeout: 5)
    }

    func testEmptyMessageDoesNotDismiss() {
        let app = launchApp()
        let message = openReporter(app)

        // Sending with no text should be rejected (the field stays on screen).
        app.buttons["catchdev.reporter.send"].tap()
        XCTAssertTrue(message.exists, "Reporter should stay open when the message is empty")
    }

    func testReporterCanReopenAfterDismiss() {
        let app = launchApp()
        let message = openReporter(app)

        // Dismiss, then confirm the present-latch was cleared so it can reopen.
        app.buttons["catchdev.reporter.cancel"].tap()
        assertDisappears(message, timeout: 5)

        app.buttons["example.sendFeedback"].tap()
        XCTAssertTrue(
            message.waitForExistence(timeout: 5),
            "Reporter should reopen after a previous dismissal (latch cleared)"
        )
    }

    /// The headline end-to-end test: traverse several screens across tabs, open the
    /// reporter, send, and assert the SDK sent the current screen as `screenName` and the
    /// visited trail as breadcrumbs — read back from the mock server via the debug probe.
    func testReporterSendsCurrentScreenNameAndBreadcrumbs() {
        let app = launchApp()

        // Tab "Home": Home -> Product Detail.
        let toDetail = app.buttons["example.home.detail"]
        XCTAssertTrue(toDetail.waitForExistence(timeout: 10), "Home should be the first screen")
        toDetail.tap()
        let toReviews = app.buttons["example.detail.reviews"]
        XCTAssertTrue(toReviews.waitForExistence(timeout: 5), "Product Detail should be pushed")

        // Switch to tab "Explore": Explore -> Category.
        app.tabBars.buttons["Explore"].tap()
        let toCategory = app.buttons["example.explore.category"]
        XCTAssertTrue(toCategory.waitForExistence(timeout: 5), "Explore should appear")
        toCategory.tap()
        XCTAssertTrue(
            app.navigationBars["Category"].waitForExistence(timeout: 5),
            "Category should be pushed"
        )

        // Open the reporter on Category and send.
        app.buttons["example.sendFeedback"].tap()
        let message = app.textViews["catchdev.reporter.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "Reporter should appear")
        message.tap()
        message.typeText("Category page bug")
        app.buttons["catchdev.reporter.send"].tap()
        assertDisappears(message, timeout: 5)

        // The debug probe reflects the parsed payload once the server has received it.
        let screenNameProbe = app.staticTexts["catchdev.debug.lastScreenName"]
        let matched = expectation(
            for: NSPredicate(format: "label == %@", "Category"),
            evaluatedWith: screenNameProbe
        )
        wait(for: [matched], timeout: 10)

        let trail = app.staticTexts["catchdev.debug.lastBreadcrumbs"].label
        let screens = trail.components(separatedBy: " > ")
        XCTAssertEqual(screens.last, "Category", "Last breadcrumb should be the current screen")
        XCTAssertFalse(screens.contains("Send feedback"), "Reporter screen must be filtered out")
        XCTAssertTrue(
            Self.isOrderedSubsequence(["Home", "Product Detail", "Explore", "Category"], of: screens),
            "Breadcrumbs should contain the visited screens in order — got: \(trail)"
        )
    }

    /// `waitForNonExistence(timeout:)` requires Xcode 15+; this predicate form works everywhere.
    private func assertDisappears(_ element: XCUIElement, timeout: TimeInterval) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: timeout)
    }

    /// True if `needle` appears as an in-order (not necessarily contiguous) subsequence of `haystack`.
    private static func isOrderedSubsequence(_ needle: [String], of haystack: [String]) -> Bool {
        var index = 0
        for item in haystack where index < needle.count && item == needle[index] {
            index += 1
        }
        return index == needle.count
    }
}
