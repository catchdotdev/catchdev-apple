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

    @objc public static let shared = CatchDev()

    /// Number of recent screens kept in the breadcrumb trail.
    static let breadcrumbCapacity = 20

    private let lock = NSLock()
    private let client: FeedbackClient

    /// Durable queue for offline / background delivery. `nil` falls back to in-memory send.
    private let outbox: FeedbackOutbox?
    /// Whether to watch connectivity and auto-flush on reconnect (off in unit tests).
    private let reachabilityEnabled: Bool

    private var configuration: Configuration?
    private var user: FeedbackUser?
    private var metadata: [String: String] = [:]
    private var environment: String?
    private var breadcrumbs = BreadcrumbTrail(capacity: CatchDev.breadcrumbCapacity)
    private var breadcrumbsEnabled = true
    private var shakeEnabled = true
    private var shakeInstalled = false
    private var trackerInstalled = false
    private var presentingReporter = false
    private var feedbackSentHandler: ((Result<String, Error>) -> Void)?
    private var debugLogging = false
    private var isFlushing = false
    private var monitorStarted = false
    private var foregroundObserved = false
    private var pathMonitor: NWPathMonitor?

    private override init() {
        self.client = FeedbackClient()
        self.outbox = FeedbackOutbox.defaultDirectory().map { FeedbackOutbox(directory: $0) }
        self.reachabilityEnabled = true
        super.init()
    }

    /// Test seam: inject a client (e.g. one backed by `MockURLProtocol`) and an optional
    /// outbox to drive an instance with its own state for `submit`-level tests. Reachability
    /// monitoring is off by default here. Note `configure()` still wires the process-wide
    /// UIKit singletons (shake/tracker), so UI state is not fully isolated.
    init(client: FeedbackClient, outbox: FeedbackOutbox? = nil, monitorReachability: Bool = false) {
        self.client = client
        self.outbox = outbox
        self.reachabilityEnabled = monitorReachability
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

    /// Attach an end-user identity to subsequent reports.
    @objc public static func setUser(id: String?, email: String?) {
        shared.setUser(id: id, email: email)
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

    /// Print SDK diagnostics to the console. Off by default — useful while integrating.
    @objc public static var isDebugLoggingEnabled: Bool {
        get { shared.withLock { $0.debugLogging } }
        set { shared.withLock { $0.debugLogging = newValue } }
    }

    /// Invoked on the main thread after every submission with the server report id
    /// on success, or the error on failure. Lets integrators confirm delivery and
    /// instrument analytics. (Swift only.)
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

    /// Assemble a report from the current context and send it. The report is durably
    /// enqueued to the outbox FIRST, so an offline period or a crash mid-send can't lose
    /// it — the same `reportId` is replayed on the next flush and the server dedupes on it.
    func submit(
        message: String,
        imageData: Data?,
        reportId: String? = nil,
        screenName: String? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let (configuration, user, metadata, environment, breadcrumbs) = withLock { state in
            (state.configuration, state.user, state.metadata, state.environment,
             state.breadcrumbs.snapshot())
        }
        guard let configuration else {
            let result: Result<String, Error> = .failure(CatchDevError.notStarted)
            notifyFeedbackSent(result)
            completion(result)
            return
        }
        var report = FeedbackReport(message: message)
        if let reportId { report.reportId = reportId }
        report.email = user?.email
        report.userId = user?.id
        report.metadata = metadata
        report.environment = environment
        report.screenName = screenName
        report.breadcrumbs = breadcrumbs
        report.imageData = imageData
        report.applyDeviceContext()

        // Persist before attempting the network so the report survives offline / app death.
        var queuedDurably = false
        if let outbox {
            do { try outbox.enqueue(report); queuedDurably = true }
            catch { log("outbox enqueue failed: \(error)") }
        }

        client.send(report, configuration: configuration) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let id):
                self.outbox?.remove(reportId: report.reportId)
                self.notifyFeedbackSent(.success(id))
                completion(.success(id))
            case .failure(CatchDevError.server(let status)):
                // Server rejected it (bad key, too large, …) — permanent; don't keep it.
                self.outbox?.remove(reportId: report.reportId)
                self.notifyFeedbackSent(.failure(CatchDevError.server(status: status)))
                completion(.failure(CatchDevError.server(status: status)))
            case .failure(let error):
                if queuedDurably {
                    // Transport/offline: it stays queued and is delivered on reconnect.
                    // Report it accepted so the reporter dismisses; onFeedbackSent fires
                    // later when the flush actually delivers it.
                    self.log("submit deferred (offline) — queued \(report.reportId)")
                    completion(.success(report.reportId))
                } else {
                    self.notifyFeedbackSent(.failure(error))
                    completion(.failure(error))
                }
            }
        }
    }

    /// Drain the outbox, oldest first, delivering each queued report. Delivered and
    /// server-rejected reports are removed; on a transport failure (still offline) it stops
    /// and leaves the rest for the next trigger. Serialized so concurrent triggers (launch,
    /// reconnect, foreground) don't double-send.
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
        flushNext(outbox.pending(), index: 0, configuration: configuration, outbox: outbox)
    }

    private func flushNext(
        _ reports: [FeedbackReport],
        index: Int,
        configuration: Configuration,
        outbox: FeedbackOutbox
    ) {
        guard index < reports.count else {
            withLock { $0.isFlushing = false }
            return
        }
        let report = reports[index]
        client.send(report, configuration: configuration) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let id):
                outbox.remove(reportId: report.reportId)
                self.notifyFeedbackSent(.success(id))
                self.flushNext(reports, index: index + 1, configuration: configuration, outbox: outbox)
            case .failure(CatchDevError.server(let status)):
                outbox.remove(reportId: report.reportId) // permanent rejection — drop it
                self.notifyFeedbackSent(.failure(CatchDevError.server(status: status)))
                self.flushNext(reports, index: index + 1, configuration: configuration, outbox: outbox)
            case .failure:
                // Still offline — stop and keep this and the remaining reports queued.
                self.withLock { $0.isFlushing = false }
            }
        }
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
            if path.status == .satisfied { self?.flushPending() }
        }
        monitor.start(queue: DispatchQueue(label: "dev.catch.reachability"))
        withLock { $0.pathMonitor = monitor }
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

    private func notifyFeedbackSent(_ result: Result<String, Error>) {
        guard let handler = withLock({ $0.feedbackSentHandler }) else { return }
        DispatchQueue.main.async { handler(result) }
    }

    func log(_ message: @autoclosure () -> String) {
        guard withLock({ $0.debugLogging }) else { return }
        print("[CatchDev] \(message())")
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
        // Returning to the foreground is a common moment connectivity is restored.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
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
            let screenName = ScreenName.resolve(presenter)
            let reporter = ReporterViewController(
                screenshot: ScreenshotCapturer.capture(),
                screenName: screenName
            )
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
