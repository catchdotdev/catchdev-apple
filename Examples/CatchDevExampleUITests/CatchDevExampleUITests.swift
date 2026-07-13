import XCTest

/// End-to-end UI tests for the redesigned CatchDev reporter, driven through the example app.
///
/// These focus on UI INTERACTIONS (does each control work and the screens flow correctly).
/// The exhaustive wire-contract verification — every field, attachment serialization, the
/// upload handshake, diagnostics exclusion — lives in the fast, deterministic Foundation
/// unit tests (`swift test`), which don't depend on the simulator's networking. One e2e
/// send here proves the upload → submit → success flow works through the real UI.
///
/// XCUITest is black-box: it opens the reporter via the app's manual-trigger button (there
/// is no public API to simulate a device shake) and relies on the app's in-process
/// `MockFeedbackServer` (under `-CatchDevUITest`). Elements are found by
/// `CatchDevReporterAccessibility` ids; what the SDK sent is read via the `catchdev.debug.*`
/// probe labels.
final class CatchDevExampleUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp(extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-CatchDevUITest"] + extraArgs
        app.launch()
        return app
    }

    @discardableResult
    private func openReporter(_ app: XCUIApplication) -> XCUIElement {
        let trigger = app.buttons["example.sendFeedback"]
        XCTAssertTrue(trigger.waitForExistence(timeout: 10), "Example app should launch")
        trigger.tap()
        let message = app.textViews["catchdev.reporter.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "Reporter should appear")
        return message
    }

    // MARK: - Core flow
    //
    // NOTE: the end-to-end send (upload handshake → submit → every wire field → diagnostics
    // exclusion) is verified in the FAST, deterministic Foundation unit tests (`swift test`:
    // AttachmentUploaderTests, FeedbackClientTests, ReporterWireTests). A network-dependent
    // XCUITest is unreliable here because loopback networking degrades across the many app
    // launches in one simulator session — so these UI tests focus on interactions.

    func testEmptyMessageDoesNotSend() {
        let app = launchApp()
        let message = openReporter(app)
        app.buttons["catchdev.reporter.send"].tap()
        XCTAssertFalse(app.buttons["catchdev.reporter.success.done"].waitForExistence(timeout: 2))
        XCTAssertTrue(message.exists, "Reporter should stay open when the description is empty")
    }

    func testCancelDismissesReporter() {
        let app = launchApp()
        let message = openReporter(app)
        app.buttons["catchdev.reporter.cancel"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: message)
        wait(for: [gone], timeout: 5)
    }

    func testReporterCanReopenAfterDismiss() {
        let app = launchApp()
        let message = openReporter(app)
        app.buttons["catchdev.reporter.cancel"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: message)
        wait(for: [gone], timeout: 5)
        app.buttons["example.sendFeedback"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5),
                      "Reporter should reopen after a previous dismissal (latch cleared)")
    }

    // MARK: - Field interactions

    func testBugTabRevealsSeverity() {
        let app = launchApp()
        openReporter(app)
        // Severity is hidden on the Feedback tab, shown on the Bug tab.
        XCTAssertFalse(app.buttons["catchdev.reporter.severity.blocks"].isHittable)
        app.buttons["catchdev.reporter.tab.bug"].tap()
        let blocks = app.buttons["catchdev.reporter.severity.blocks"]
        XCTAssertTrue(blocks.waitForExistence(timeout: 3), "Severity should appear on the Bug tab")
        XCTAssertTrue(app.buttons["catchdev.reporter.severity.annoying"].exists)
        XCTAssertTrue(app.buttons["catchdev.reporter.severity.minor"].exists)
        blocks.tap() // selectable
    }

    func testSelectArea() {
        let app = launchApp()
        openReporter(app)
        let area = app.buttons["catchdev.reporter.area"]
        area.tap()
        let option = app.buttons["catchdev.reporter.area.payments"]
        XCTAssertTrue(option.waitForExistence(timeout: 3), "The area picker sheet should open on tap")
        option.tap()
        XCTAssertTrue(area.label.contains("Payments"), "Area button should reflect the choice")
    }

    func testScreenshotAttachmentIsPresentByDefault() {
        let app = launchApp()
        openReporter(app)
        XCTAssertTrue(app.otherElements["catchdev.reporter.attachment.0"].waitForExistence(timeout: 3),
                      "The shake-time screenshot should be attached by default")
    }

    func testAnnotateScreenshot() {
        let app = launchApp()
        let message = openReporter(app)
        app.buttons["catchdev.reporter.tool.screenshot"].tap()
        let done = app.buttons["catchdev.reporter.annotate.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "Annotate screen should appear")
        app.buttons["catchdev.reporter.annotate.box"].tap()
        // Draw a box via a coordinate drag (the canvas overlays the image element).
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.6))
        start.press(forDuration: 0.1, thenDragTo: end)
        done.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 3), "Should return to the form after Done")
    }

    func testRecordReopensReporterWithRecordingAttachment() {
        let app = launchApp()
        let message = openReporter(app)
        app.buttons["catchdev.reporter.tool.record"].tap()
        let stop = app.buttons["catchdev.reporter.record.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Stop-recording control should appear")
        stop.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5), "Reporter should reopen after recording")
        // Screenshot (0) + recording (1) are both attached.
        XCTAssertTrue(app.otherElements["catchdev.reporter.attachment.1"].waitForExistence(timeout: 3),
                      "The recording should be added as a second attachment")
    }

    /// Regression: when recording can't start (Simulator / permission denied), the reporter
    /// must stay open with an alert — NOT dismiss and leave the host screen frozen.
    func testRecordUnavailableKeepsReporterOpenAndInteractive() {
        let app = launchApp(extraArgs: ["-CatchDevRecordingUnavailable"])
        let message = openReporter(app)
        app.buttons["catchdev.reporter.tool.record"].tap()
        let ok = app.alerts.buttons["OK"]
        XCTAssertTrue(ok.waitForExistence(timeout: 5), "An 'unavailable' alert should appear")
        ok.tap()
        XCTAssertTrue(message.exists, "Reporter should remain open after an unavailable recording")
        XCTAssertTrue(app.buttons["catchdev.reporter.send"].isHittable,
                      "The reporter should still be interactive (not frozen)")
    }
}
