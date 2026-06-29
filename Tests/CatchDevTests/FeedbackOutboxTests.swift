import XCTest
@testable import CatchDev

final class FeedbackOutboxTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catchdev-outbox-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func report(id: String, time: String, message: String = "hi", image: Data? = nil) -> FeedbackReport {
        var report = FeedbackReport(message: message)
        report.reportId = id
        report.time = time
        report.imageData = image
        return report
    }

    func testEnqueueThenPendingRoundTripsTheReport() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1", message: "hello"))
        let pending = outbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.reportId, "a")
        XCTAssertEqual(pending.first?.message, "hello")
    }

    func testScreenshotIsPersistedAndRestored() throws {
        let outbox = FeedbackOutbox(directory: dir)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])
        try outbox.enqueue(report(id: "a", time: "t1", image: jpeg))
        XCTAssertEqual(outbox.pending().first?.imageData, jpeg)
    }

    func testReportWithoutScreenshotRoundTripsWithNilImage() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1", image: nil))
        XCTAssertNil(outbox.pending().first?.imageData)
    }

    func testPendingIsOrderedOldestFirstByReportTime() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "c", time: "2026-01-03"))
        try outbox.enqueue(report(id: "a", time: "2026-01-01"))
        try outbox.enqueue(report(id: "b", time: "2026-01-02"))
        XCTAssertEqual(outbox.pending().map(\.reportId), ["a", "b", "c"])
    }

    func testRemoveDeletesOnlyTheNamedEntry() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"))
        try outbox.enqueue(report(id: "b", time: "t2"))
        outbox.remove(reportId: "a")
        XCTAssertEqual(outbox.pending().map(\.reportId), ["b"])
        XCTAssertEqual(outbox.count, 1)
    }

    func testEnqueueBeyondCapacityDropsOldest() throws {
        let outbox = FeedbackOutbox(directory: dir, maxEntries: 2)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"))
        try outbox.enqueue(report(id: "b", time: "2026-01-02"))
        try outbox.enqueue(report(id: "c", time: "2026-01-03"))
        XCTAssertEqual(outbox.pending().map(\.reportId), ["b", "c"])
    }

    func testCorruptEntryIsSkipped() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"))
        let bogus = dir.appendingPathComponent("bogus", isDirectory: true)
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: bogus.appendingPathComponent("report.json"))
        XCTAssertEqual(outbox.pending().map(\.reportId), ["a"])
    }

    func testCountReflectsEnqueuedReports() throws {
        let outbox = FeedbackOutbox(directory: dir)
        XCTAssertEqual(outbox.count, 0)
        try outbox.enqueue(report(id: "a", time: "t1"))
        XCTAssertEqual(outbox.count, 1)
    }
}
