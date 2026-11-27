import XCTest
@_spi(CatchDevTesting) import CatchDev

/// A report carries at most 10 attachments, the automatic screenshot included (the backend keeps
/// no more). At that count the reporter stops offering to add one: Attach and Record are
/// disabled and "Up to 10 attachments" shows. The Screenshot tool stays usable while a
/// screenshot is attached, because it then marks that one up instead of adding another. A file
/// still being read counts too.
final class ReporterAttachmentLimitTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var files: [URL] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        files = []
        super.tearDown()
    }

    /// A reporter on screen, reopened with `count` attachments (a screenshot first if asked).
    private func showReporter(attachments count: Int, screenshot: Bool) -> UIViewController {
        let reporter = CatchDevReporterTesting.makeReporter(attachments: count, screenshot: screenshot)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = reporter
        window.makeKeyAndVisible()
        reporter.view.layoutIfNeeded()
        windows.append(window)
        return reporter
    }

    private func find(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        for subview in view.subviews {
            if let hit = find(id, in: subview) { return hit }
        }
        return nil
    }

    private func isEnabled(_ id: String, in reporter: UIViewController) throws -> Bool {
        try XCTUnwrap(find(id, in: reporter.view) as? UIButton, "no button \(id)").isEnabled
    }

    private func hint(in reporter: UIViewController) throws -> UILabel {
        try XCTUnwrap(find(CatchDevReporterAccessibility.attachmentLimit, in: reporter.view) as? UILabel)
    }

    func testBelowTheLimitEveryToolWorksAndNoHintShows() throws {
        let reporter = showReporter(attachments: 9, screenshot: true)
        XCTAssertTrue(try isEnabled(CatchDevReporterAccessibility.toolScreenshot, in: reporter))
        XCTAssertTrue(try isEnabled(CatchDevReporterAccessibility.toolRecord, in: reporter))
        XCTAssertTrue(try isEnabled(CatchDevReporterAccessibility.toolAttach, in: reporter))
        XCTAssertTrue(try hint(in: reporter).isHidden)
    }

    func testAtTheLimitAttachAndRecordAreDisabledAndTheHintShows() throws {
        let reporter = showReporter(attachments: 10, screenshot: true)
        XCTAssertFalse(try isEnabled(CatchDevReporterAccessibility.toolAttach, in: reporter))
        XCTAssertFalse(try isEnabled(CatchDevReporterAccessibility.toolRecord, in: reporter))
        XCTAssertTrue(
            try isEnabled(CatchDevReporterAccessibility.toolScreenshot, in: reporter),
            "it marks up the attached screenshot, which adds nothing"
        )
        let label = try hint(in: reporter)
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(label.text, "Up to 10 attachments")
    }

    func testAtTheLimitWithTheScreenshotRemovedTheScreenshotToolIsDisabledToo() throws {
        let reporter = showReporter(attachments: 10, screenshot: false)
        XCTAssertFalse(
            try isEnabled(CatchDevReporterAccessibility.toolScreenshot, in: reporter),
            "it would add the screenshot back, an eleventh attachment"
        )
        XCTAssertFalse(try isEnabled(CatchDevReporterAccessibility.toolAttach, in: reporter))
        XCTAssertFalse(try hint(in: reporter).isHidden)
    }

    /// The tenth attachment is a picked file whose bytes are still being read (an iCloud file
    /// can take a while). It already counts, so a second pick can't slip in meanwhile.
    func testAFileStillBeingReadCountsTowardTheLimit() throws {
        let reporter = showReporter(attachments: 9, screenshot: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catchdev-\(UUID().uuidString).txt")
        try Data("picked".utf8).write(to: file)
        files.append(file)

        CatchDevReporterTesting.pick(file, in: reporter)
        XCTAssertFalse(try isEnabled(CatchDevReporterAccessibility.toolAttach, in: reporter), "full while the read is in flight")
        XCTAssertFalse(try hint(in: reporter).isHidden)

        let tenth = CatchDevReporterAccessibility.attachment(9)
        let deadline = Date().addingTimeInterval(5)
        while find(tenth, in: reporter.view) == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(find(tenth, in: reporter.view), "the file landed as the tenth attachment")
        XCTAssertFalse(try isEnabled(CatchDevReporterAccessibility.toolAttach, in: reporter), "and the report is full")
    }
}
