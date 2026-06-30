import UIKit
@_spi(CatchDevTesting) import CatchDev

/// UIKit entry point for the example app. Starts the SDK, builds the tab/navigation UI,
/// and — under `-CatchDevUITest` — wires the in-process mock server to a debug probe so
/// the UI tests can assert what the SDK actually sent.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var debugProbe: DebugProbeView?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let isUITest = ProcessInfo.processInfo.arguments.contains("-CatchDevUITest")

        // Start the SDK BEFORE building the window: this installs the view-controller
        // tracker swizzle, so the very first screen's appearance is recorded.
        if isUITest {
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

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = RootTabBarController()
        window.makeKeyAndVisible()
        self.window = window

        if isUITest {
            let probe = DebugProbeView()
            probe.attach(to: window)
            probe.setMockPort(MockFeedbackServer.shared.port)
            debugProbe = probe
            MockFeedbackServer.shared.onRequestReceived = { [weak probe] received in
                DispatchQueue.main.async {
                    probe?.update(received)
                }
            }
            MockFeedbackServer.shared.onAnyRequest = { [weak probe] method, path in
                DispatchQueue.main.async {
                    probe?.noteRequest(method: method, path: path)
                }
            }
        }
        return true
    }
}
