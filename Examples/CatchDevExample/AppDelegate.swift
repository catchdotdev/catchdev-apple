import UIKit
@_spi(CatchDevTesting) import CatchDev

/// UIKit entry point for the example app. Starts the SDK; the window and the tab/navigation
/// UI are built by ``SceneDelegate`` (the app uses the scene life cycle). Under
/// `-CatchDevUITest` it also starts the in-process mock server the UI tests send to.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Start the SDK BEFORE any scene connects: this installs the view-controller
        // tracker swizzle, so the very first screen's appearance is recorded.
        if ProcessInfo.processInfo.arguments.contains("-CatchDevUITest") {
            // Hermetic tests: wipe any outbox left by a previous test launch so a stale
            // queued report can't replay into this run.
            CatchDev.resetPersistenceForTesting()
            let port = MockFeedbackServer.shared.start()
            // Use 127.0.0.1 (not "localhost"): the latter is dual-stack, and happy-eyeballs
            // can open a second loopback connection that closes empty — which would report a
            // bogus (empty) request and clobber the debug probe mid-test.
            CatchDev.start(apiKey: "ck_uitest", endpoint: URL(string: "http://127.0.0.1:\(port)"))
        } else {
            // Paste your App access key from the catch.dev dashboard (App → API Keys).
            // For a local backend: endpoint: URL(string: "http://localhost:4000").
            CatchDev.start(apiKey: "ck_replace_me")
        }
        CatchDev.setEnvironment("development")
        return true
    }
}
