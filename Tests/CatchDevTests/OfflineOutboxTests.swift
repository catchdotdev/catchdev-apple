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

    private func makeSDK(outbox: FeedbackOutbox) -> CatchDev {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        let sdk = CatchDev(
            client: FeedbackClient(session: session, boundaryProvider: { "B" }),
            uploader: AttachmentUploader(session: session),
            outbox: outbox
        )
        sdk.configure(apiKey: "ck", endpoint: endpoint)
        return sdk
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

    /// The permanent-rejection rule is about the REPORT POST. An attachment the server refuses
    /// for good (the backend 413s a recording over its per-kind cap) must cost the user that
    /// one file — not the typed message and not the attachments that already uploaded.
    func testAnAttachmentRejectedForGoodIsDroppedAndTheReportIsStillDelivered() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.rejectMintOver = 512 // the backend's per-kind byte cap

        let outcome = try submit(
            sdk, message: "video is broken",
            blobs: [screenshotBlob(64), recordingBlob(4096)] // the recording blows the cap
        )
        guard case .delivered = outcome else {
            return XCTFail("one oversized attachment must not fail the whole report, got \(outcome)")
        }

        XCTAssertEqual(stub.putCount, 1, "only the accepted attachment reaches R2")
        XCTAssertEqual(stub.reportBodies.count, 1, "the report is still posted")
        let body = try XCTUnwrap(stub.reportBodies.first)
        XCTAssertTrue(body.contains("name=\"message\"\r\n\r\nvideo is broken"), "the message survives")
        XCTAssertEqual(
            try Self.attachmentCount(in: body), 1,
            "the delivered report keeps the screenshot that DID upload"
        )
        XCTAssertEqual(outbox.count, 0, "delivered — nothing is left to retry forever")
    }

    /// 408 / 429 sit in the 4xx range but are transient by definition — the request was fine,
    /// the server just could not take it now. Dropping the report over one would be a bug.
    func testARateLimitedAttachmentUploadKeepsTheWholeEntryQueued() throws {
        let outbox = tempOutbox()
        let sdk = makeSDK(outbox: outbox)
        stub.mintStatus = 429 // rate limited

        let outcome = try submit(sdk, blobs: [screenshotBlob()])
        guard case .queued(let reportId) = outcome else {
            return XCTFail("a 429 must be retryable (queued), got \(outcome)")
        }
        XCTAssertEqual(stub.reportBodies.count, 0, "nothing was posted")
        XCTAssertEqual(outbox.count, 1, "a rate-limited upload must not drop the report")
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
            try? outbox.enqueue(later)
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

/// A stubbed catch.dev + R2 backend for `MockURLProtocol`: routes the presigned-URL mint,
/// the R2 PUT, and the report POST, and can simulate being offline or rejecting any hop.
private final class StubbedBackend {
    private let lock = NSLock()

    private var _offline = false
    private var _reportTransportFails = false
    private var _mintStatus = 200
    private var _putStatus = 200
    private var _reportStatus = 200
    private var _rejectMintOver: Int?
    private var _mintCount = 0
    private var _putCount = 0
    private var _reportBodies: [String] = []
    private var _onFirstPut: (() -> Void)?

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
                _reportBodies.append(Self.bodyString(request))
                if _reportTransportFails { throw URLError(.networkConnectionLost) }
                guard _reportStatus == 200 else { return (Self.response(request, _reportStatus), Data()) }
                return (Self.response(request, 200), Data("{\"id\":\"fb_server\"}".utf8))
            }

            // Anything else is the presigned PUT straight to R2.
            _putCount += 1
            return (Self.response(request, _putStatus), Data())
        }
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
