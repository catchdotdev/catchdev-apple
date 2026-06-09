import Foundation
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

    private let lock = NSLock()
    private let client = FeedbackClient()

    private var configuration: Configuration?
    private var user: FeedbackUser?
    private var metadata: [String: String] = [:]
    private var environment: String?
    private var shakeEnabled = true
    private var shakeInstalled = false

    private override init() { super.init() }

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
        shared.withLock { $0.user = FeedbackUser(id: id, email: email) }
    }

    /// Attach arbitrary custom key/values to subsequent reports.
    @objc public static func setMetadata(_ metadata: [String: String]) {
        shared.withLock { $0.metadata = metadata }
    }

    /// Tag reports with an environment name (e.g. `"production"`, `"staging"`).
    @objc public static func setEnvironment(_ environment: String?) {
        shared.withLock { $0.environment = environment }
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

    // MARK: - Internal

    private func configure(apiKey: String, endpoint: URL?) {
        withLock {
            $0.configuration = Configuration(
                apiKey: apiKey,
                endpoint: endpoint ?? Configuration.defaultEndpoint
            )
        }
        #if canImport(UIKit)
        installShakeDetectorIfNeeded()
        ShakeDetector.shared.isEnabled = isShakeToReportEnabledValue
        #endif
    }

    /// Assemble a report from the current context and send it.
    func submit(
        message: String,
        imageData: Data?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let snapshot = withLock { state -> (Configuration?, FeedbackUser?, [String: String], String?) in
            (state.configuration, state.user, state.metadata, state.environment)
        }
        guard let configuration = snapshot.0 else {
            completion(.failure(CatchDevError.notStarted))
            return
        }
        var report = FeedbackReport(message: message)
        report.email = snapshot.1?.email
        report.userId = snapshot.1?.id
        report.metadata = snapshot.2
        report.environment = snapshot.3
        report.imageData = imageData
        report.applyDeviceContext()
        client.send(report, configuration: configuration, completion: completion)
    }

    private var isShakeToReportEnabledValue: Bool {
        withLock { $0.shakeEnabled }
    }

    @discardableResult
    private func withLock<T>(_ body: (CatchDev) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    // MARK: - UI (iOS only)

    #if canImport(UIKit)
    /// Manually open the feedback reporter (captures the current screen).
    @objc public static func presentReporter() {
        shared.presentReporter(screenshot: ScreenshotCapturer.capture())
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
            self?.presentReporter(screenshot: ScreenshotCapturer.capture())
        }
    }

    func presentReporter(screenshot: UIImage?) {
        DispatchQueue.main.async {
            guard self.withLock({ $0.configuration != nil }) else { return }
            guard let presenter = UIApplication.cdv_topViewController() else { return }
            if presenter is ReporterContainer
                || presenter.presentedViewController is ReporterContainer {
                return
            }
            let reporter = ReporterViewController(screenshot: screenshot)
            let container = ReporterContainer(rootViewController: reporter)
            container.modalPresentationStyle = .fullScreen
            presenter.present(container, animated: true)
        }
    }
    #endif
}
