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

    private let uploadedRef = Attachment(
        key: "feedback/uploads/x.jpg", kind: .screenshot,
        contentType: "image/jpeg", size: 16, filename: "a.jpg", annotated: nil
    )

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

    /// A1. Recording an upload is ONE atomic write (the blob's receipt) followed by dropping
    /// the bytes. If that write fails — disk full, unwritable volume — nothing may be dropped:
    /// the bytes are the only copy of the user's evidence. The old code wrote the reference
    /// with `try?` and deleted the bytes regardless, losing BOTH.
    func testMarkUploadedKeepsTheBlobBytesWhenTheReceiptCannotBeWritten() throws {
        let disk = ScriptedWriter()
        let outbox = FeedbackOutbox(directory: dir, writeFile: disk.write)
        try outbox.enqueue(report(id: "a", time: "t1"), blobs: [blob(16)])

        disk.failEveryWrite = true // the disk fills up mid-delivery
        outbox.markUploaded(reportId: "a", blobIndex: 0, attachment: uploadedRef)

        XCTAssertEqual(
            outbox.blobData(reportId: "a", index: 0)?.count, 16,
            "a failed write must NOT drop the bytes — they are the only copy of the evidence"
        )
        let entry = try XCTUnwrap(outbox.entry(reportId: "a"))
        XCTAssertTrue(entry.report.attachments.isEmpty, "and no reference was persisted either")
        XCTAssertEqual(entry.blobs.map(\.index), [0], "the blob is still pending, so the retry re-uploads it")
        XCTAssertNil(outbox.uploadedAttachment(reportId: "a", index: 0))

        // Space frees up: the retry records the upload for real.
        disk.failEveryWrite = false
        outbox.markUploaded(reportId: "a", blobIndex: 0, attachment: uploadedRef)
        XCTAssertEqual(outbox.entry(reportId: "a")?.report.attachments, [uploadedRef])
        XCTAssertNil(outbox.blobData(reportId: "a", index: 0), "now the bytes may go")
    }

    /// A2. A throw part-way through `enqueue` left the blob bytes it had already written inside
    /// a folder with no `report.json` — invisible to `pending()`, counted by no cap, reaped by
    /// nothing. Pure disk leak.
    func testEnqueueLeavesNothingBehindWhenItThrowsPartWay() throws {
        let disk = ScriptedWriter()
        // The blobs land; the report.json write is what fails.
        disk.failWrite = { $0.lastPathComponent == "report.json" }
        let outbox = FeedbackOutbox(directory: dir, writeFile: disk.write)

        XCTAssertThrowsError(try outbox.enqueue(report(id: "a", time: "t1"), blobs: [blob(4096)]))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("a").path),
            "a half-written entry must not orphan its blob bytes on disk"
        )
        XCTAssertEqual(outbox.count, 0)
        XCTAssertEqual(outbox.totalBytes, 0, "no cap would ever account for an orphaned entry")
    }

    func testUploadedAttachmentIsTheReceiptThatProvesABlobReachedR2() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"), blobs: [blob(16), blob(32)])
        let attachment = Attachment(
            key: "feedback/uploads/x.jpg", kind: .screenshot,
            contentType: "image/jpeg", size: 16, filename: "a.jpg", annotated: nil
        )
        XCTAssertNil(outbox.uploadedAttachment(reportId: "a", index: 0), "nothing is uploaded yet")

        outbox.markUploaded(reportId: "a", blobIndex: 0, attachment: attachment)

        XCTAssertEqual(outbox.uploadedAttachment(reportId: "a", index: 0), attachment)
        XCTAssertNil(outbox.uploadedAttachment(reportId: "a", index: 1), "the other blob is still pending")
        XCTAssertNil(outbox.uploadedAttachment(reportId: "nope", index: 0))
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

    // MARK: - Attachment attempts (the give-up limit's counter)

    /// The counter that bounds the attachment retry lives on disk, next to its entry, so a
    /// relaunch can neither reset it nor lose it.
    func testAttachmentAttemptsArePersistedPerEntryAndSurviveARelaunch() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"), blobs: [blob(16)])
        try outbox.enqueue(report(id: "b", time: "t2"))
        XCTAssertEqual(outbox.attachmentAttempts(reportId: "a"), 0)

        XCTAssertEqual(outbox.recordAttachmentAttempt(reportId: "a"), 1)
        XCTAssertEqual(outbox.recordAttachmentAttempt(reportId: "a"), 2)

        let relaunched = FeedbackOutbox(directory: dir) // a new process reading the same disk
        XCTAssertEqual(relaunched.attachmentAttempts(reportId: "a"), 2)
        XCTAssertEqual(relaunched.attachmentAttempts(reportId: "b"), 0, "counted per entry")
        XCTAssertEqual(relaunched.entry(reportId: "a")?.blobs.count, 1, "the bytes are untouched")
    }

    func testAttachmentAttemptsGoWithTheirEntry() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"))
        outbox.recordAttachmentAttempt(reportId: "a")
        outbox.remove(reportId: "a")
        XCTAssertEqual(outbox.attachmentAttempts(reportId: "a"), 0)

        // Counting an attempt for an entry that is gone must not resurrect its folder.
        outbox.recordAttachmentAttempt(reportId: "a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a").path))
        XCTAssertEqual(outbox.count, 0)
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
    //
    // The unified rule, shared VERBATIM with the Android outbox (`enforceCapacity` in its
    // `FeedbackOutbox.kt`) — the same input must evict the same entries on both platforms:
    //
    //     evict oldest-first while  count > maxEntries
    //                          OR  (totalBytes > maxBytes AND more than one entry remains)
    //
    // `totalBytes` is what the entries occupy on disk (report.json + descriptors + pending
    // attachment bytes), measured the same way as Android's `bytesOf()`. The blobs below are
    // large relative to that per-entry metadata (a few hundred bytes) so the budgets read clearly.

    func testEnqueueBeyondMaxEntriesDropsOldest() throws {
        let outbox = FeedbackOutbox(directory: dir, maxEntries: 2)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"))
        try outbox.enqueue(report(id: "b", time: "2026-01-02"))
        try outbox.enqueue(report(id: "c", time: "2026-01-03"))
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["b", "c"])
    }

    func testEnqueueBeyondByteBudgetDropsOldestFirst() throws {
        // Budget fits two 4 KB entries, not three.
        let outbox = FeedbackOutbox(directory: dir, maxEntries: 50, maxBytes: 10_000)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"), blobs: [blob(4096)])
        try outbox.enqueue(report(id: "b", time: "2026-01-02"), blobs: [blob(4096)])
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["a", "b"])
        XCTAssertLessThanOrEqual(outbox.totalBytes, 10_000)

        try outbox.enqueue(report(id: "c", time: "2026-01-03"), blobs: [blob(4096)])
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["b", "c"],
                       "the byte budget must evict the OLDEST entry, not the newest")
        XCTAssertLessThanOrEqual(outbox.totalBytes, 10_000, "and it must actually get under budget")
    }

    /// An entry bigger than the whole budget is never DROPPED — and it does not get to destroy
    /// the reports already queued beside it either. Evicting them could not bring the outbox
    /// under budget (the oversized entry alone is already over it), so it would trade N good
    /// reports for nothing.
    ///
    /// Mirrors Android's `anOversizedNewEntryDoesNotCannibaliseTheReportsAlreadyQueued`. These
    /// two SDKs have drifted apart on this rule twice; keep the assertions identical.
    func testAnOversizedNewEntryDoesNotCannibaliseTheReportsAlreadyQueued() throws {
        let outbox = FeedbackOutbox(directory: dir, maxBytes: 10_000)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"), blobs: [blob(2048)])
        try outbox.enqueue(report(id: "b", time: "2026-01-02"), blobs: [blob(2048)])
        try outbox.enqueue(report(id: "big", time: "2026-01-03"), blobs: [blob(40_000)])

        XCTAssertEqual(
            outbox.pending().map(\.report.reportId), ["a", "b", "big"],
            "evicting a and b could not get us under the budget — so they are kept"
        )
        XCTAssertEqual(
            outbox.blobData(reportId: "big", index: 0)?.count, 40_000,
            "and the oversized entry keeps the evidence that made it oversized"
        )
    }

    /// The lone-entry clause, on its own: one report whose recording alone blows the budget is
    /// kept rather than destroyed.
    func testALoneOversizedEntryIsNeverEvicted() throws {
        let outbox = FeedbackOutbox(directory: dir, maxBytes: 1_000)
        try outbox.enqueue(report(id: "big", time: "2026-01-01"), blobs: [blob(40_000)])

        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["big"])
        XCTAssertEqual(outbox.blobData(reportId: "big", index: 0)?.count, 40_000)
    }

    /// Same floor rule when the oversized entry is the one a worker is mid-delivery on.
    /// Mirrors Android's `anOversizedEntryBeingDeliveredDoesNotCannibaliseTheReportsAlreadyQueued`.
    func testAnOversizedEntryBeingDeliveredDoesNotCannibaliseTheReportsAlreadyQueued() throws {
        let outbox = FeedbackOutbox(directory: dir, maxBytes: 10_000)
        try outbox.enqueue(report(id: "big", time: "2026-01-01"), blobs: [blob(40_000)])
        XCTAssertTrue(outbox.hold("big"), "a worker is uploading its blob right now")
        try outbox.enqueue(report(id: "queued", time: "2026-01-02"), blobs: [blob(2048)])

        XCTAssertEqual(
            outbox.blobData(reportId: "big", index: 0)?.count, 40_000,
            "the held entry is never evicted"
        )
        XCTAssertEqual(
            outbox.pendingReportIds(), ["queued"],
            "...and it does not get to destroy its neighbour either (the held one stays hidden)"
        )
        outbox.release("big")
    }

    /// The COUNT cap keeps working even when an oversized entry has switched the byte cap off —
    /// the floor rule suspends the byte budget, not the whole capacity sweep. This is what bounds
    /// disk growth while an oversized entry is queued.
    /// Mirrors Android's `theCountCapStillEvictsWhenAnOversizedEntryDisablesTheByteCap`.
    func testCountCapStillEvictsWhenAnOversizedEntryDisablesTheByteCap() throws {
        let outbox = FeedbackOutbox(directory: dir, maxEntries: 2, maxBytes: 100)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"), blobs: [blob(50)])
        try outbox.enqueue(report(id: "b", time: "2026-01-02"), blobs: [blob(50)])
        try outbox.enqueue(report(id: "big", time: "2026-01-03"), blobs: [blob(500)])

        XCTAssertEqual(
            outbox.pending().map(\.report.reportId), ["b", "big"],
            "the count cap evicts the oldest; the byte cap stands down"
        )
    }

    // MARK: - The delivery claim (hold / release)

    /// B1. The claim lives in the outbox precisely so the CAPS can see it: an entry that a
    /// delivery is uploading right now must never be evicted. Deleting its folder underneath
    /// the deliverer strands the blob it is mid-upload, and the deliverer — finding the bytes
    /// gone — would POST the report with an empty `attachments` array and let the 2xx ack make
    /// the loss permanent.
    func testAnEntryBeingDeliveredIsNeverEvictedByTheCaps() throws {
        let outbox = FeedbackOutbox(directory: dir, maxEntries: 1, maxBytes: 100)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"), blobs: [blob(50)])
        XCTAssertTrue(outbox.hold("a"), "a delivery claims the entry and starts uploading its blob")

        // Both caps want the oldest entry ("a") gone — it is over the count cap AND the queue is
        // over the byte budget. It is being delivered, so it stays.
        try outbox.enqueue(report(id: "b", time: "2026-01-02"), blobs: [blob(90)])

        XCTAssertEqual(outbox.count, 2, "a held entry is never the eviction victim")
        XCTAssertEqual(
            outbox.blobData(reportId: "a", index: 0)?.count, 50,
            "the bytes the deliverer is uploading are still there"
        )
        XCTAssertNotNil(outbox.entry(reportId: "a"))
        XCTAssertEqual(
            outbox.pending().map(\.report.reportId), ["b"],
            "a held entry is hidden from every other deliverer"
        )
        XCTAssertEqual(outbox.pendingReportIds(), ["b"])

        // Released (delivery finished/failed): it is visible — and evictable — again.
        outbox.release("a")
        XCTAssertEqual(outbox.pendingReportIds(), ["a", "b"])
        try outbox.enqueue(report(id: "c", time: "2026-01-03"))
        XCTAssertEqual(outbox.pending().map(\.report.reportId), ["c"], "maxEntries = 1")
    }

    func testHoldIsExclusiveAndReleaseGivesItBack() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "a", time: "t1"))
        XCTAssertTrue(outbox.hold("a"))
        XCTAssertFalse(outbox.hold("a"), "a second deliverer must not get the same entry")
        outbox.release("a")
        XCTAssertTrue(outbox.hold("a"))
    }

    func testPendingReportIdsMatchesPendingWithoutLoadingAnyBytes() throws {
        let outbox = FeedbackOutbox(directory: dir)
        try outbox.enqueue(report(id: "b", time: "2026-01-02", image: Data([0xFF, 0xD8])), blobs: [blob(16)])
        try outbox.enqueue(report(id: "a", time: "2026-01-01"))
        XCTAssertEqual(outbox.pendingReportIds(), ["a", "b"])
        XCTAssertEqual(outbox.pendingReportIds(), outbox.pending().map(\.report.reportId))
    }

    func testByteBudgetCountsUploadedBlobsAsFreed() throws {
        let outbox = FeedbackOutbox(directory: dir, maxBytes: 10_000)
        try outbox.enqueue(report(id: "a", time: "2026-01-01"), blobs: [blob(4096)])
        let queued = outbox.totalBytes
        XCTAssertGreaterThan(queued, 4096, "the bytes awaiting upload are on the books")

        outbox.markUploaded(reportId: "a", blobIndex: 0, attachment: Attachment(
            key: "k", kind: .screenshot, contentType: "image/jpeg",
            size: 4096, filename: nil, annotated: nil
        ))

        XCTAssertLessThan(
            outbox.totalBytes, 1_000,
            """
            uploaded bytes no longer count against the budget — they are gone from disk, and all \
            that is left on the books is the entry's metadata (report.json + the descriptor \
            carrying the receipt)
            """
        )
    }

    /// `enqueue` writes the attachment bytes with the lock RELEASED — they run to tens of
    /// megabytes, and that same lock is taken by the reporter's thread and by the delivery
    /// pipeline, so holding it across the write would stall them for the length of the disk IO.
    ///
    /// What makes that safe is the `writing` set. The folder being filled has no `report.json`
    /// yet, so anything sweeping the queue in that window (a concurrent enqueue's cap check, a
    /// flush building its work list) would otherwise take it for the residue of a crashed enqueue
    /// and REAP it — deleting the user's bytes out from under the write in progress.
    func testAnEntryStillBeingWrittenIsNeitherVisibleNorReapedByAConcurrentSweep() throws {
        let disk = ScriptedWriter()
        let outbox = FeedbackOutbox(directory: dir, writeFile: disk.write)
        try outbox.enqueue(report(id: "old", time: "2026-01-01"))

        // Sweep the queue from another thread while the new entry's blob bytes are going down.
        var swept: [String] = []
        disk.onWrite = { [unowned outbox] url in
            guard url.lastPathComponent == "0.bin" else { return }
            let done = self.expectation(description: "concurrent sweep")
            DispatchQueue.global().async {
                swept = outbox.pendingReportIds() // this is what reaps half-written folders
                done.fulfill()
            }
            // A lock held across the blob write would park the sweep here until the timeout.
            self.wait(for: [done], timeout: 5)
        }
        try outbox.enqueue(report(id: "new", time: "2026-01-02"), blobs: [blob(2048)])

        XCTAssertEqual(swept, ["old"], "an entry still being written is not on the queue yet")
        XCTAssertEqual(
            outbox.pendingReportIds(), ["old", "new"],
            "and it joins the queue, intact, the moment its report.json lands"
        )
        XCTAssertEqual(
            outbox.blobData(reportId: "new", index: 0)?.count, 2048,
            "the sweep must not reap the folder whose bytes are still being written"
        )
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

/// A disk that can be made to fail on demand, for the outbox's "the write didn't land" paths.
///
/// They cannot be reached with POSIX permissions: a directory mode that fails the *write* fails
/// the *delete* just the same (both need write access to the directory), so the read-only trick
/// keeps the blob bytes for the wrong reason and would pass against the very bug it is meant to
/// catch. A real disk-full failure lets the delete succeed — which is exactly how the old code
/// managed to lose the reference AND the bytes.
private final class ScriptedWriter {
    /// Fail every write (a full disk).
    var failEveryWrite = false
    /// Or fail selectively, by destination.
    var failWrite: (URL) -> Bool = { _ in false }
    /// Run *inside* a write, before the bytes land — a seam for "what does the rest of the outbox
    /// see while a slow write is in progress?".
    var onWrite: (URL) -> Void = { _ in }

    struct DiskFull: Error {}

    func write(_ data: Data, to url: URL) throws {
        guard !failEveryWrite, !failWrite(url) else { throw DiskFull() }
        onWrite(url)
        try data.write(to: url, options: .atomic)
    }
}
