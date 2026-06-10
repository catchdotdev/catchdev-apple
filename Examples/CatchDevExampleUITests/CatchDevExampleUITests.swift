import XCTest

/// End-to-end UI tests for the CatchDev reporter, driven through the example app.
///
/// XCUITest is black-box: it can only see the screen, so it (a) opens the reporter via
/// the app's manual-trigger button (there is no public API to simulate a device shake),
/// and (b) relies on the app stubbing the network under `-CatchDevUITest` so Send
/// succeeds deterministically. Elements are found by the accessibility identifiers in
/// `CatchDevReporterAccessibility`.
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

    func testReporterSubmitsFeedback() {
        let app = launchApp()

        app.buttons["example.sendFeedback"].tap()

        let message = app.textViews["catchdev.reporter.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "Reporter should appear")

        message.tap()
        message.typeText("The checkout button is misaligned on small screens.")

        app.buttons["catchdev.reporter.send"].tap()

        // On the stubbed 200 the reporter dismisses, so the message field disappears.
        assertDisappears(message, timeout: 5)
    }

    func testCancelDismissesReporter() {
        let app = launchApp()

        app.buttons["example.sendFeedback"].tap()
        let message = app.textViews["catchdev.reporter.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))

        app.buttons["catchdev.reporter.cancel"].tap()
        assertDisappears(message, timeout: 5)
    }

    func testEmptyMessageDoesNotDismiss() {
        let app = launchApp()

        app.buttons["example.sendFeedback"].tap()
        let message = app.textViews["catchdev.reporter.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))

        // Sending with no text should be rejected (the field stays on screen).
        app.buttons["catchdev.reporter.send"].tap()
        XCTAssertTrue(message.exists, "Reporter should stay open when the message is empty")
    }

    /// `waitForNonExistence(timeout:)` requires Xcode 15+; this predicate form works everywhere.
    private func assertDisappears(_ element: XCUIElement, timeout: TimeInterval) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: timeout)
    }
}
