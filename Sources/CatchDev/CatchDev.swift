import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Entry point for the catch.dev user-feedback SDK.
///
/// ```swift
/// import CatchDev
///
/// // In AppDelegate.didFinishLaunching / App init:
/// CatchDev.start(apiKey: "ck_...")        // shake-to-report enabled by default
/// CatchDev.setUser(id: "123", email: "a@b.com")
/// CatchDev.presentReporter()              // or trigger manually from a button
/// ```
///
/// Objective-C: `[CDVCatchDev startWithApiKey:@"ck_..."];`
@objc(CDVCatchDev)
public final class CatchDev: NSObject {

    /// What happened to a submission. A report is `queued` when it is safely on disk but the
    /// network is unavailable — the reporter shows a success-style "we'll send it later"
    /// state for this, never an error, and `onFeedbackSent` stays silent until it is
    /// actually `delivered` by a later flush.
    enum SubmissionOutcome {
        /// The report and every attachment reached the server.
        case delivered(reportId: String)
        /// Safely on disk; nothing reached the server yet.
        case queued(reportId: String)
        /// The report reached the server, but some attachments did not. They stay in the
        /// outbox and the next flush retries them; `onFeedbackSent` waits for that outcome.
        case attachmentsPending(reportId: String)
    }

    /// How one delivery attempt of an outbox entry ended.
    enum DeliveryOutcome {
        /// The report and every attachment reached the server. The entry is gone.
        case delivered(id: String)
        /// The report reached the server but some attachments did not. The entry stays, and
        /// the next flush uploads them and re-POSTs the report under the same `reportId`.
        case attachmentsPending(id: String)
        /// The report reached the server, but its missing attachments ran out of retries, so
        /// the SDK gave up on them. The entry is gone.
        case attachmentsAbandoned(CatchDevAttachmentsNotDelivered)
        /// The server refused the report for good. The entry is gone.
        case rejected(Error)
        /// The report didn't reach the server (offline, 5xx, rate-limited). The entry stays.
        case deferred(Error)
    }

    /// When the SDK stops retrying attachments that won't upload.
    ///
    /// **Shared verbatim with the Android SDK — keep the two identical.** Any failed attachment
    /// upload (a 403 from R2, a refused mint, a timeout) keeps the attachment in the outbox, and
    /// every flush retries it. The SDK gives up on an entry's missing attachments only once
    /// BOTH limits are reached:
    ///
    /// - `maxAttempts`: delivery attempts that reached the server (the report POST got a 2xx)
    ///   yet still left attachments missing. Attempts that never reached the server don't
    ///   count, so time spent offline can't use up the retries.
    /// - `maxAge`: time since the user submitted the report (its own `time`).
    ///
    /// Requiring both means neither a short R2 outage nor a burst of flushes (launch, the
    /// reachability callback and the foreground notification can all fire within a second) can
    /// cost a screenshot, and an app that is rarely opened still gets `maxAttempts` real tries.
    struct AttachmentRetryLimits {
        var maxAttempts: Int
        var maxAge: TimeInterval

        static let standard = AttachmentRetryLimits(maxAttempts: 5, maxAge: 7 * 24 * 60 * 60)
    }

    /// One attachment whose upload failed in this attempt: it stays pending for the next one.
    struct AttachmentFailure {
        let blob: OutboxBlob
        let error: Error
    }

    /// Why a report POST failed. The distinction is what makes the outbox correct: a permanent
    /// rejection drops the entry, a retryable failure keeps it for the next flush. It applies
    /// to the report POST only — an attachment upload is retried whatever its failure.
    enum DeliveryFailure: Error {
        /// The server rejected it for good (bad key, payload too large, …) — retrying is
        /// pointless, so the entry is deleted.
        case permanent(Error)
        /// Offline / transport error, or a server-side 5xx — keep the entry and retry.
        case retryable(Error)

        /// Statuses in the 4xx range that are transient by definition and MUST be retried:
        /// the request was fine, the server just couldn't take it *now*. Classifying these as
        /// permanent would delete a perfectly good report (backend rate limiting on the ingest
        /// endpoint is a planned follow-up, so 429 is not hypothetical). 407 comes from an
        /// intercepting corporate proxy, not from us. Keep this set identical to the Android
        /// SDK's `RETRYABLE_STATUSES`.
        static let retryableClientStatuses: Set<Int> = [407, 408, 425, 429]

        init(_ error: Error) {
            if case CatchDevError.server(let status) = error,
               (400..<500).contains(status),
               !Self.retryableClientStatuses.contains(status) {
                self = .permanent(error)
            } else {
                self = .retryable(error)
            }
        }
    }

    @objc public static let shared = CatchDev()

    /// Number of recent screens kept in the breadcrumb trail.
    static let breadcrumbCapacity = 20

    private let lock = NSLock()
    private let client: FeedbackClient

    /// Uploads attachments (screenshots / recordings / files) straight to R2 via a
    /// backend-minted presigned URL. Stateless, so one instance is shared.
    private let uploader: AttachmentUploader

    /// Durable queue for offline / background delivery. `nil` falls back to in-memory send.
    private let outbox: FeedbackOutbox?
    /// Whether to watch connectivity and auto-flush on reconnect (off in unit tests).
    private let reachabilityEnabled: Bool
    /// When to stop retrying attachments that won't upload.
    private let attachmentRetryLimits: AttachmentRetryLimits

    /// Serial queue for the SDK's own outbox work: the whole flush drain, and every read/write a
    /// delivery makes (reading a blob's 25–40 MB back off disk, recording an upload's receipt,
    /// ack-deleting the entry).
    ///
    /// **Its real job is to keep that work off the HOST's threads.** A `URLSession` completion
    /// runs on the session's delegate queue — in production `URLSession.shared`, whose threads the
    /// host app also uses — so continuing a delivery inline from a network callback would do the
    /// SDK's disk IO (and take the outbox's lock) on a thread the host is relying on. Every hop
    /// out of a network callback therefore lands back here first; `deliver`/`uploadBlobs` are
    /// written that way.
    ///
    /// The one thing that deliberately does NOT run here is ``submit``'s initial `enqueue`: it is
    /// synchronous on the caller's thread, because a submission scheduled but not yet written
    /// dies with a process that gets suspended right after Send (see `submit`).
    private let outboxQueue = DispatchQueue(label: "dev.catch.outbox", qos: .utility)

    /// Where `didBecomeActive` is observed. Explicitly NOT the main queue: the foreground
    /// flush touches the outbox, and `queue: nil` would run it on the posting (main) thread.
    private let notificationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    private var configuration: Configuration?
    private var user: FeedbackUser?
    private var metadata: [String: String] = [:]
    private var environment: String?
    private var areas: [String] = CatchDev.defaultAreas
    private var breadcrumbs = BreadcrumbTrail(capacity: CatchDev.breadcrumbCapacity)
    private var breadcrumbsEnabled = true
    private var networkCaptureEnabled = false
    private var shakeEnabled = true
    private var contactFieldEnabled = false
    private var screenshotAttachmentEnabled = true
    private var shakeInstalled = false
    private var trackerInstalled = false
    private var presentingReporter = false
    private var feedbackSentHandler: ((Result<String, Error>) -> Void)?
    private var debugLogging = false
    private var isFlushing = false
    private var monitorStarted = false
    private var foregroundObserved = false
    private var pathMonitor: NWPathMonitor?
    // The path monitor's most recent verdict. Defaults to reachable so we never tell an online
    // user they're offline when reachability isn't being monitored / hasn't reported yet.
    private var pathSatisfied = true

    private override init() {
        self.client = FeedbackClient()
        self.uploader = AttachmentUploader()
        self.outbox = FeedbackOutbox.defaultDirectory().map { FeedbackOutbox(directory: $0) }
        self.reachabilityEnabled = true
        self.attachmentRetryLimits = .standard
        super.init()
    }

    /// Test seam: inject a client + uploader (e.g. backed by `MockURLProtocol`) and an
    /// optional outbox to drive an instance with its own state for `submit`-level tests.
    /// Reachability monitoring is off by default here. Note `configure()` still wires the
    /// process-wide UIKit singletons (shake/tracker), so UI state is not fully isolated.
    init(
        client: FeedbackClient,
        uploader: AttachmentUploader = AttachmentUploader(),
        outbox: FeedbackOutbox? = nil,
        monitorReachability: Bool = false,
        attachmentRetryLimits: AttachmentRetryLimits = .standard
    ) {
        self.client = client
        self.uploader = uploader
        self.outbox = outbox
        self.reachabilityEnabled = monitorReachability
        self.attachmentRetryLimits = attachmentRetryLimits
        super.init()
    }

    // MARK: - Public API

    /// Start the SDK against the production catch.dev API.
    @objc(startWithApiKey:)
    public static func start(apiKey: String) {
        shared.configure(apiKey: apiKey, endpoint: nil)
    }

    /// Start the SDK against a custom API endpoint (self-hosted / staging).
    @objc(startWithApiKey:endpoint:)
    public static func start(apiKey: String, endpoint: URL?) {
        shared.configure(apiKey: apiKey, endpoint: endpoint)
    }

    /// Test-only: wipe the durable on-disk outbox so UI tests start from a clean slate.
    /// The outbox lives in Application Support and otherwise persists across app launches
    /// in the same simulator, leaking queued reports between tests.
    @_spi(CatchDevTesting)
    public static func resetPersistenceForTesting() {
        if let dir = FeedbackOutbox.defaultDirectory() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Attach an end-user identity to subsequent reports.
    @objc public static func setUser(id: String?, email: String?) {
        shared.setUser(id: id, email: email)
    }

    /// Set (or clear) just the end user's email — a first-class way to pre-fill the report's
    /// contact address without prompting. Used as the report email whenever the in-reporter
    /// Contact field is hidden or left blank. Preserves any previously set user id.
    @objc public static func setUserEmail(_ email: String?) {
        shared.withLock { state in
            state.user = FeedbackUser(id: state.user?.id, email: email)
        }
    }

    /// Attach arbitrary custom key/values to subsequent reports.
    @objc public static func setMetadata(_ metadata: [String: String]) {
        shared.setMetadata(metadata)
    }

    /// Tag reports with an environment name (e.g. `"production"`, `"staging"`).
    @objc public static func setEnvironment(_ environment: String?) {
        shared.setEnvironment(environment)
    }

    func setUser(id: String?, email: String?) {
        withLock { $0.user = FeedbackUser(id: id, email: email) }
    }

    func setMetadata(_ metadata: [String: String]) {
        withLock { $0.metadata = metadata }
    }

    func setEnvironment(_ environment: String?) {
        withLock { $0.environment = environment }
    }

    /// Whether shaking the device opens the feedback reporter. Defaults to `true`.
    @objc public static var isShakeToReportEnabled: Bool {
        get { shared.withLock { $0.shakeEnabled } }
        set {
            shared.withLock { $0.shakeEnabled = newValue }
            #if canImport(UIKit)
            ShakeDetector.shared.isEnabled = newValue
            #endif
        }
    }

    /// The areas offered by the reporter's **Area** picker, in the order shown.
    ///
    /// Defaults to ``defaultAreas``. Set your own to match how your app is actually divided
    /// (`["Checkout", "Search", "Profile", …]`); the picker scrolls, so a long list is fine.
    /// Set an **empty array** to hide the Area field entirely.
    ///
    /// Area stays optional either way — the picker offers a "None" row.
    @objc public static var areas: [String] {
        get { shared.withLock { $0.areas } }
        // Blank entries would render as an unpickable empty row.
        set { shared.withLock { $0.areas = newValue.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } } }
    }

    /// The built-in area list used when the host doesn't set its own.
    @objc public static let defaultAreas = ["Login", "Payments", "Performance", "Other"]

    /// Whether the reporter shows the **Contact email** field. Defaults to `false` — most
    /// apps identify the user via ``setUser(id:email:)`` / ``setUserEmail(_:)`` instead of
    /// asking again. When shown, a non-empty entry overrides the configured user email.
    @objc public static var isContactFieldEnabled: Bool {
        get { shared.withLock { $0.contactFieldEnabled } }
        set { shared.withLock { $0.contactFieldEnabled = newValue } }
    }

    /// Whether a screenshot of the screen that spawned the reporter is automatically attached
    /// (and available to annotate via the Screenshot tool). Defaults to `true`. Disable for
    /// apps that never want an auto-capture — the reporter then opens with no screenshot, and
    /// the user attaches evidence via the File tool instead.
    @objc public static var isScreenshotAttachmentEnabled: Bool {
        get { shared.withLock { $0.screenshotAttachmentEnabled } }
        set { shared.withLock { $0.screenshotAttachmentEnabled = newValue } }
    }

    /// Whether the SDK automatically records a breadcrumb trail of visited screens (sent
    /// inside `meta`). Defaults to `true`. Disable to stop collecting screen names — useful
    /// if screen titles can contain personal data and you don't want to override them via
    /// ``CatchDevScreenNaming``.
    @objc public static var isAutomaticBreadcrumbsEnabled: Bool {
        get { shared.isAutomaticBreadcrumbsEnabled }
        set { shared.isAutomaticBreadcrumbsEnabled = newValue }
    }

    var isAutomaticBreadcrumbsEnabled: Bool {
        get { withLock { $0.breadcrumbsEnabled } }
        set { withLock { $0.breadcrumbsEnabled = newValue } }
    }

    /// Whether the SDK includes captured FAILED host network calls (non-2xx responses +
    /// transport errors) in the reporter's "Failed network calls" diagnostic. **Off by
    /// default.** The SDK does NOT intercept the host's `URLSession` (that would break
    /// cookies/auth/pinning/uploads); when enabled, the host reports failures via
    /// ``recordFailedRequest(method:url:status:)`` — e.g. from a `URLSession` delegate or an
    /// Alamofire event monitor. Records are redacted to method + host/path + status.
    @objc public static var isNetworkCaptureEnabled: Bool {
        get { shared.withLock { $0.networkCaptureEnabled } }
        set { shared.withLock { $0.networkCaptureEnabled = newValue } }
    }

    /// Report a failed host request for the diagnostic. No-op unless capture is enabled.
    @objc public static func recordFailedRequest(method: String, url: String, status: Int) {
        guard shared.withLock({ $0.networkCaptureEnabled }) else { return }
        CatchDevNetworkCapture.shared.record(method: method, url: url, status: status)
    }

    /// Print SDK diagnostics to the console. Off by default — useful while integrating.
    @objc public static var isDebugLoggingEnabled: Bool {
        get { shared.withLock { $0.debugLogging } }
        set { shared.withLock { $0.debugLogging = newValue } }
    }

    /// Invoked on the main thread once per submission, with its final outcome. Lets
    /// integrators confirm delivery and instrument analytics. (Swift only.)
    ///
    /// - `.success(id)`: the report and every attachment reached catch.dev; `id` is the
    ///   server's id for the report.
    /// - `.failure(CatchDevAttachmentsNotDelivered)`: the report reached catch.dev (its
    ///   `reportId` is in the error), but some attachments never uploaded before the retry
    ///   limits ran out.
    /// - `.failure(CatchDevError)`: the report was not delivered (rejected by the server, or
    ///   the SDK was not started).
    ///
    /// A submission that is still waiting in the outbox — offline, or with attachments still
    /// retrying — has no outcome yet, so the callback fires later, from the flush that
    /// settles it.
    public static var onFeedbackSent: ((Result<String, Error>) -> Void)? {
        get { shared.onFeedbackSent }
        set { shared.onFeedbackSent = newValue }
    }

    var onFeedbackSent: ((Result<String, Error>) -> Void)? {
        get { withLock { $0.feedbackSentHandler } }
        set { withLock { $0.feedbackSentHandler = newValue } }
    }

    // MARK: - Internal

    func configure(apiKey: String, endpoint: URL?) {
        withLock {
            $0.configuration = Configuration(
                apiKey: apiKey,
                endpoint: endpoint ?? Configuration.defaultEndpoint
            )
        }
        #if canImport(UIKit)
        installShakeDetectorIfNeeded()
        ShakeDetector.shared.isEnabled = withLock { $0.shakeEnabled }
        installViewControllerTrackerIfNeeded()
        observeForegroundIfNeeded()
        #endif
        startReachabilityMonitorIfNeeded()
        // Deliver anything left over from a previous offline session / launch.
        flushPending()
    }

    /// Assemble a report from the current context and deliver it.
    ///
    /// **Persist first.** The report AND the raw bytes of every not-yet-uploaded attachment
    /// (`pendingAttachments`) are written to the durable outbox BEFORE any network call, so
    /// an offline period or a crash mid-send can't lose them. Only then does the SDK upload
    /// the attachments and POST the report. The same `reportId` is replayed on the next
    /// flush and the server dedupes on it, so a replay can never duplicate a report.
    ///
    /// Offline, the completion reports `.queued` (a success-style state), not an error. When
    /// the report lands but an attachment upload fails, it reports `.attachmentsPending` and the
    /// attachment stays queued. `onFeedbackSent` fires only with a submission's final outcome.
    ///
    /// **Threading.** The report is assembled AND persisted on the calling thread — see the
    /// "persist first, synchronously" comment below for why the persist may not be deferred to a
    /// queue — and everything after it (uploads, the report POST, and the outbox writes they
    /// drive) runs on ``outboxQueue``. `completion` therefore lands on a background thread;
    /// callers that drive UI from it must hop to main themselves (the reporter does).
    func submit(
        message: String,
        imageData: Data?,
        type: ReportType = .feedback,
        severity: Severity? = nil,
        area: String? = nil,
        contactEmail: String? = nil,
        attachments: [Attachment] = [],
        pendingAttachments: [PendingBlob] = [],
        reportId: String? = nil,
        screenName: String? = nil,
        excludedDiagnostics: Set<DiagnosticID> = [],
        completion: @escaping (Result<SubmissionOutcome, Error>) -> Void
    ) {
        let (configuration, user, metadata, environment, breadcrumbs, networkCapture) = withLock { state in
            (state.configuration, state.user, state.metadata, state.environment,
             state.breadcrumbs.snapshot(), state.networkCaptureEnabled)
        }
        guard let configuration else {
            notifyFeedbackSent(.failure(CatchDevError.notStarted))
            completion(.failure(CatchDevError.notStarted))
            return
        }
        var report = FeedbackReport(message: message)
        if let reportId { report.reportId = reportId }
        report.type = type
        report.severity = severity
        report.area = area
        // Contact field (when set) overrides the configured user email.
        let trimmedContact = contactEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        report.email = (trimmedContact?.isEmpty == false) ? trimmedContact : user?.email
        report.userId = user?.id
        report.metadata = metadata
        report.environment = environment
        report.screenName = screenName
        report.breadcrumbs = breadcrumbs
        report.attachments = attachments
        report.imageData = imageData
        report.applyDeviceContext()

        // Diagnostics the SDK contributes automatically. Session is always included
        // (locked in the UI); the rest are dropped when the user toggled them off.
        report.sessionId = SessionInfo.sessionId
        if networkCapture, !excludedDiagnostics.contains(.network) {
            report.failedRequests = CatchDevNetworkCapture.shared.snapshot()
        }
        if excludedDiagnostics.contains(.screen) { report.screenName = nil }
        if excludedDiagnostics.contains(.user) { report.userId = nil }
        if excludedDiagnostics.contains(.breadcrumbs) { report.breadcrumbs = [] }
        if excludedDiagnostics.contains(.version) {
            report.appVersion = nil
            report.appBuild = nil
        }
        if excludedDiagnostics.contains(.device) {
            report.device = nil
            report.osVersion = nil
        }

        let reportId = report.reportId

        // 1. PERSIST FIRST — report + every attachment's bytes, before any network call, and
        // SYNCHRONOUSLY, on the caller's thread, before `submit` returns.
        //
        // The persist may NOT be moved onto `outboxQueue`. Tapping Send and immediately
        // backgrounding the app (home gesture, an incoming call, an app switch) is an ordinary
        // gesture, and iOS suspends — and later jetsams — a backgrounded process without running
        // whatever was merely *scheduled*. A deferred enqueue therefore loses the report, the
        // typed message and the recording outright, which is the exact loss the outbox exists to
        // prevent. Blocking the caller for one file write (under the reporter's "Sending report…"
        // overlay) is the price of "after submit returns, this submission survives the process
        // dying". Everything after the persist — uploads, the POST, the outbox writes they drive —
        // runs on `outboxQueue`.
        //
        // Claim the entry BEFORE `enqueue` publishes it. The claim lives in the OUTBOX, so it
        // also stops the caps from evicting the entry we are about to upload. If a flush already
        // owns it, it is durable and in flight — say "queued" rather than sending the same report
        // (and re-uploading its bytes) twice.
        var queuedDurably = false
        var holding = false
        if let outbox {
            guard outbox.hold(reportId) else {
                log("submit: \(reportId) is already being delivered by a flush — queued")
                completion(.success(.queued(reportId: reportId)))
                return
            }
            do {
                try outbox.enqueue(report, blobs: pendingAttachments)
                queuedDurably = true
                holding = true
            } catch {
                // Persistence failed (disk full): fall back to a best-effort in-memory send —
                // and there is nothing on disk left to claim.
                log("outbox enqueue failed: \(error)")
                outbox.release(reportId)
            }
        }
        // Only a durably-persisted entry may be reported as "queued" (and kept on failure).
        let durableOutbox = queuedDurably ? outbox : nil

        outboxQueue.async { [weak self] in
            guard let self else { return }

            // Deliver from the DURABLE entry, byte-for-byte the way a flush would: the report
            // and the blob bytes are re-read from disk, so the receipts `markUploaded` writes
            // ("this blob landed") are observable here too. Only when there is no durable entry
            // do we fall back to the in-memory bytes.
            let deliveryReport: FeedbackReport
            let blobs: [OutboxBlob]
            let loadBlob: (OutboxBlob) -> Data?
            if let durableOutbox, let entry = durableOutbox.entry(reportId: reportId) {
                deliveryReport = entry.report
                blobs = entry.blobs
                loadBlob = { blob in durableOutbox.blobData(reportId: reportId, index: blob.index) }
            } else {
                deliveryReport = report
                // Descriptors mirror what `enqueue` would have written (index = position).
                blobs = pendingAttachments.enumerated().map { index, blob in
                    OutboxBlob(
                        index: index, kind: blob.kind, contentType: blob.contentType,
                        filename: blob.filename, annotated: blob.annotated, size: blob.data.count
                    )
                }
                loadBlob = { descriptor in
                    pendingAttachments.indices.contains(descriptor.index)
                        ? pendingAttachments[descriptor.index].data
                        : nil
                }
            }

            // 2/3. DELIVER, then ACK-then-delete (handled inside `deliver`).
            self.deliver(
                report: deliveryReport, blobs: blobs, loadBlob: loadBlob,
                outbox: durableOutbox, configuration: configuration
            ) { [weak self] outcome in
                guard let self else { return }
                if holding { self.endDelivery(of: reportId) }
                switch outcome {
                case .delivered(let id):
                    self.notifyFeedbackSent(.success(id))
                    completion(.success(.delivered(reportId: id)))
                case .attachmentsPending(let id):
                    // The report is on the server; its missing attachments stay in the outbox
                    // for the next flush. No onFeedbackSent yet: that waits for the outcome.
                    completion(.success(.attachmentsPending(reportId: id)))
                case .attachmentsAbandoned(let error):
                    // Only reachable without a durable entry (nothing could retry them).
                    self.notifyFeedbackSent(.failure(error))
                    completion(.failure(error))
                case .rejected(let error):
                    // 4. The server rejected it for good; the entry is already dropped.
                    self.notifyFeedbackSent(.failure(error))
                    completion(.failure(error))
                case .deferred(let error):
                    // 5. Offline: the entry stays on disk and is delivered on reconnect. Report
                    // it QUEUED (a success state) so the reporter dismisses normally instead of
                    // showing "Couldn't send report"; onFeedbackSent fires when it lands.
                    if queuedDurably {
                        self.log("submit deferred (offline) — queued \(reportId)")
                        completion(.success(.queued(reportId: reportId)))
                    } else {
                        self.notifyFeedbackSent(.failure(error))
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// Deliver one submission: upload every still-pending attachment (persisting each
    /// reference as it lands), then POST the report — even when an upload failed, so the
    /// user's report reaches the dashboard while R2 is broken. The durable entry is removed
    /// only once the server has the report AND every attachment, once it refuses the report
    /// for good, or once the missing attachments run out of retries
    /// (``settleMissingAttachments(report:id:failures:unconfirmed:outbox:)``).
    ///
    /// **A retry relies on the server's dedupe.** The next attempt mints fresh upload URLs for
    /// whatever is still pending (the server never hands URLs back, and a presigned URL expires
    /// after an hour anyway), uploads those bytes, and re-POSTs the report under the same
    /// `reportId`, listing every reference. The server keeps the existing row and the
    /// attachments it already stored, and checks only the references it doesn't have yet.
    ///
    /// **Callers must hold the entry's delivery claim** (``beginDelivery(of:)``) for the whole
    /// call: this reads and rewrites on-disk state that a second, concurrent delivery of the
    /// same entry would race.
    ///
    /// **Threading.** Call it on ``outboxQueue``. Every continuation that follows a network hop
    /// is dispatched back onto it before it touches the outbox — never inline on the URLSession
    /// completion thread, which belongs to the host.
    private func deliver(
        report: FeedbackReport,
        blobs: [OutboxBlob],
        loadBlob: @escaping (OutboxBlob) -> Data?,
        outbox: FeedbackOutbox?,
        configuration: Configuration,
        completion: @escaping (DeliveryOutcome) -> Void
    ) {
        uploadBlobs(
            report: report, blobs: blobs, index: 0, failures: [], loadBlob: loadBlob,
            outbox: outbox, configuration: configuration
        ) { [weak self] pass in
            guard let self else { return }
            let ready = pass.report
            self.client.send(ready, configuration: configuration) { [weak self] sendResult in
                guard let self else { return }
                // Back onto the outbox queue: deleting the entry is disk IO, and this callback is
                // running on the URLSession's delegate thread.
                self.outboxQueue.async {
                    switch sendResult {
                    case .success(let ack):
                        let id = ack.id.isEmpty ? report.reportId : ack.id
                        // References the server could not find in R2 (its HEAD came back empty
                        // or failed): the upload "succeeded", yet the attachment isn't stored. A
                        // server too old to send the count is taken at its word.
                        let listed = ready.attachments.count
                        let unconfirmed = max(0, listed - (ack.storedAttachments ?? listed))
                        if pass.failures.isEmpty, unconfirmed == 0 {
                            outbox?.remove(reportId: report.reportId) // ack-then-delete
                            completion(.delivered(id: id))
                        } else {
                            completion(self.settleMissingAttachments(
                                report: report, id: id, failures: pass.failures,
                                unconfirmed: unconfirmed, outbox: outbox
                            ))
                        }
                    case .failure(let error):
                        switch DeliveryFailure(error) {
                        case .permanent(let error):
                            outbox?.remove(reportId: report.reportId)
                            completion(.rejected(error))
                        case .retryable(let error):
                            completion(.deferred(error))
                        }
                    }
                }
            }
        }
    }

    /// The report reached the server, but attachments did not: `failures` never uploaded, and
    /// `unconfirmed` uploaded references the server could not find. Count the attempt, then
    /// either keep the entry for the next flush or — once both ``AttachmentRetryLimits`` are
    /// reached — give up on those attachments, log it even with debug logging off, and drop
    /// the entry.
    ///
    /// Without a durable entry there is nothing to retry from, so the attempt is final.
    private func settleMissingAttachments(
        report: FeedbackReport,
        id: String,
        failures: [AttachmentFailure],
        unconfirmed: Int,
        outbox: FeedbackOutbox?
    ) -> DeliveryOutcome {
        let missing = failures.count + unconfirmed
        var attempts = 1
        if let outbox {
            attempts = outbox.recordAttachmentAttempt(reportId: report.reportId)
            // An unreadable `time` counts as old enough, so the attempt limit alone bounds it.
            let age = Timestamp.date(from: report.time).map { Date().timeIntervalSince($0) } ?? .infinity
            guard attempts >= attachmentRetryLimits.maxAttempts, age >= attachmentRetryLimits.maxAge else {
                log("report \(id) reached the server; \(missing) attachment(s) still missing after attempt \(attempts) — kept for the next flush")
                return .attachmentsPending(id: id)
            }
            outbox.remove(reportId: report.reportId)
        }
        for failure in failures {
            warn(
                "giving up on attachment \(failure.blob.index) (\(failure.blob.kind.rawValue), "
                    + "\(failure.blob.size) bytes) of report \(id) after \(attempts) failed attempt(s); "
                    + "last error: \(failure.error)"
            )
        }
        if unconfirmed > 0 {
            warn(
                "giving up on \(unconfirmed) attachment(s) of report \(id) that uploaded but that "
                    + "the server could not find in storage, after \(attempts) attempt(s)"
            )
        }
        return .attachmentsAbandoned(CatchDevAttachmentsNotDelivered(
            reportId: id, missingCount: missing, underlyingError: failures.last?.error
        ))
    }

    /// One pass over an entry's pending blobs: the report carrying every reference that has
    /// landed so far, and the blobs whose upload failed this time.
    struct UploadPass {
        let report: FeedbackReport
        let failures: [AttachmentFailure]
    }

    /// Upload the pending attachment blobs one at a time, appending each returned reference
    /// to the report (and persisting it) as soon as it lands — so a replay never re-uploads
    /// bytes that already reached R2. A failed upload, whatever the failure, is recorded and
    /// the pass moves on to the next blob; the failed blob's bytes stay on disk for the next
    /// attempt.
    ///
    /// Runs on ``outboxQueue`` — including every recursive step, which is why the uploader's
    /// completion hops back onto it before reading the next blob or writing a receipt.
    private func uploadBlobs(
        report: FeedbackReport,
        blobs: [OutboxBlob],
        index: Int,
        failures: [AttachmentFailure],
        loadBlob: @escaping (OutboxBlob) -> Data?,
        outbox: FeedbackOutbox?,
        configuration: Configuration,
        completion: @escaping (UploadPass) -> Void
    ) {
        guard index < blobs.count else {
            completion(UploadPass(report: report, failures: failures))
            return
        }
        let blob = blobs[index]
        guard let data = loadBlob(blob) else {
            // The bytes we were told are still pending are gone or unreadable. "Gone" may only
            // be read as "already uploaded" with PROOF: a receipt for this exact blob index.
            // Without one it is an ordinary failed blob — it stays pending, and the entry
            // cannot complete (or be ack-deleted) without it.
            var next = report
            var failed = failures
            if let receipt = outbox?.uploadedAttachment(reportId: report.reportId, index: blob.index) {
                if !next.attachments.contains(receipt) { next.attachments.append(receipt) }
            } else {
                log("blob \(blob.index) of \(report.reportId) is unreadable with no receipt — kept for retry")
                failed.append(AttachmentFailure(
                    blob: blob, error: CatchDevError.transport(OutboxError.blobMissing)
                ))
            }
            uploadBlobs(
                report: next, blobs: blobs, index: index + 1, failures: failed, loadBlob: loadBlob,
                outbox: outbox, configuration: configuration, completion: completion
            )
            return
        }
        uploader.upload(
            data: data, kind: blob.kind, contentType: blob.contentType,
            filename: blob.filename, annotated: blob.annotated, configuration: configuration
        ) { [weak self] result in
            guard let self else { return }
            // Hop back to the outbox queue BEFORE touching the outbox: this callback is on the
            // URLSession delegate thread (in production, `URLSession.shared`'s — the host app's
            // too), and what follows writes a receipt / deletes bytes / reads the next 25–40 MB
            // blob. The SDK does its disk work on its own queue, never on the host's threads.
            self.outboxQueue.async {
                switch result {
                case .failure(let error):
                    // Kept for the next attempt, whatever the failure — a 4xx included. R2
                    // answering 403 (a bucket that is misconfigured or not enabled) is exactly the
                    // outage this retry exists for: treating it as permanent turned every R2
                    // problem into silent screenshot loss. `AttachmentRetryLimits` bounds it.
                    self.log("attachment \(blob.index) of \(report.reportId) failed to upload (\(error)) — kept for retry")
                    self.uploadBlobs(
                        report: report, blobs: blobs, index: index + 1,
                        failures: failures + [AttachmentFailure(blob: blob, error: error)],
                        loadBlob: loadBlob, outbox: outbox, configuration: configuration,
                        completion: completion
                    )
                case .success(let attachment):
                    outbox?.markUploaded(
                        reportId: report.reportId, blobIndex: blob.index, attachment: attachment
                    )
                    var next = report
                    next.attachments.append(attachment)
                    self.uploadBlobs(
                        report: next, blobs: blobs, index: index + 1, failures: failures,
                        loadBlob: loadBlob, outbox: outbox, configuration: configuration,
                        completion: completion
                    )
                }
            }
        }
    }

    /// Drain the outbox, oldest first, delivering each queued entry (uploading any
    /// attachment bytes it still carries, then posting the report). Delivered and
    /// permanently-rejected entries are removed; an entry whose report landed but whose
    /// attachments didn't stays for the next flush, and the drain moves on; on a transport
    /// failure (still offline) it stops and leaves the rest queued.
    ///
    /// Two latches keep this correct: `isFlushing` serializes flush-vs-flush (launch,
    /// reconnect, foreground can all fire at once), and the per-entry delivery claim
    /// (``beginDelivery(of:)``, which is the outbox's own `hold`) serializes flush-vs-`submit`
    /// — a report is in the outbox while its own `submit` is still uploading it, and
    /// delivering it again from here would double-send it.
    ///
    /// **Threading.** Called from `didFinishLaunching` (via `configure`), from the reachability
    /// monitor, and on every foreground — so the whole drain runs on ``outboxQueue``, never on
    /// the caller's thread.
    func flushPending() {
        guard let outbox else { return }
        let configuration = withLock { $0.configuration }
        guard let configuration else { return }
        let shouldFlush = withLock { state -> Bool in
            if state.isFlushing { return false }
            state.isFlushing = true
            return true
        }
        guard shouldFlush else { return }
        outboxQueue.async { [weak self] in
            // IDs only — `pending()` would read every queued entry's screenshot into memory
            // just to build a work list. Each entry is re-read from disk immediately before it
            // is delivered anyway, because delivering the entries ahead of it takes seconds
            // during which an in-flight submit can advance it (record a receipt, drop a blob's
            // bytes) or finish it outright.
            guard let self else { return }
            self.flushNext(
                outbox.pendingReportIds(), index: 0, configuration: configuration, outbox: outbox
            )
        }
    }

    /// Runs on ``outboxQueue`` (it reads the entry off disk); the network hops it kicks off
    /// call back on their own threads and re-enter via `advance`, which hops back.
    private func flushNext(
        _ reportIds: [String],
        index: Int,
        configuration: Configuration,
        outbox: FeedbackOutbox
    ) {
        guard index < reportIds.count else {
            withLock { $0.isFlushing = false }
            return
        }
        let reportId = reportIds[index]
        let advance = { [weak self] in
            guard let self else { return }
            self.outboxQueue.async {
                self.flushNext(reportIds, index: index + 1, configuration: configuration, outbox: outbox)
            }
        }

        // `submit` is delivering this entry right now — leave it alone.
        guard beginDelivery(of: reportId) else {
            log("flush: \(reportId) is already being delivered — skipped")
            advance()
            return
        }
        // Re-read from disk: since the snapshot, the entry may have been delivered, evicted,
        // or had attachment references appended by the submit that owns it.
        guard let entry = outbox.entry(reportId: reportId) else {
            endDelivery(of: reportId)
            advance()
            return
        }
        deliver(
            report: entry.report,
            blobs: entry.blobs,
            loadBlob: { blob in outbox.blobData(reportId: reportId, index: blob.index) },
            outbox: outbox,
            configuration: configuration
        ) { [weak self] outcome in
            guard let self else { return }
            self.endDelivery(of: reportId)
            switch outcome {
            case .delivered(let id):
                self.notifyFeedbackSent(.success(id))
                advance()
            case .attachmentsPending:
                // The server took the report, so it is reachable: keep draining. This entry's
                // missing attachments wait for the next flush.
                advance()
            case .attachmentsAbandoned(let error):
                self.notifyFeedbackSent(.failure(error)) // the entry is already dropped
                advance()
            case .rejected(let error):
                self.notifyFeedbackSent(.failure(error)) // the entry is already dropped
                advance()
            case .deferred:
                // Still offline — stop and keep this and the remaining entries queued.
                self.withLock { $0.isFlushing = false }
            }
        }
    }

    /// Claim exclusive delivery of one outbox entry; `false` means another path already holds
    /// it and the caller must not deliver it.
    ///
    /// The entry is on disk from BEFORE the first network call until the ack, which makes it
    /// visible to `submit`'s own delivery *and* to every flush trigger (launch, reconnect,
    /// foreground). Without this claim the two deliver the same entry concurrently: the bytes
    /// are uploaded twice, `onFeedbackSent` fires twice for one report, and — worst — the
    /// loser POSTs its stale copy of the report and then ack-deletes the entry holding the
    /// winner's attachment references, losing the evidence for good. `isFlushing` cannot cover
    /// this; it only latches flush-vs-flush.
    ///
    /// The claim itself lives in ``FeedbackOutbox`` (`hold`/`release`), not here, because the
    /// outbox is what *deletes* entries: a cap eviction firing mid-delivery would otherwise
    /// delete the folder whose blobs a deliverer is uploading — the very loss this claim
    /// exists to prevent. An SDK-side set could not be seen by `enforceCapacity`.
    private func beginDelivery(of reportId: String) -> Bool {
        outbox?.hold(reportId) ?? true
    }

    private func endDelivery(of reportId: String) {
        outbox?.release(reportId)
    }

    private func startReachabilityMonitorIfNeeded() {
        guard reachabilityEnabled, outbox != nil else { return }
        let shouldStart = withLock { state -> Bool in
            if state.monitorStarted { return true }
            state.monitorStarted = true
            return false
        }
        guard !shouldStart else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            self?.withLock { $0.pathSatisfied = satisfied }
            if satisfied { self?.flushPending() }
        }
        monitor.start(queue: DispatchQueue(label: "dev.catch.reachability"))
        withLock { $0.pathMonitor = monitor }
    }

    /// Whether a flush is draining the outbox right now. A `flushPending()` call made while one
    /// is still running is ignored, so tests wait for this to clear before flushing again.
    var isFlushInProgress: Bool { withLock { $0.isFlushing } }

    /// Whether the device currently has no satisfied network path, per the outbox's reachability
    /// monitor. Used by the reporter to tell "you're offline" apart from "the server was briefly
    /// unreachable" on the queued overlay. Defaults to `false` (online) when reachability isn't
    /// monitored, so an online user is never told they're offline.
    func isCurrentlyOffline() -> Bool {
        withLock { !$0.pathSatisfied }
    }

    /// Append a visited screen to the breadcrumb trail (no-op when automatic breadcrumbs
    /// are disabled). Thread-safe; the screen name is resolved by the caller (UIKit) so no
    /// UIKit work happens inside the lock.
    func recordBreadcrumb(screen: String) {
        let crumb = Breadcrumb(screen: screen, time: Timestamp.now())
        withLock { state in
            guard state.breadcrumbsEnabled else { return }
            state.breadcrumbs.record(crumb)
        }
    }

    /// The configured end-user id, for the reporter's "User ID" diagnostic row.
    var currentUserId: String? { withLock { $0.user?.id } }

    /// Number of breadcrumbs currently in the trail, for the diagnostics summary.
    var breadcrumbCount: Int { withLock { $0.breadcrumbs.snapshot().count } }

    private func notifyFeedbackSent(_ result: Result<String, Error>) {
        guard let handler = withLock({ $0.feedbackSentHandler }) else { return }
        DispatchQueue.main.async { handler(result) }
    }

    func log(_ message: @autoclosure () -> String) {
        guard withLock({ $0.debugLogging }) else { return }
        print("[CatchDev] \(message())")
    }

    /// Logged whether or not debug logging is on. Reserved for the SDK giving up on something
    /// the user submitted, which must never happen silently.
    func warn(_ message: String) {
        Self.warn(message)
    }

    static func warn(_ message: String) {
        NSLog("[CatchDev] %@", message)
    }

    @discardableResult
    private func withLock<T>(_ body: (CatchDev) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    // MARK: - UI (iOS only)

    #if canImport(UIKit)
    /// Open the feedback reporter manually (e.g. from a "Send feedback" button).
    /// Safe to call from any thread — capture and presentation happen on the main thread.
    @objc public static func presentReporter() {
        shared.presentReporter()
    }

    private func installShakeDetectorIfNeeded() {
        let alreadyInstalled = withLock { state -> Bool in
            if state.shakeInstalled { return true }
            state.shakeInstalled = true
            return false
        }
        guard !alreadyInstalled else { return }
        ShakeDetector.shared.install()
        ShakeDetector.shared.onShake = { [weak self] in
            self?.presentReporter()
        }
    }

    private func installViewControllerTrackerIfNeeded() {
        let alreadyInstalled = withLock { state -> Bool in
            if state.trackerInstalled { return true }
            state.trackerInstalled = true
            return false
        }
        guard !alreadyInstalled else { return }
        // Set the handler BEFORE installing the swizzle so the first screen's appearance
        // (which can fire synchronously as the window is made key) is never missed.
        ViewControllerTracker.shared.onAppear = { [weak self] viewController in
            // Resolve the name (UIKit, main thread) BEFORE entering the lock.
            let name = ScreenName.resolve(viewController)
            self?.recordBreadcrumb(screen: name)
        }
        ViewControllerTracker.shared.install()
    }

    private func observeForegroundIfNeeded() {
        let alreadyObserved = withLock { state -> Bool in
            if state.foregroundObserved { return true }
            state.foregroundObserved = true
            return false
        }
        guard !alreadyObserved else { return }
        // Returning to the foreground is a common moment connectivity is restored. Observed on
        // an explicit background queue: `queue: nil` delivers on the POSTING thread, which for
        // `didBecomeActive` is the main thread — and the flush this fires reads the outbox.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: notificationQueue
        ) { [weak self] _ in
            self?.flushPending()
        }
    }

    func presentReporter() {
        DispatchQueue.main.async {
            guard self.withLock({ $0.configuration != nil }) else {
                self.log("presentReporter() called before start(apiKey:) — ignored.")
                return
            }

            // Reject re-entrant presentation (e.g. a rapid double shake, or a shake
            // while the reporter is already up). The latch is cleared when the
            // reporter is dismissed (ReporterViewController.onClose).
            let alreadyPresenting = self.withLock { state -> Bool in
                if state.presentingReporter { return true }
                state.presentingReporter = true
                return false
            }
            guard !alreadyPresenting else { return }

            guard let presenter = UIApplication.cdv_topViewController(),
                  presenter.view.window != nil,
                  !presenter.isBeingDismissed
            else {
                self.withLock { $0.presentingReporter = false }
                self.log("presentReporter(): no view controller available to present from — ignored.")
                return
            }

            // Capture on the main thread, immediately before presenting, so the
            // reporter UI is not part of the screenshot. Resolve the screen name from
            // the SAME presenter now — at submit-time the top VC is the reporter itself.
            // A pending restore (returning from the Record flow) reopens the same draft
            // instead of capturing a fresh screenshot.
            let reporter: ReporterViewController
            if let restore = ReporterViewController.consumePendingRestore() {
                reporter = ReporterViewController(restoring: restore)
            } else {
                let screenName = ScreenName.resolve(presenter)
                let attachShot = self.withLock { $0.screenshotAttachmentEnabled }
                reporter = ReporterViewController(
                    screenshot: attachShot ? ScreenshotCapturer.capture() : nil,
                    screenName: screenName
                )
            }
            reporter.onClose = { [weak self] in
                self?.withLock { $0.presentingReporter = false }
            }
            let container = ReporterContainer(rootViewController: reporter)
            container.modalPresentationStyle = .fullScreen
            presenter.present(container, animated: true)

            // UIKit can reject a presentation with only a console warning (presenter
            // already presenting, mid-transition). The reporter's deinit backstop
            // clears the latch when that happens; this check surfaces it early. The
            // isBeingPresented guard avoids a false release while UIKit is still
            // setting up a deferred-but-accepted presentation.
            DispatchQueue.main.async { [weak self] in
                if container.presentingViewController == nil, !container.isBeingPresented {
                    self?.withLock { $0.presentingReporter = false }
                    self?.log("presentReporter(): UIKit did not accept the presentation — latch released.")
                }
            }
        }
    }
    #endif
}
