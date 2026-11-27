import XCTest
@testable import CatchDev

/// End-to-end coverage of the offline outbox: persist-first, upload-then-post, ack-then-delete.
///
/// These drive a real `CatchDev` instance (via the `init(client:uploader:outbox:)` seam) over a
/// stubbed network that routes all three hops the SDK makes — mint a presigned URL, PUT the
/// bytes to R2, POST the report — so the queue/replay semantics are verified deterministically
/// without a simulator or a backend.
final class OfflineOutboxTests: XCTestCase {
    private let endpoint = URL(string: "https://api.catch.dev")!
    private var tempDirs: [URL] = []
    private var stub: StubbedBackend!
    /// Every line the SDK logged with `warn` (the lines it logs even with debug logging off).
    private let warnings = WarningLog()

    override func setUp() {
        super.setUp()
        stub = StubbedBackend()
        stub.install()
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        stub = nil
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func tempOutbox(maxEntries: Int = 50, maxBytes: Int = 50 * 1024 * 1024) -> FeedbackOutbox {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catchdev-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(dir)
        return FeedbackOutbox(directory: dir, maxEntries: maxEntries, maxBytes: maxBytes)
    }

    /// An SDK over `outbox` and the stubbed backend. Attachment retries default to no backoff,
    /// because most tests here are about what a retry does, not when; the backoff tests pass
    /// `.standard` and a `clock` they move forward.
    private func makeSDK(
        outbox: FeedbackOutbox,
        limits: CatchDev.AttachmentRetryLimits = .standard,
        backoff: CatchDev.AttachmentRetryBackoff = .immediate,
        clock: TestClock? = nil
    ) -> CatchDev {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        let warnings = self.warnings
        let sdk = CatchDev(
            client: FeedbackClient(session: session, boundaryProvider: { "B" }),
            uploader: AttachmentUploader(session: session),
            outbox: outbox,
            attachmentRetryLimits: limits,
            attachmentRetryBackoff: backoff,
            now: { clock?.now ?? Date() },
            warningLog: { warnings.append($0) }
        )
        sdk.configure(apiKey: "ck", endpoint: endpoint)
        return sdk
    }

    /// Spin the main run loop until `condition` holds — for flushes that end without firing
    /// `onFeedbackSent` (nothing to wait on but the state they leave behind).
    private func waitUntil(
        _ description: String, timeout: TimeInterval = 5, _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting until \(description)")
    }

    /// Run one flush to completion. Waiting for the flush to be fully over (not just for its
    /// POST) matters: a `flushPending()` issued while one is still finishing is ignored.
    private func flushAndWait(_ sdk: CatchDev, until description: String, _ condition: () -> Bool) {
        sdk.flushPending()
        waitUntil(description) { condition() && !sdk.isFlushInProgress }
    }

    /// The `time` a report submitted `seconds` ago carries.
    private static func timestamp(secondsAgo seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(-seconds))
    }

    private func screenshotBlob(_ bytes: Int = 64) -> PendingBlob {
        PendingBlob(
            kind: .screenshot, data: Data(repeating: 0xEE, count: bytes),
            contentType: "image/jpeg", filename: "screenshot.jpg", annotated: true
        )
    }

    /// Stands in for a screen recording — the attachment that actually runs into the backend's
    /// per-kind size cap.
    private func recordingBlob(_ bytes: Int) -> PendingBlob {
        PendingBlob(
            kind: .recording, data: Data(repeating: 0x11, count: bytes),
            contentType: "video/mp4", filename: "recording.mp4", annotated: false
        )
    }

    /// A picked file; its size tells the files of one test apart.
    private func fileBlob(_ bytes: Int) -> PendingBlob {
        PendingBlob(
            kind: .file, data: Data(repeating: 0x22, count: bytes),
            contentType: "text/plain", filename: "notes-\(bytes).txt", annotated: false
        )
    }

    /// Submit and return the outcome (the reporter's view of the send).
    @discardableResult
    private func submit(
        _ sdk: CatchDev,
        message: String = "offline report",
        blobs: [PendingBlob]
    ) throws -> CatchDev.SubmissionOutcome {
        var outcome: Result<CatchDev.SubmissionOutcome, Error>?
        let done = expectation(description: "submit")
        sdk.submit(message: message, imageData: nil, pendingAttachments: blobs) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(outcome).get()
    }

    // MARK: - 1. Persist first / offline is not an error

    /// **Persist first means persist SYNCHRONOUSLY.** Tapping Send and immediately backgrounding
    /// the app is an ordinary gesture (home swipe, an incoming call, an app switch) and iOS then
    /// suspends — and later jetsams — the process without running whatever the SDK merely
    /// *scheduled*. A `submit` that hands its `enqueue` to a background queue therefore loses the
    /// report, the typed message and the 30 MB recording outright, while the user is looking at
    /// "Sending report…" and believing it was sent.
    ///
    /// So: by the time `submit` RETURNS — with no waiting, no run-loop turn, nothing draining —
    /// the report and every attachment byte must already be on disk.
    func testSubmitPersistsTheReportAndItsBytesBeforeItEvenReturns() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.offline = true

        sdk.submit(
            message: "typed just before the app was suspended",
            imageData: nil,
            pendingAttachments: [screenshotBlob(128)],
            reportId: "durable"
        ) { _ in }

        // Not a single `wait` above this line: this is the state of the disk the instant Send
        // returned, which is all a process that gets suspended right afterwards will ever have.
        XCTAssertEqual(outbox.count, 1, "the entry must be on disk before submit returns")
        let entry = try XCTUnwrap(outbox.entry(reportId: "durable"))
        XCTAssertEqual(entry.report.message, "typed just before the app was suspended")
        XCTAssertEqual(
            outbox.blobData(reportId: "durable", index: 0)?.count, 128,
            "the attachment's raw bytes are persisted too — before any network call"
        )

        settle() // let the (offline) delivery attempt finish before the stub is torn down
        XCTAssertEqual(outbox.count, 1, "still queued: it was never delivered")
    }

    func testOfflineSubmitPersistsReportWithBlobsAndReportsQueuedNotAnError() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.offline = true

        // onFeedbackSent must NOT fire for a merely-queued report.
        let notified = expectation(description: "onFeedbackSent must not fire on queue")
        notified.isInverted = true
        sdk.onFeedbackSent = { _ in notified.fulfill() }

        let outcome = try submit(sdk, blobs: [screenshotBlob(128)])
        guard case .queued(let reportId) = outcome else {
            return XCTFail("an offline submit must be reported as queued, got \(outcome)")
        }

        // The report AND its not-yet-uploaded bytes are durably on disk.
        let entry = try XCTUnwrap(outbox.pending().first)
        XCTAssertEqual(entry.report.reportId, reportId)
        XCTAssertEqual(entry.report.message, "offline report")
        XCTAssertTrue(entry.report.attachments.isEmpty, "nothing uploaded while offline")
        XCTAssertEqual(entry.blobs.count, 1, "the attachment's raw bytes must be persisted")
        XCTAssertEqual(entry.blobs.first?.size, 128)
        XCTAssertEqual(outbox.blobData(reportId: reportId, index: 0)?.count, 128)
        XCTAssertEqual(stub.putCount, 0, "offline: nothing reached R2")
        XCTAssertEqual(stub.reportBodies.count, 0, "offline: nothing was posted")

        wait(for: [notified], timeout: 0.5)
    }

    // MARK: - 2/3. Flush on reconnect → upload, post, delete on ack

    func testFlushAfterReconnectUploadsBlobsPostsReportAndDeletesTheEntryOnAck() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.offline = true
        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .queued(let reportId) = outcome else { return XCTFail("expected queued") }

        // Reconnect.
        stub.offline = false
        let delivered = expectation(description: "delivered")
        sdk.onFeedbackSent = { result in
            if case .success(let id) = result { XCTAssertEqual(id, "fb_server") }
            else { XCTFail("expected delivery success, got \(result)") }
            delivered.fulfill()
        }
        sdk.flushPending()
        wait(for: [delivered], timeout: 5)

        XCTAssertEqual(stub.mintCount, 1, "the queued blob is uploaded during the flush")
        XCTAssertEqual(stub.putCount, 1)
        XCTAssertEqual(stub.reportBodies.count, 1)
        let body = try XCTUnwrap(stub.reportBodies.first)
        XCTAssertTrue(body.contains("name=\"reportId\"\r\n\r\n\(reportId)"))
        XCTAssertTrue(body.contains("name=\"attachments\""), "the uploaded ref travels in the report")
        XCTAssertTrue(body.contains("feedback"), "the R2 key is referenced")
        XCTAssertEqual(outbox.count, 0, "the entry is deleted only after the backend acked it")
    }

    // MARK: - 4. Duplicate safety on replay

    func testReplayKeepsTheSameReportIdAndNeverPostsASecondReport() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        // Uploads succeed; only the report POST fails at the transport layer.
        stub.reportTransportFails = true

        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .queued(let reportId) = outcome else {
            return XCTFail("a transport failure on the report POST must queue, got \(outcome)")
        }
        XCTAssertEqual(outbox.count, 1, "the entry survives a failed report POST")

        stub.reportTransportFails = false
        let delivered = expectation(description: "delivered")
        sdk.onFeedbackSent = { _ in delivered.fulfill() }
        sdk.flushPending()
        wait(for: [delivered], timeout: 5)

        // Every report POST attempt (the failed ones + the delivered one) carried the SAME
        // client-generated idempotency key — the server dedupes, so no duplicate report.
        let ids = Set(stub.reportBodies.compactMap { Self.field("reportId", in: $0) })
        XCTAssertEqual(ids, [reportId], "reportId must never be regenerated on retry")
        XCTAssertEqual(outbox.count, 0)
    }

    func testAlreadyUploadedAttachmentIsNotReUploadedOnReplay() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.reportTransportFails = true

        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .queued(let reportId) = outcome else { return XCTFail("expected queued") }

        // The upload landed before the POST failed: its reference is persisted into the
        // entry's report and its bytes are gone from disk.
        let queued = try XCTUnwrap(outbox.pending().first)
        XCTAssertEqual(queued.report.attachments.count, 1)
        XCTAssertTrue(queued.blobs.isEmpty, "an uploaded blob's bytes are dropped")
        XCTAssertNil(outbox.blobData(reportId: reportId, index: 0))
        XCTAssertEqual(stub.putCount, 1)

        stub.reportTransportFails = false
        let delivered = expectation(description: "delivered")
        sdk.onFeedbackSent = { _ in delivered.fulfill() }
        sdk.flushPending()
        wait(for: [delivered], timeout: 5)

        XCTAssertEqual(stub.mintCount, 1, "the flush must not re-mint an upload URL")
        XCTAssertEqual(stub.putCount, 1, "the flush must not re-upload bytes already in R2")
        XCTAssertEqual(
            Self.field("attachments", in: try XCTUnwrap(stub.reportBodies.last))?.contains("uploads"),
            true,
            "the delivered report still carries the attachment reference"
        )
        XCTAssertEqual(outbox.count, 0)
    }

    // MARK: - 5. Permanent rejection

    func testServerRejectionOfTheReportDeletesTheEntry() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.reportStatus = 413 // payload too large

        var outcome: Result<CatchDev.SubmissionOutcome, Error>?
        let done = expectation(description: "submit")
        sdk.submit(message: "x", imageData: nil, pendingAttachments: [screenshotBlob()]) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        guard case .failure(CatchDevError.server(let status)) = try XCTUnwrap(outcome) else {
            return XCTFail("a 4xx must surface as an error, got \(String(describing: outcome))")
        }
        XCTAssertEqual(status, 413)
        XCTAssertEqual(outbox.count, 0, "a permanently rejected report must not be retried forever")
    }

    /// The permanent-rejection rule is about the REPORT POST. An attachment hop that fails —
    /// even with a 4xx, here the backend refusing to mint a URL for a recording over its cap —
    /// never costs the user the typed message or the attachments that DID upload, and the
    /// failed one is kept for a retry rather than dropped (only the retry limits drop it).
    func testAnAttachmentTheServerRefusesIsKeptForRetryAndTheReportStillLands() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.rejectMintOver = 512 // the backend's per-kind byte cap

        let outcome = try submit(
            sdk, message: "video is broken",
            blobs: [screenshotBlob(64), recordingBlob(4096)] // the recording blows the cap
        )
        guard case .attachmentsPending = outcome else {
            return XCTFail("the report lands and the refused attachment stays pending, got \(outcome)")
        }

        XCTAssertEqual(stub.putCount, 1, "only the accepted attachment reaches R2")
        XCTAssertEqual(stub.reportBodies.count, 1, "the report is still posted")
        let body = try XCTUnwrap(stub.reportBodies.first)
        XCTAssertTrue(body.contains("name=\"message\"\r\n\r\nvideo is broken"), "the message survives")
        XCTAssertEqual(
            try Self.attachmentCount(in: body), 1,
            "the posted report carries the screenshot that DID upload"
        )
        let reportId = try XCTUnwrap(Self.field("reportId", in: body))
        let entry = try XCTUnwrap(outbox.entry(reportId: reportId), "kept: an attachment is missing")
        XCTAssertEqual(entry.blobs.map(\.index), [1], "the refused recording is kept, not dropped")
        XCTAssertEqual(outbox.attachmentAttempts(reportId: reportId), 1)
    }

    /// A 429 on the mint: the report itself still lands, and the attachment's bytes stay on
    /// disk for the next flush.
    func testARateLimitedAttachmentUploadKeepsTheAttachmentQueued() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.mintStatus = 429 // rate limited

        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .attachmentsPending = outcome else {
            return XCTFail("a 429 must keep the attachment pending, got \(outcome)")
        }
        XCTAssertEqual(stub.reportBodies.count, 1, "the report itself was posted")
        let reportId = try XCTUnwrap(Self.field("reportId", in: XCTUnwrap(stub.reportBodies.first)))
        XCTAssertEqual(outbox.count, 1, "a rate-limited upload must not drop the attachment")
        XCTAssertEqual(
            outbox.blobData(reportId: reportId, index: 0)?.count, 64,
            "the attachment's bytes are kept for the retry"
        )
    }

    func testServerErrorKeepsTheEntryQueuedForRetry() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.reportStatus = 503 // transient outage — not a permanent rejection

        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .queued = outcome else {
            return XCTFail("a 5xx must be retryable (queued), got \(outcome)")
        }
        XCTAssertEqual(outbox.count, 1, "a 5xx must not drop the report")
    }

    // MARK: - 6. Flush drains oldest-first and stops when still offline

    func testFlushStopsAndKeepsEntriesWhenStillOffline() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.offline = true
        try submit(sdk, message: "one", blobs: [screenshotBlob()])
        try submit(sdk, message: "two", blobs: [screenshotBlob()])
        XCTAssertEqual(outbox.count, 2)

        sdk.flushPending()
        // Nothing is delivered; the entries stay put (a later flush retries them).
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(outbox.count, 2, "an offline flush must not drop anything")

        stub.offline = false
        let delivered = expectation(description: "both delivered")
        delivered.expectedFulfillmentCount = 2
        sdk.onFeedbackSent = { _ in delivered.fulfill() }
        sdk.flushPending()
        wait(for: [delivered], timeout: 10)
        XCTAssertEqual(outbox.count, 0)
    }

    // MARK: - 7. A flush that races an in-flight submit

    /// The entry is on disk from before the first network call until the ack, so ANY flush
    /// trigger that fires mid-send (foreground, `NWPathMonitor` path change, a Wi-Fi↔cellular
    /// handoff) sees the very report that `submit` is still uploading. It must not deliver it
    /// a second time: that re-uploads the bytes, POSTs the report twice, and fires
    /// `onFeedbackSent` twice for one submission.
    func testAFlushThatRacesAnInFlightSubmitDoesNotDeliverTheReportTwice() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        let deliveries = AttemptCounter()
        sdk.onFeedbackSent = { _ in _ = deliveries.increment() }

        // Fire a flush from inside the R2 PUT — i.e. while submit's upload is genuinely in
        // flight, the entry is on disk, and its blob bytes have not been dropped yet.
        stub.onFirstPut = { [weak sdk] in sdk?.flushPending() }

        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .delivered = outcome else { return XCTFail("expected delivered, got \(outcome)") }
        settle()

        XCTAssertEqual(stub.mintCount, 1, "the racing flush must not re-mint an upload URL")
        XCTAssertEqual(stub.putCount, 1, "the racing flush must not re-upload the bytes to R2")
        XCTAssertEqual(stub.reportBodies.count, 1, "the report must be POSTed exactly once")
        XCTAssertEqual(deliveries.count, 1, "onFeedbackSent fires once per delivered report")
        XCTAssertEqual(
            try Self.attachmentCount(in: try XCTUnwrap(stub.reportBodies.first)), 1,
            "the delivered report carries its attachment exactly once"
        )
        XCTAssertEqual(outbox.count, 0)
    }

    /// The full-blast-radius version: an older entry is queued from a previous offline session
    /// (the feature's own home turf), so the racing flush has real work to do and reaches the
    /// in-flight entry only *after* its upload has landed and its blob bytes are gone. Both
    /// reports must be delivered exactly once, each carrying its own evidence.
    func testAFlushWithAnOlderQueuedEntryDeliversBothExactlyOnceWithTheirAttachments() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)

        // Entry A: queued while offline on an earlier launch.
        stub.offline = true
        let first = try submit(sdk, message: "older report", blobs: [screenshotBlob(32)])
        guard case .queued(let firstId) = first else { return XCTFail("expected queued") }

        // Back online. The user submits B; mid-upload, a reconnect/foreground fires a flush.
        stub.offline = false
        let deliveries = AttemptCounter()
        let delivered = expectation(description: "both delivered")
        delivered.expectedFulfillmentCount = 2
        delivered.assertForOverFulfill = false // a 3rd delivery is asserted on below, not crashed on
        sdk.onFeedbackSent = { _ in
            _ = deliveries.increment()
            delivered.fulfill()
        }
        stub.onFirstPut = { [weak sdk] in sdk?.flushPending() }

        let second = try submit(sdk, message: "newer report", blobs: [screenshotBlob(64)])
        guard case .delivered = second else { return XCTFail("expected delivered, got \(second)") }
        wait(for: [delivered], timeout: 10)
        settle()

        XCTAssertEqual(deliveries.count, 2, "onFeedbackSent fires once per report — not once per attempt")
        XCTAssertEqual(stub.reportBodies.count, 2, "two reports, two POSTs — no replay")
        let ids = stub.reportBodies.compactMap { Self.field("reportId", in: $0) }
        XCTAssertEqual(Set(ids).count, 2, "the two POSTs are the two distinct reports")
        XCTAssertTrue(ids.contains(firstId), "the older queued entry was delivered")
        for body in stub.reportBodies {
            XCTAssertEqual(
                try Self.attachmentCount(in: body), 1,
                "every delivered report keeps its screenshot exactly once"
            )
        }
        XCTAssertEqual(stub.putCount, 2, "each attachment reaches R2 exactly once")
        XCTAssertEqual(outbox.count, 0)
    }

    // MARK: - 8. The caps must never evict an entry that is being delivered

    /// B1, end to end. The delivery claim lives inside the outbox so the CAPS can see it.
    ///
    /// A report with TWO attachments is being delivered; while its FIRST blob is mid-PUT — so
    /// the second one's bytes have not been read yet — another report is queued and trips the
    /// count cap. The eviction used to delete the folder of the entry being delivered: the
    /// deliverer then found blob #2's bytes gone, read that as "already uploaded", POSTed the
    /// report WITHOUT that attachment, and the backend's 2xx ack made the loss permanent.
    ///
    /// Both halves of the fix are asserted here: the entry is not evicted (so the bytes are
    /// still there), and missing bytes with no receipt are no longer mistaken for an upload.
    func testACapEvictionCannotStripAnInFlightReportOfItsEvidence() throws {
        let outbox = tempOutbox(maxEntries: 1)
        let sdk = makeSDK(outbox: outbox)

        // Queue a second report from inside the first R2 PUT — synchronously, so the cap runs
        // while the delivery is genuinely mid-flight and blob #2 is still only on disk.
        stub.onFirstPut = {
            var later = FeedbackReport(message: "queued behind it")
            later.reportId = "later"
            later.time = "2099-01-01T00:00:00Z"
            _ = try? outbox.enqueue(later)
        }

        let outcome = try submit(sdk, message: "two files", blobs: [screenshotBlob(64), recordingBlob(128)])
        guard case .delivered = outcome else {
            return XCTFail("the in-flight entry was evicted from under its delivery, got \(outcome)")
        }
        settle()

        XCTAssertEqual(stub.putCount, 2, "BOTH attachments reached R2 — the second one's bytes survived")
        let body = try XCTUnwrap(stub.reportBodies.first)
        XCTAssertEqual(
            try Self.attachmentCount(in: body), 2,
            "an entry being delivered must not be evicted — the delivered report keeps every attachment"
        )
        XCTAssertEqual(outbox.count, 1, "the delivered entry is gone; the one queued behind it stays")
        XCTAssertEqual(outbox.pendingReportIds(), ["later"])
    }

    // MARK: - 9. A failed attachment upload is retried, never silently dropped

    /// Success: a submission counts as delivered only when the server confirms it stored the
    /// attachment (`attachments: 1` in its answer) — and only then is the entry deleted.
    func testASubmissionIsDeliveredOnceTheServerConfirmsItsAttachment() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        var results: [Result<String, Error>] = []
        let sent = expectation(description: "onFeedbackSent")
        sdk.onFeedbackSent = { results.append($0); sent.fulfill() }

        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .delivered(let id) = outcome else { return XCTFail("expected delivered, got \(outcome)") }
        wait(for: [sent], timeout: 5)

        XCTAssertEqual(id, "fb_server")
        XCTAssertEqual(try results.map { try $0.get() }, ["fb_server"])
        let reportId = try XCTUnwrap(Self.field("reportId", in: XCTUnwrap(stub.reportBodies.first)))
        XCTAssertEqual(stub.storedAttachmentCount(reportId: reportId), 1, "the server has the screenshot")
        XCTAssertEqual(outbox.count, 0)
    }

    /// The production failure: R2 answers the presigned PUT with 403. The report must reach the
    /// dashboard at once, and the screenshot must stay queued — not dropped, not reported as
    /// delivered. The next flush mints a FRESH upload URL (the server never hands one back on a
    /// re-POST), uploads the bytes, and re-posts the report under the same `reportId`; only then
    /// does `onFeedbackSent` fire, exactly once.
    func testAnR2403KeepsTheScreenshotQueuedAndTheNextFlushDeliversIt() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.putStatus = 403
        var results: [Result<String, Error>] = []
        let sent = expectation(description: "onFeedbackSent fires once, with the final outcome")
        sdk.onFeedbackSent = { results.append($0); sent.fulfill() }

        let outcome = try submit(sdk, message: "checkout is broken", blobs: [screenshotBlob(128)])
        guard case .attachmentsPending(let id) = outcome else {
            return XCTFail("a 403 from R2 must leave the screenshot pending, got \(outcome)")
        }
        XCTAssertEqual(id, "fb_server", "the report itself reached the server")
        let firstPost = try XCTUnwrap(stub.reportBodies.first)
        XCTAssertTrue(firstPost.contains("name=\"message\"\r\n\r\ncheckout is broken"))
        XCTAssertEqual(try Self.attachmentCount(in: firstPost), 0, "nothing had landed yet")
        let reportId = try XCTUnwrap(Self.field("reportId", in: firstPost))
        XCTAssertEqual(outbox.blobData(reportId: reportId, index: 0)?.count, 128, "the bytes are kept")
        XCTAssertEqual(outbox.attachmentAttempts(reportId: reportId), 1)
        settle()
        XCTAssertTrue(results.isEmpty, "no outcome yet — the screenshot is still on its way")

        stub.putStatus = 200 // R2 is fixed
        sdk.flushPending()
        wait(for: [sent], timeout: 5)

        XCTAssertEqual(try results.map { try $0.get() }, ["fb_server"])
        XCTAssertEqual(stub.mintCount, 2, "the retry minted a fresh presigned URL")
        XCTAssertEqual(stub.putCount, 2)
        XCTAssertEqual(stub.reportBodies.count, 2, "the report was re-posted once the screenshot landed")
        XCTAssertEqual(
            Set(stub.reportBodies.compactMap { Self.field("reportId", in: $0) }), [reportId],
            "the re-POST reuses the reportId, so the server dedupes onto the same report"
        )
        XCTAssertEqual(try Self.attachmentCount(in: XCTUnwrap(stub.reportBodies.last)), 1)
        XCTAssertEqual(stub.storedAttachmentCount(reportId: reportId), 1)
        XCTAssertEqual(outbox.count, 0, "delivered in full: the entry is gone")
    }

    /// Bounded, never silent: when R2 never recovers, the SDK gives up on the screenshot once
    /// the retry limits are spent, and says so — `onFeedbackSent` gets a
    /// `CatchDevAttachmentsNotDelivered` carrying the report's server id — and drops the entry.
    func testGivesUpOnAnAttachmentOnlyWhenTheRetryLimitsRunOut() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox, limits: .init(maxAttempts: 3, maxAge: 0))
        stub.putStatus = 403 // R2 never recovers
        var results: [Result<String, Error>] = []
        let sent = expectation(description: "onFeedbackSent")
        sdk.onFeedbackSent = { results.append($0); sent.fulfill() }

        let outcome = try submit(sdk, blobs: [screenshotBlob()]) // attempt 1
        guard case .attachmentsPending = outcome else { return XCTFail("expected pending, got \(outcome)") }
        let reportId = try XCTUnwrap(Self.field("reportId", in: XCTUnwrap(stub.reportBodies.first)))

        flushAndWait(sdk, until: "attempt 2 is counted") { outbox.attachmentAttempts(reportId: reportId) == 2 }
        XCTAssertTrue(results.isEmpty, "attempt 2 of 3: still retrying")
        XCTAssertEqual(outbox.blobData(reportId: reportId, index: 0)?.count, 64, "the bytes are still kept")

        sdk.flushPending() // attempt 3: the limit
        wait(for: [sent], timeout: 5)

        guard case .failure(let error as CatchDevAttachmentsNotDelivered) = try XCTUnwrap(results.first) else {
            return XCTFail("giving up must be reported as CatchDevAttachmentsNotDelivered, got \(results)")
        }
        XCTAssertEqual(error.reportId, "fb_server", "the report itself was delivered, under this id")
        XCTAssertEqual(error.missingCount, 1)
        guard case .server(let status)? = error.underlyingError as? CatchDevError else {
            return XCTFail("the last upload failure travels with it, got \(String(describing: error.underlyingError))")
        }
        XCTAssertEqual(status, 403)
        XCTAssertEqual(stub.reportBodies.count, 3, "the report was re-posted on every attempt")
        XCTAssertEqual(stub.putCount, 3)
        XCTAssertEqual(outbox.count, 0, "given up: the entry is gone")

        flushAndWait(sdk, until: "a flush of the now-empty outbox finishes") { true }
        XCTAssertEqual(stub.reportBodies.count, 3, "nothing is left to retry")
        XCTAssertEqual(results.count, 1, "onFeedbackSent fires once per submission")
    }

    /// Both limits must be spent. An entry younger than `maxAge` keeps its attachment however
    /// many attempts fail; one older than `maxAge` is given up on at the attempt limit.
    func testTheGiveUpAlsoWaitsForTheEntryToBeOldEnough() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox, limits: .init(maxAttempts: 1, maxAge: 24 * 60 * 60))
        stub.putStatus = 403
        var results: [Result<String, Error>] = []
        sdk.onFeedbackSent = { results.append($0) }

        // Fresh: past the attempt limit at once, but far younger than a day.
        _ = try submit(sdk, message: "fresh", blobs: [screenshotBlob()])
        let freshId = try XCTUnwrap(Self.field("reportId", in: XCTUnwrap(stub.reportBodies.first)))
        flushAndWait(sdk, until: "attempt 2 is counted") { outbox.attachmentAttempts(reportId: freshId) == 2 }
        XCTAssertNotNil(outbox.entry(reportId: freshId), "too young to give up on")

        // Submitted two days ago and queued offline since: its first failed attempt that
        // reaches the server is past both limits.
        var old = FeedbackReport(message: "from two days ago")
        old.reportId = "old"
        old.time = Self.timestamp(secondsAgo: 2 * 24 * 60 * 60)
        try outbox.enqueue(old, blobs: [screenshotBlob()])

        flushAndWait(sdk, until: "the old entry is given up on") { outbox.entry(reportId: "old") == nil }
        waitUntil("onFeedbackSent reports it") { !results.isEmpty }
        guard case .failure(let error as CatchDevAttachmentsNotDelivered) = try XCTUnwrap(results.first) else {
            return XCTFail("expected CatchDevAttachmentsNotDelivered, got \(results)")
        }
        XCTAssertEqual(error.missingCount, 1)
        XCTAssertEqual(results.count, 1, "only the old entry is settled")
        XCTAssertNotNil(outbox.entry(reportId: freshId), "the fresh entry is still retrying")
    }

    /// A network error reaching R2 (the API answers, the bucket's host doesn't): the report
    /// lands, the screenshot stays queued, and it goes up once R2 is reachable again.
    func testANetworkErrorOnTheUploadKeepsTheScreenshotAndALaterFlushDeliversIt() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.putTransportFails = true
        var results: [Result<String, Error>] = []
        let sent = expectation(description: "onFeedbackSent")
        sdk.onFeedbackSent = { results.append($0); sent.fulfill() }

        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .attachmentsPending = outcome else { return XCTFail("expected pending, got \(outcome)") }
        let reportId = try XCTUnwrap(Self.field("reportId", in: XCTUnwrap(stub.reportBodies.first)))
        XCTAssertEqual(outbox.blobData(reportId: reportId, index: 0)?.count, 64, "the bytes are kept")

        stub.putTransportFails = false
        sdk.flushPending()
        wait(for: [sent], timeout: 5)

        XCTAssertEqual(try results.map { try $0.get() }, ["fb_server"])
        XCTAssertEqual(stub.storedAttachmentCount(reportId: reportId), 1)
        XCTAssertEqual(outbox.count, 0)
    }

    /// Offline is not an attachment failure: attempts that never reach the server don't count
    /// toward the give-up limit, so a long offline stretch can't cost the user a screenshot.
    func testOfflineAttemptsDoNotUseUpTheAttachmentRetries() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox, limits: .init(maxAttempts: 1, maxAge: 0))
        stub.offline = true

        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .queued(let reportId) = outcome else { return XCTFail("expected queued, got \(outcome)") }
        for _ in 0..<3 {
            flushAndWait(sdk, until: "an offline flush finishes") { true }
        }
        XCTAssertEqual(outbox.attachmentAttempts(reportId: reportId), 0, "offline attempts are not counted")
        XCTAssertEqual(outbox.blobData(reportId: reportId, index: 0)?.count, 64)

        stub.offline = false
        let sent = expectation(description: "delivered")
        sdk.onFeedbackSent = { result in
            XCTAssertEqual(try? result.get(), "fb_server")
            sent.fulfill()
        }
        sdk.flushPending()
        wait(for: [sent], timeout: 5)
        XCTAssertEqual(outbox.count, 0)
    }

    /// Bytes that are on disk but can't be read, with no receipt, are an ordinary failed
    /// attachment: the report still lands, the entry stays incomplete, and the attempt counts.
    /// (Missing bytes are never read as "already uploaded" without a receipt.)
    func testUnreadableAttachmentBytesCountAsAFailedUpload() throws {
        let outbox = tempOutbox()
        let directory = try XCTUnwrap(tempDirs.last)
        let sdk = makeSDK(outbox: outbox)
        stub.offline = true
        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .queued(let reportId) = outcome else { return XCTFail("expected queued, got \(outcome)") }

        let bytes = directory.appendingPathComponent("\(reportId)/blobs/0.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bytes.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bytes.path) }

        stub.offline = false
        flushAndWait(sdk, until: "the attempt is counted") { outbox.attachmentAttempts(reportId: reportId) == 1 }

        XCTAssertEqual(stub.reportBodies.count, 1, "the report itself was posted")
        XCTAssertEqual(stub.putCount, 0, "nothing could be uploaded")
        XCTAssertNotNil(outbox.entry(reportId: reportId), "incomplete: the entry stays")
    }

    /// The upload "succeeded" but the server could not find the object (its R2 HEAD failed), so
    /// its `attachments` count comes up short. The entry stays, and the retry re-posts the
    /// reference WITHOUT re-uploading — the bytes already reached R2.
    func testAShortStoredCountKeepsTheEntryAndTheRetryRepostsWithoutReuploading() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.serverCannotFindUploads = true
        let sent = expectation(description: "onFeedbackSent")
        sdk.onFeedbackSent = { result in
            XCTAssertEqual(try? result.get(), "fb_server")
            sent.fulfill()
        }

        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .attachmentsPending = outcome else {
            return XCTFail("listed 1, stored 0 is not a delivery, got \(outcome)")
        }
        let reportId = try XCTUnwrap(Self.field("reportId", in: XCTUnwrap(stub.reportBodies.first)))
        XCTAssertEqual(outbox.entry(reportId: reportId)?.report.attachments.count, 1, "its receipt is kept")

        stub.serverCannotFindUploads = false
        sdk.flushPending()
        wait(for: [sent], timeout: 5)

        XCTAssertEqual(stub.putCount, 1, "the bytes were not uploaded twice")
        XCTAssertEqual(stub.mintCount, 1)
        XCTAssertEqual(stub.reportBodies.count, 2)
        XCTAssertEqual(stub.storedAttachmentCount(reportId: reportId), 1)
        XCTAssertEqual(outbox.count, 0)
    }

    // MARK: - 10. At most ten attachments per report

    /// The backend stores only the first 10 references a report lists. A submission with more
    /// (the reporter never offers more, but any other path might) is trimmed before it is
    /// persisted: the entry holds 10, the screenshot first even though it came last, and each
    /// dropped attachment is logged. The report is complete once the 10 kept ones land; nothing
    /// waits for the dropped ones.
    func testASubmissionWithMoreThanTenAttachmentsIsTrimmedToTenScreenshotFirst() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.offline = true
        let files = (1...11).map { fileBlob(100 + $0) }
        let outcome = try submit(sdk, blobs: files + [screenshotBlob()])
        guard case .queued(let reportId) = outcome else { return XCTFail("expected queued, got \(outcome)") }

        let entry = try XCTUnwrap(outbox.entry(reportId: reportId))
        XCTAssertEqual(entry.blobs.count, 10, "the entry never holds more than the server keeps")
        XCTAssertEqual(entry.blobs.first?.kind, .screenshot, "the screenshot is kept, and listed first")
        XCTAssertEqual(entry.blobs.dropFirst().map(\.size), (1...9).map { 100 + $0 }, "then the first nine files")
        XCTAssertEqual(warnings.lines.count, 2, "one warning per dropped attachment")
        XCTAssertTrue(
            warnings.lines.allSatisfy { $0.contains(reportId) && $0.contains("dropped a file attachment") },
            "\(warnings.lines)"
        )

        stub.offline = false
        let sent = expectation(description: "delivered")
        sdk.onFeedbackSent = { result in
            XCTAssertEqual(try? result.get(), "fb_server")
            sent.fulfill()
        }
        sdk.flushPending()
        wait(for: [sent], timeout: 5)

        XCTAssertEqual(stub.putCount, 10)
        XCTAssertEqual(try Self.attachmentCount(in: XCTUnwrap(stub.reportBodies.last)), 10)
        XCTAssertEqual(stub.storedAttachmentCount(reportId: reportId), 10)
        XCTAssertEqual(outbox.count, 0, "complete: the dropped attachments are not waited for")
    }

    /// References the caller already uploaded keep their place (they come first on the wire),
    /// and the blobs share the room left, screenshots first. The same rule as the Android SDK.
    func testReferencesAlreadyUploadedKeepTheirPlaceAndTheBlobsShareTheRest() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.offline = true
        let refs = (1...8).map {
            Attachment(key: "feedback/uploads/ref-\($0).bin", kind: .file, contentType: "text/plain", size: $0)
        }
        var outcome: Result<CatchDev.SubmissionOutcome, Error>?
        let done = expectation(description: "submit")
        sdk.submit(
            message: "eight already uploaded", imageData: nil, attachments: refs,
            pendingAttachments: [fileBlob(201), fileBlob(202), screenshotBlob()]
        ) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        guard case .queued(let reportId) = try XCTUnwrap(outcome).get() else {
            return XCTFail("expected queued, got \(String(describing: outcome))")
        }

        let entry = try XCTUnwrap(outbox.entry(reportId: reportId))
        XCTAssertEqual(entry.report.attachments, refs, "the eight references keep their place")
        XCTAssertEqual(entry.blobs.map(\.kind), [.screenshot, .file], "two slots left: the screenshot, then a file")
        XCTAssertEqual(entry.blobs.last?.size, 201, "the first file")
        XCTAssertEqual(warnings.lines.count, 1)
    }

    /// Without a durable outbox (the disk can't be written), the in-memory send is trimmed the
    /// same way.
    func testWithoutADurableOutboxTheInMemorySendIsTrimmedTheSameWay() throws {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        let warnings = self.warnings
        let sdk = CatchDev(
            client: FeedbackClient(session: session, boundaryProvider: { "B" }),
            uploader: AttachmentUploader(session: session),
            outbox: nil,
            warningLog: { warnings.append($0) }
        )
        sdk.configure(apiKey: "ck", endpoint: endpoint)

        let outcome = try submit(sdk, blobs: (1...12).map { fileBlob(300 + $0) })
        guard case .delivered = outcome else { return XCTFail("expected delivered, got \(outcome)") }
        XCTAssertEqual(stub.putCount, 10)
        XCTAssertEqual(try Self.attachmentCount(in: XCTUnwrap(stub.reportBodies.last)), 10)
        XCTAssertEqual(warnings.lines.count, 2)
    }

    /// An entry queued by an SDK version without the limit (0.1.2 or older) can hold more. It
    /// is trimmed when the flush reads it back, screenshot first and with a warning per dropped
    /// attachment, so it completes instead of retrying the extra ones until the give-up.
    func testAnEntryQueuedWithMoreThanTenAttachmentsIsTrimmedBeforeItIsDelivered() throws {
        let outbox = tempOutbox()
        var legacy = FeedbackReport(message: "queued before the limit existed")
        legacy.reportId = "legacy"
        // The outbox stores what it is given (only `submit` trims), so this is how such an
        // entry looks on disk.
        try outbox.enqueue(legacy, blobs: (1...11).map { fileBlob(100 + $0) } + [screenshotBlob()])
        XCTAssertEqual(outbox.entry(reportId: "legacy")?.blobs.count, 12, "precondition: over the limit")

        let sdk = makeSDK(outbox: outbox) // starting the SDK flushes the outbox
        waitUntil("the entry is delivered") { outbox.count == 0 && !sdk.isFlushInProgress }

        XCTAssertEqual(stub.putCount, 10, "only the ten kept attachments were uploaded")
        let body = try XCTUnwrap(stub.reportBodies.last)
        XCTAssertEqual(try Self.attachmentCount(in: body), 10)
        XCTAssertTrue(body.contains("\"kind\":\"screenshot\""), "the screenshot was kept, though it came last")
        XCTAssertEqual(stub.storedAttachmentCount(reportId: "legacy"), 10)
        XCTAssertEqual(warnings.lines.count, 2, "one warning per dropped attachment")
    }

    // MARK: - 11. Backoff between attachment retries

    /// After an attempt that reached the server but left attachments missing, the entry waits
    /// out its backoff (60 s after the first). A flush during the wait skips it without
    /// stopping: the newer report queued behind it is still delivered. The first flush after
    /// the wait retries it.
    func testAFlushSkipsAnEntryInItsBackoffWithoutHoldingBackTheOthers() throws {
        let outbox = tempOutbox()
        let clock = TestClock()
        let sdk = makeSDK(outbox: outbox, backoff: .standard, clock: clock)
        stub.putStatus = 403
        let first = try submit(sdk, message: "older", blobs: [screenshotBlob()])
        guard case .attachmentsPending = first else { return XCTFail("expected pending, got \(first)") }
        let olderId = try XCTUnwrap(Self.field("reportId", in: XCTUnwrap(stub.reportBodies.first)))

        stub.offline = true
        let second = try submit(sdk, message: "newer", blobs: [screenshotBlob()])
        guard case .queued(let newerId) = second else { return XCTFail("expected queued, got \(second)") }
        stub.offline = false
        stub.putStatus = 200 // storage is fixed: the older entry would succeed now, if it were tried

        clock.advance(by: 30) // inside the older entry's 60 s wait
        flushAndWait(sdk, until: "the newer report is delivered") { outbox.entry(reportId: newerId) == nil }
        XCTAssertNotNil(outbox.entry(reportId: olderId), "the waiting entry was skipped")
        let posted = stub.reportBodies.compactMap { Self.field("reportId", in: $0) }
        XCTAssertEqual(posted.filter { $0 == olderId }.count, 1, "and not re-posted")
        XCTAssertEqual(outbox.attachmentAttempts(reportId: olderId), 1)

        let delivered = expectation(description: "the older report completes")
        sdk.onFeedbackSent = { result in
            XCTAssertEqual(try? result.get(), "fb_server")
            delivered.fulfill()
        }
        clock.advance(by: 40) // 70 s after the attempt: the wait is over
        sdk.flushPending()
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(outbox.count, 0)
    }

    /// The wait runs from the last counted attempt, stamped on the attempts file from the SDK's
    /// clock, and doubles with each attempt: 60 s, then 120 s, then 240 s.
    func testTheBackoffRunsFromTheLastCountedAttemptAndDoubles() throws {
        let outbox = tempOutbox()
        let clock = TestClock()
        let sdk = makeSDK(outbox: outbox, backoff: .standard, clock: clock)
        stub.putStatus = 403
        let start = clock.now
        _ = try submit(sdk, blobs: [screenshotBlob()]) // attempt 1, at `start`
        let reportId = try XCTUnwrap(Self.field("reportId", in: XCTUnwrap(stub.reportBodies.first)))

        func assertNextRetry(after seconds: TimeInterval, _ message: String) throws {
            let next = try XCTUnwrap(sdk.nextAttachmentRetry(of: reportId), message)
            XCTAssertEqual(next.timeIntervalSince(start), seconds, accuracy: 0.01, message)
        }
        try assertNextRetry(after: 60, "attempt 1: wait 60 s")

        clock.advance(by: 61)
        flushAndWait(sdk, until: "attempt 2 is counted") { outbox.attachmentAttempts(reportId: reportId) == 2 }
        try assertNextRetry(after: 61 + 120, "attempt 2, made at 61 s: wait 120 s")

        clock.advance(by: 121)
        flushAndWait(sdk, until: "attempt 3 is counted") { outbox.attachmentAttempts(reportId: reportId) == 3 }
        try assertNextRetry(after: 182 + 240, "attempt 3, made at 182 s: wait 240 s")
    }

    /// The give-up rule is unchanged: at least 5 counted attempts AND 7 days. With the standard
    /// backoff, the SDK's clock drives both the retries and the age check.
    func testWithTheStandardBackoffTheGiveUpStillNeedsFiveAttemptsAndSevenDays() throws {
        let outbox = tempOutbox()
        let clock = TestClock()
        let sdk = makeSDK(outbox: outbox, backoff: .standard, clock: clock)
        stub.putStatus = 403
        var results: [Result<String, Error>] = []
        sdk.onFeedbackSent = { results.append($0) }

        _ = try submit(sdk, blobs: [screenshotBlob()]) // attempt 1
        let reportId = try XCTUnwrap(Self.field("reportId", in: XCTUnwrap(stub.reportBodies.first)))
        for attempt in 2...6 {
            clock.advance(by: 6 * 60 * 60) // past any wait
            flushAndWait(sdk, until: "attempt \(attempt) is counted") {
                outbox.attachmentAttempts(reportId: reportId) == attempt
            }
        }
        settle()
        XCTAssertTrue(results.isEmpty, "6 attempts, but only 30 hours old: still retrying")
        XCTAssertNotNil(outbox.entry(reportId: reportId))

        clock.advance(by: 7 * 24 * 60 * 60)
        flushAndWait(sdk, until: "it is given up on") { outbox.entry(reportId: reportId) == nil }
        waitUntil("onFeedbackSent reports it") { !results.isEmpty }
        guard case .failure(let error as CatchDevAttachmentsNotDelivered) = try XCTUnwrap(results.first) else {
            return XCTFail("expected CatchDevAttachmentsNotDelivered, got \(results)")
        }
        XCTAssertEqual(error.missingCount, 1)
        XCTAssertEqual(stub.reportBodies.count, 7, "one POST per attempt, no more")
    }

    // MARK: - 12. A report the outbox evicts gets its final outcome

    /// The outbox is full and a newer report needs the room, so the oldest queued report, never
    /// delivered, is dropped. `onFeedbackSent` says so once, with `CatchDevOutboxFull`, and
    /// nothing more is ever reported for it.
    func testEvictingAReportThatNeverReachedTheServerReportsOutboxFull() throws {
        let outbox = tempOutbox(maxEntries: 1)
        let sdk = makeSDK(outbox: outbox)
        var results: [Result<String, Error>] = []
        sdk.onFeedbackSent = { results.append($0) }
        stub.offline = true

        guard case .queued(let olderId) = try submit(sdk, message: "older", blobs: [screenshotBlob()]) else {
            return XCTFail("expected queued")
        }
        try submit(sdk, message: "newer", blobs: [screenshotBlob()])
        waitUntil("onFeedbackSent reports the eviction") { !results.isEmpty }

        guard case .failure(let error as CatchDevOutboxFull) = try XCTUnwrap(results.first) else {
            return XCTFail("expected CatchDevOutboxFull, got \(results)")
        }
        XCTAssertEqual(error.reportId, olderId)
        XCTAssertNil(outbox.entry(reportId: olderId))

        stub.offline = false
        flushAndWait(sdk, until: "the newer report is delivered") { outbox.count == 0 }
        waitUntil("its outcome arrives") { results.count == 2 }
        settle()
        XCTAssertEqual(results.count, 2, "one outcome per report")
        XCTAssertEqual(try? results.last?.get(), "fb_server")
        XCTAssertFalse(
            stub.reportBodies.contains { Self.field("reportId", in: $0) == olderId },
            "the evicted report never reached the server"
        )
    }

    /// The evicted report had already reached the server; its two attachments were still
    /// waiting for a retry. The outcome is `CatchDevAttachmentsNotDelivered`, caused by
    /// `CatchDevOutboxFull`.
    func testEvictingAReportWhoseAttachmentsWerePendingReportsThemNotDelivered() throws {
        let outbox = tempOutbox(maxEntries: 1)
        let sdk = makeSDK(outbox: outbox)
        var results: [Result<String, Error>] = []
        sdk.onFeedbackSent = { results.append($0) }
        stub.putStatus = 403

        let older = try submit(sdk, message: "older", blobs: [screenshotBlob(), recordingBlob(256)])
        guard case .attachmentsPending = older else { return XCTFail("expected pending, got \(older)") }
        let olderId = try XCTUnwrap(Self.field("reportId", in: XCTUnwrap(stub.reportBodies.first)))

        stub.offline = true
        try submit(sdk, message: "newer", blobs: [])
        waitUntil("onFeedbackSent reports the eviction") { !results.isEmpty }
        settle()

        XCTAssertEqual(results.count, 1, "one outcome, for the evicted report")
        guard case .failure(let error as CatchDevAttachmentsNotDelivered) = try XCTUnwrap(results.first) else {
            return XCTFail("expected CatchDevAttachmentsNotDelivered, got \(results)")
        }
        XCTAssertEqual(error.reportId, olderId, "the SDK's own id: the server's isn't kept on disk")
        XCTAssertEqual(error.missingCount, 2, "neither attachment ever uploaded")
        XCTAssertEqual((error.underlyingError as? CatchDevOutboxFull)?.reportId, olderId)
        XCTAssertNil(outbox.entry(reportId: olderId))
    }

    // MARK: - Helpers

    /// Let any stray second delivery land before asserting it did not happen.
    private func settle(_ seconds: TimeInterval = 0.5) {
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        wait(for: [settled], timeout: seconds + 2)
    }

    /// Pull one multipart field's value out of a captured request body.
    private static func field(_ name: String, in body: String) -> String? {
        guard let start = body.range(of: "name=\"\(name)\"\r\n\r\n") else { return nil }
        let rest = body[start.upperBound...]
        guard let end = rest.range(of: "\r\n") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    /// How many attachment references the posted report actually carries. `0` when the field
    /// is absent — which is exactly what a report that lost its evidence looks like on the wire.
    private static func attachmentCount(in body: String) throws -> Int {
        guard let json = field("attachments", in: body) else { return 0 }
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return (parsed as? [Any])?.count ?? 0
    }
}

extension CatchDev.AttachmentRetryBackoff {
    /// No wait between attachment retries, for the tests about what a retry does rather than
    /// when it happens.
    static let immediate = CatchDev.AttachmentRetryBackoff(initialDelay: 0, maxDelay: 0)
}

/// A clock the backoff tests move forward by hand. Read from the SDK's outbox queue, so locked.
private final class TestClock {
    private let lock = NSLock()
    private var current = Date()

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// The lines an SDK logged with `warn`, from whichever thread logged them.
private final class WarningLog {
    private let lock = NSLock()
    private var _lines: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        _lines.append(line)
    }
}

/// A stubbed catch.dev + R2 backend for `MockURLProtocol`: routes the presigned-URL mint,
/// the R2 PUT, and the report POST, and can simulate being offline or rejecting any hop.
///
/// The report POST mirrors the real backend's replay semantics: a re-POST under the same
/// `reportId` keeps what earlier POSTs stored, a listed key is stored only if its bytes really
/// reached R2 (the backend HEAD-checks each one), and the answer carries `attachments: <stored
/// count>` whenever the report listed any.
private final class StubbedBackend {
    private let lock = NSLock()

    private var _offline = false
    private var _reportTransportFails = false
    private var _putTransportFails = false
    private var _serverCannotFindUploads = false
    private var _mintStatus = 200
    private var _putStatus = 200
    private var _reportStatus = 200
    private var _rejectMintOver: Int?
    private var _mintCount = 0
    private var _putCount = 0
    private var _reportBodies: [String] = []
    private var _onFirstPut: (() -> Void)?
    /// Keys whose R2 PUT returned 2xx.
    private var _landedKeys: Set<String> = []
    /// reportId → the attachment keys the "server" has stored for that report.
    private var _storedKeys: [String: Set<String>] = [:]

    var offline: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _offline }
        set { lock.lock(); defer { lock.unlock() }; _offline = newValue }
    }
    /// 413 any presigned-URL mint whose declared `size` exceeds this — the backend's per-kind
    /// byte cap (recording 50 MB, file 25 MB, screenshot 8 MB).
    var rejectMintOver: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _rejectMintOver }
        set { lock.lock(); defer { lock.unlock() }; _rejectMintOver = newValue }
    }
    /// Run once, from inside the first R2 PUT — i.e. while a submit's upload is genuinely in
    /// flight. Lets a test fire a flush at the exact moment the racing triggers do (reconnect,
    /// foreground) with the entry sitting on disk, un-acked, bytes not yet dropped.
    var onFirstPut: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFirstPut }
        set { lock.lock(); defer { lock.unlock() }; _onFirstPut = newValue }
    }
    /// Fail only the report POST at the transport layer (uploads still succeed).
    var reportTransportFails: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _reportTransportFails }
        set { lock.lock(); defer { lock.unlock() }; _reportTransportFails = newValue }
    }
    var mintStatus: Int {
        get { lock.lock(); defer { lock.unlock() }; return _mintStatus }
        set { lock.lock(); defer { lock.unlock() }; _mintStatus = newValue }
    }
    /// What R2 answers the presigned PUT with (403 is the production failure: R2 not enabled).
    var putStatus: Int {
        get { lock.lock(); defer { lock.unlock() }; return _putStatus }
        set { lock.lock(); defer { lock.unlock() }; _putStatus = newValue }
    }
    /// Fail only the R2 PUT at the transport layer — the API answers, R2's host doesn't.
    var putTransportFails: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _putTransportFails }
        set { lock.lock(); defer { lock.unlock() }; _putTransportFails = newValue }
    }
    /// The server's HEAD-check of listed keys fails, so it stores none of them.
    var serverCannotFindUploads: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _serverCannotFindUploads }
        set { lock.lock(); defer { lock.unlock() }; _serverCannotFindUploads = newValue }
    }
    /// How many attachments the "server" holds for a report, across all its POSTs.
    func storedAttachmentCount(reportId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _storedKeys[reportId]?.count ?? 0
    }
    var reportStatus: Int {
        get { lock.lock(); defer { lock.unlock() }; return _reportStatus }
        set { lock.lock(); defer { lock.unlock() }; _reportStatus = newValue }
    }
    var mintCount: Int { lock.lock(); defer { lock.unlock() }; return _mintCount }
    var putCount: Int { lock.lock(); defer { lock.unlock() }; return _putCount }
    var reportBodies: [String] { lock.lock(); defer { lock.unlock() }; return _reportBodies }

    func install() {
        MockURLProtocol.handler = { [self] request in
            let path = request.url?.path ?? ""
            let isPut = !path.hasSuffix("/feedback/upload-url") && !path.hasSuffix("/feedback/report")

            // Claim + run the one-shot PUT hook OUTSIDE the lock: it re-enters the SDK (to
            // fire a flush) while this request is still in flight.
            if isPut, let hook = claimFlushHook() { hook() }

            lock.lock()
            defer { lock.unlock() }

            if _offline { throw URLError(.notConnectedToInternet) }

            if path.hasSuffix("/feedback/upload-url") {
                if let limit = _rejectMintOver, Self.declaredSize(request) > limit {
                    return (Self.response(request, 413), Data()) // payload too large
                }
                guard _mintStatus == 200 else { return (Self.response(request, _mintStatus), Data()) }
                _mintCount += 1
                let json = """
                {"uploadUrl":"https://r2.example.com/put/\(_mintCount)",\
                "key":"feedback/uploads/\(_mintCount).bin","expiresIn":600}
                """
                return (Self.response(request, 200), Data(json.utf8))
            }

            if path.hasSuffix("/feedback/report") {
                let body = Self.bodyString(request)
                _reportBodies.append(body)
                if _reportTransportFails { throw URLError(.networkConnectionLost) }
                guard _reportStatus == 200 else { return (Self.response(request, _reportStatus), Data()) }
                let reportId = Self.multipartField("reportId", in: body) ?? ""
                let listed = Self.attachmentKeys(in: body)
                var stored = _storedKeys[reportId] ?? []
                if !_serverCannotFindUploads {
                    // Like the backend, only the first 10 references listed count, and at most
                    // 10 are kept (`MAX_ATTACHMENTS`).
                    stored.formUnion(listed.prefix(10).filter { _landedKeys.contains($0) })
                }
                _storedKeys[reportId] = stored
                let storedCount = min(stored.count, 10)
                let count = (!listed.isEmpty || !stored.isEmpty) ? ",\"attachments\":\(storedCount)" : ""
                return (Self.response(request, 200), Data("{\"id\":\"fb_server\"\(count)}".utf8))
            }

            // Anything else is the presigned PUT straight to R2 (`/put/<n>` ↔ key
            // `feedback/uploads/<n>.bin`, as minted above).
            if _putTransportFails { throw URLError(.timedOut) }
            _putCount += 1
            if (200..<300).contains(_putStatus), let n = request.url?.lastPathComponent {
                _landedKeys.insert("feedback/uploads/\(n).bin")
            }
            return (Self.response(request, _putStatus), Data())
        }
    }

    /// One multipart field's value from a captured report body.
    private static func multipartField(_ name: String, in body: String) -> String? {
        guard let start = body.range(of: "name=\"\(name)\"\r\n\r\n") else { return nil }
        let rest = body[start.upperBound...]
        guard let end = rest.range(of: "\r\n") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    /// The R2 keys a report body lists in its `attachments` field.
    private static func attachmentKeys(in body: String) -> [String] {
        guard
            let json = multipartField("attachments", in: body),
            let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["key"] as? String }
    }

    /// Take the one-shot PUT hook, so a flush it triggers can't re-trigger itself.
    private func claimFlushHook() -> (() -> Void)? {
        lock.lock(); defer { lock.unlock() }
        let hook = _onFirstPut
        _onFirstPut = nil
        return hook
    }

    /// The `size` the SDK declared when minting the presigned URL.
    private static func declaredSize(_ request: URLRequest) -> Int {
        let body = Data(bodyString(request).utf8)
        guard
            let parsed = try? JSONSerialization.jsonObject(with: body),
            let json = parsed as? [String: Any],
            let size = json["size"] as? Int
        else { return 0 }
        return size
    }

    private static func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// URLSession often moves `httpBody` into a stream by the time a `URLProtocol` sees it.
    private static func bodyString(_ request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 8192
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
