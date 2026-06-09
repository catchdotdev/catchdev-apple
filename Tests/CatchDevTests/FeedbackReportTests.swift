import XCTest
@testable import CatchDev

final class FeedbackReportTests: XCTestCase {
    func testDefaults() {
        let report = FeedbackReport(message: "hi")
        XCTAssertEqual(report.sdk, "catchdev-apple")
        XCTAssertEqual(report.sdkVersion, SDKInfo.version)
        XCTAssertEqual(report.imageContentType, "image/jpeg")
        XCTAssertFalse(report.time.isEmpty)
    }

    func testMetadataJSONIsNilWhenEmpty() {
        let report = FeedbackReport(message: "hi")
        XCTAssertNil(report.metadataJSONString)
    }

    func testMetadataJSONIsSortedAndStable() {
        var report = FeedbackReport(message: "hi")
        report.metadata = ["b": "2", "a": "1"]
        XCTAssertEqual(report.metadataJSONString, "{\"a\":\"1\",\"b\":\"2\"}")
    }

    func testApplyDeviceContextPopulatesFields() {
        var report = FeedbackReport(message: "hi")
        report.applyDeviceContext()
        XCTAssertFalse(report.osVersion?.isEmpty ?? true)
        XCTAssertFalse(report.device?.isEmpty ?? true)
        XCTAssertFalse(report.platform?.isEmpty ?? true)
    }
}
