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

    private func blob(_ bytes: Int, kind: AttachmentKind = .screenshot) -> PendingBlob {
        PendingBlob(
            kind: kind, data: Data(repeating: 0xAB, count: bytes),
            contentType: "image/jpeg", filename: "a.jpg", annotated: false
        )
    }

    // MARK: - Report round-trip

    func testEnqueueThenPendingRoundTripsTheReport() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1", message: "hello"))
        let pending = outbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.report.reportId, "a")
        XCTAssertEqual(pending.first?.report.message, "hello")
    }

    func testScreenshotIsPersistedAndRestored() throws {
        let outbox = FeedbackOutbox(directory: dir)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])
        try outbox.enqueue(report(id: "a", time: "t1", image: jpeg))
        XCTAssertEqual(outbox.pending().first?.report.imageData, jpeg)
    }

    func testReportWithoutScreenshotRoundTripsWithNilImage() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1", image: nil))
        XCTAssertNil(outbox.pending().first?.report.imageData)
    }

    func testPendingIsOrderedOldestFirstByReportTime() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "c", time: "2026-01-03"))
        try outbox.enqueue(report(id: "a", time: "2026-01-01"))
        try outbox.enqueue(report(id: "b", time: "2026-01-02"))
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["a", "b", "c"])
    }

    func testRemoveDeletesOnlyTheNamedEntry() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"))
        try outbox.enqueue(report(id: "b", time: "t2"))
        outbox.remove(reportId: "a")
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["b"])
        XCTAssertEqual(outbox.count, 1)
    }

    func testCorruptEntryIsSkipped() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"))
        let bogus = dir.appendingPathComponent("bogus", isDirectory: true)
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: bogus.appendingPathComponent("report.json"))
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["a"])
    }

    func testCountReflectsEnqueuedReports() throws {
        let outbox = FeedbackOutbox(directory: dir)
        XCTAssertEqual(outbox.count, 0)
        try outbox.enqueue(report(id: "a", time: "t1"))
        XCTAssertEqual(outbox.count, 1)
    }

    // MARK: - Pending attachment blobs

    func testEnqueuePersistsPendingBlobBytesAndMetadata() throws {
        let outbox = FeedbackOutbox(directory: dir)
        let recording = PendingBlob(
            kind: .recording, data: Data(repeating: 0x07, count: 128),
            contentType: "video/mp4", filename: "clip.mp4", annotated: false
        )
        try outbox.enqueue(report(id: "a", time: "t1"), blobs: [blob(64), recording])

        let entry = try XCTUnwrap(outbox.pending().first)
        XCTAssertEqual(entry.blobs.map(\.index), [0, 1], "blob indices are stable and ordered")
        XCTAssertEqual(entry.blobs[0].kind, .screenshot)
        XCTAssertEqual(entry.blobs[0].size, 64)
        XCTAssertEqual(entry.blobs[1].kind, .recording)
        XCTAssertEqual(entry.blobs[1].contentType, "video/mp4")
        XCTAssertEqual(entry.blobs[1].filename, "clip.mp4")
        XCTAssertTrue(entry.report.attachments.isEmpty, "nothing is uploaded yet")

        XCTAssertEqual(outbox.blobData(reportId: "a", index: 0)?.count, 64)
        XCTAssertEqual(outbox.blobData(reportId: "a", index: 1), recording.data)
    }

    func testMarkUploadedAppendsAttachmentRefAndDeletesTheBlob() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"), blobs: [blob(64), blob(32)])

        let attachment = Attachment(
            key: "feedback/uploads/x.jpg", kind: .screenshot,
            contentType: "image/jpeg", size: 64, filename: "a.jpg", annotated: nil
        )
        outbox.markUploaded(reportId: "a", blobIndex: 0, attachment: attachment)

        let entry = try XCTUnwrap(outbox.pending().first)
        XCTAssertEqual(entry.report.attachments, [attachment], "the ref is persisted into report.json")
        XCTAssertEqual(entry.blobs.map(\.index), [1], "the uploaded blob's bytes are dropped")
        XCTAssertNil(outbox.blobData(reportId: "a", index: 0))
        XCTAssertEqual(outbox.blobData(reportId: "a", index: 1)?.count, 32)
    }

    func testMarkUploadedIsIdempotent() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"), blobs: [blob(16)])
        let attachment = Attachment(
            key: "feedback/uploads/x.jpg", kind: .screenshot,
            contentType: "image/jpeg", size: 16, filename: "a.jpg", annotated: nil
        )
        outbox.markUploaded(reportId: "a", blobIndex: 0, attachment: attachment)
        outbox.markUploaded(reportId: "a", blobIndex: 0, attachment: attachment)
        XCTAssertEqual(outbox.pending().first?.report.attachments.count, 1)
    }

    /// Idempotency must key on the BLOB, not on the `Attachment` value: a second upload of the
    /// same bytes gets a different R2 key, so the two references are never equal. Recording
    /// both would list the same screenshot twice in the delivered report.
    func testMarkUploadedIgnoresASecondUploadOfTheSameBlobEvenWithADifferentKey() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"), blobs: [blob(16)])
        let first = Attachment(
            key: "feedback/uploads/1.jpg", kind: .screenshot,
            contentType: "image/jpeg", size: 16, filename: "a.jpg", annotated: nil
        )
        let second = Attachment(
            key: "feedback/uploads/2.jpg", kind: .screenshot,
            contentType: "image/jpeg", size: 16, filename: "a.jpg", annotated: nil
        )
        outbox.markUploaded(reportId: "a", blobIndex: 0, attachment: first)
        outbox.markUploaded(reportId: "a", blobIndex: 0, attachment: second)

        XCTAssertEqual(
            outbox.pending().first?.report.attachments, [first],
            "the same evidence must never be listed twice"
        )
    }

    func testEntryReadsOneEntryFreshFromDisk() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"), blobs: [blob(16)])
        let attachment = Attachment(
            key: "feedback/uploads/x.jpg", kind: .screenshot,
            contentType: "image/jpeg", size: 16, filename: "a.jpg", annotated: nil
        )

        let stale = try XCTUnwrap(outbox.entry(reportId: "a"))
        XCTAssertEqual(stale.blobs.count, 1)
        XCTAssertTrue(stale.report.attachments.isEmpty)

        outbox.markUploaded(reportId: "a", blobIndex: 0, attachment: attachment)

        let fresh = try XCTUnwrap(outbox.entry(reportId: "a"))
        XCTAssertEqual(fresh.report.attachments, [attachment], "a re-read sees the persisted ref")
        XCTAssertTrue(fresh.blobs.isEmpty, "a re-read sees the uploaded blob's bytes are gone")
        XCTAssertNil(outbox.entry(reportId: "nope"))
    }

    func testDropBlobDiscardsTheBytesButKeepsTheReport() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"), blobs: [blob(16), blob(32)])

        outbox.dropBlob(reportId: "a", index: 1) // the server refused these bytes for good

        let entry = try XCTUnwrap(outbox.entry(reportId: "a"))
        XCTAssertEqual(entry.report.message, "hi", "the user's message survives a rejected file")
        XCTAssertEqual(entry.blobs.map(\.index), [0], "only the refused blob is discarded")
        XCTAssertNil(outbox.blobData(reportId: "a", index: 1))
        XCTAssertTrue(entry.report.attachments.isEmpty, "a refused blob contributes no reference")
    }

    func testRemoveDeletesPendingBlobsToo() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"), blobs: [blob(64)])
        outbox.remove(reportId: "a")
        XCTAssertEqual(outbox.count, 0)
        XCTAssertNil(outbox.blobData(reportId: "a", index: 0))
        XCTAssertEqual(outbox.totalBytes, 0)
    }

    // MARK: - Caps

    func testEnqueueBeyondMaxEntriesDropsOldest() throws {
        let outbox = FeedbackOutbox(directory: dir, maxEntries: 2)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"))
        try outbox.enqueue(report(id: "b", time: "2026-01-02"))
        try outbox.enqueue(report(id: "c", time: "2026-01-03"))
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["b", "c"])
    }

    func testEnqueueBeyondByteBudgetDropsOldestFirst() throws {
        // Budget fits two 400-byte blobs, not three.
        let outbox = FeedbackOutbox(directory: dir, maxEntries: 50, maxBytes: 1000)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"), blobs: [blob(400)])
        try outbox.enqueue(report(id: "b", time: "2026-01-02"), blobs: [blob(400)])
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["a", "b"])
        XCTAssertEqual(outbox.totalBytes, 800)

        try outbox.enqueue(report(id: "c", time: "2026-01-03"), blobs: [blob(400)])
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["b", "c"],
                       "the byte budget must evict the OLDEST entry, not the newest")
        XCTAssertEqual(outbox.totalBytes, 800)
    }

    func testByteBudgetKeepsTheNewestEntryEvenWhenItAloneExceedsTheBudget() throws {
        let outbox = FeedbackOutbox(directory: dir, maxBytes: 100)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"), blobs: [blob(50)])
        try outbox.enqueue(report(id: "big", time: "2026-01-02"), blobs: [blob(500)])
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["big"],
                       "an oversized report is kept rather than silently lost")
    }

    func testByteBudgetCountsUploadedBlobsAsFreed() throws {
        let outbox = FeedbackOutbox(directory: dir, maxBytes: 1000)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"), blobs: [blob(400)])
        outbox.markUploaded(reportId: "a", blobIndex: 0, attachment: Attachment(
            key: "k", kind: .screenshot, contentType: "image/jpeg",
            size: 400, filename: nil, annotated: nil
        ))
        XCTAssertEqual(outbox.totalBytes, 0, "uploaded bytes no longer count against the budget")
    }

    func testHalfWrittenEntryWithoutReportJSONIsPrunedOnNextEnqueue() throws {
        let outbox = FeedbackOutbox(directory: dir, maxEntries: 50)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"))
        // Simulate a crash between writing the blobs and writing report.json.
        let orphan = dir.appendingPathComponent("orphan/blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: orphan.appendingPathComponent("0.bin"))

        try outbox.enqueue(report(id: "b", time: "2026-01-02"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("orphan").path),
            "an entry with no decodable report.json must not linger on disk"
        )
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["a", "b"])
    }
}
