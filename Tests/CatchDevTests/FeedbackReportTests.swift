import XCTest
@testable import CatchDev

final class FeedbackReportTests: XCTestCase {
    func testDefaults() {
        let report = FeedbackReport(message: "hi")
        XCTAssertEqual(report.sdk, "catchdev-apple")
        XCTAssertEqual(report.sdkVersion, SDKInfo.version)
        XCTAssertEqual(report.imageContentType, "image/jpeg")
        XCTAssertFalse(report.time.isEmpty)
        XCTAssertTrue(report.breadcrumbs.isEmpty)
        XCTAssertNil(report.screenName)
    }

    func testMetaJSONIsNilWhenEmpty() {
        let report = FeedbackReport(message: "hi")
        XCTAssertNil(report.metaJSONString)
    }

    // Regression: with metadata only (no breadcrumbs) the output must be byte-identical
    // to the old metadata-only JSON so the wire format doesn't change for existing apps.
    func testMetaJSONMetadataOnlyIsSortedAndStable() {
        var report = FeedbackReport(message: "hi")
        report.metadata = ["b": "2", "a": "1"]
        XCTAssertEqual(report.metaJSONString, "{\"a\":\"1\",\"b\":\"2\"}")
    }

    func testMetaJSONBreadcrumbsOnly() {
        var report = FeedbackReport(message: "hi")
        report.breadcrumbs = [
            Breadcrumb(screen: "A", time: "t1"),
            Breadcrumb(screen: "B", time: "t2"),
        ]
        XCTAssertEqual(
            report.metaJSONString,
            "{\"catchdev.breadcrumbs\":[{\"screen\":\"A\",\"time\":\"t1\"},{\"screen\":\"B\",\"time\":\"t2\"}]}"
        )
    }

    func testMetaJSONMergesMetadataAndBreadcrumbsWithoutClobber() {
        var report = FeedbackReport(message: "hi")
        report.metadata = ["z": "1"]
        report.breadcrumbs = [Breadcrumb(screen: "A", time: "t1")]
        // Top-level keys are sorted: "catchdev.breadcrumbs" < "z".
        XCTAssertEqual(
            report.metaJSONString,
            "{\"catchdev.breadcrumbs\":[{\"screen\":\"A\",\"time\":\"t1\"}],\"z\":\"1\"}"
        )
    }

    // If a user reuses the reserved key, the SDK's breadcrumbs win for that key, but the
    // user's other keys are untouched.
    func testMetaJSONReservedKeyCollisionSDKWins() {
        var report = FeedbackReport(message: "hi")
        report.metadata = ["catchdev.breadcrumbs": "userValue", "keep": "me"]
        report.breadcrumbs = [Breadcrumb(screen: "A", time: "t1")]
        let json = report.metaJSONString ?? ""
        XCTAssertTrue(json.contains("\"catchdev.breadcrumbs\":[{\"screen\":\"A\",\"time\":\"t1\"}]"))
        XCTAssertFalse(json.contains("userValue"))
        XCTAssertTrue(json.contains("\"keep\":\"me\""))
    }

    // A user reusing the reserved key keeps their value when there are NO breadcrumbs —
    // the SDK only overwrites it when it actually has a trail to write.
    func testReservedKeyPreservedWhenNoBreadcrumbs() {
        var report = FeedbackReport(message: "hi")
        report.metadata = ["catchdev.breadcrumbs": "userValue", "k": "v"]
        let json = report.metaJSONString ?? ""
        XCTAssertTrue(json.contains("\"catchdev.breadcrumbs\":\"userValue\""))
        XCTAssertTrue(json.contains("\"k\":\"v\""))
    }

    // Screen names / metadata can contain quotes, newlines, emoji, backslashes — the JSON
    // must escape them and round-trip back to the exact value.
    func testMetaJSONEscapesSpecialCharacters() throws {
        var report = FeedbackReport(message: "hi")
        let weird = "He said \"hi\"\nLine2 😀 a\\b"
        report.breadcrumbs = [Breadcrumb(screen: weird, time: "t1")]
        report.metadata = ["key\"x": "val\nue"]

        let json = try XCTUnwrap(report.metaJSONString)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let crumbs = try XCTUnwrap(object["catchdev.breadcrumbs"] as? [[String: Any]])
        XCTAssertEqual(crumbs.first?["screen"] as? String, weird)
        XCTAssertEqual(object["key\"x"] as? String, "val\nue")
        // The raw JSON must contain escaped quotes, not a bare unescaped one.
        XCTAssertTrue(json.contains("\\\"hi\\\""))
    }

    func testApplyDeviceContextPopulatesFields() {
        var report = FeedbackReport(message: "hi")
        report.applyDeviceContext()
        XCTAssertFalse(report.osVersion?.isEmpty ?? true)
        XCTAssertFalse(report.device?.isEmpty ?? true)
        XCTAssertFalse(report.platform?.isEmpty ?? true)
    }
}
