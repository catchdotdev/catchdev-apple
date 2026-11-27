import UIKit

/// Builds the example app's window. Apps built with the iOS 27 SDK must adopt the scene life
/// cycle — the iOS 27 runtime refuses to launch one that doesn't ("UIScene life cycle is
/// required for apps built with this SDK") — so the window lives here, not in the app
/// delegate. The scene is declared in `UIApplicationSceneManifest` (see `project.yml`).
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var debugProbe: DebugProbeView?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // The SDK was already started in `application(_:didFinishLaunchingWithOptions:)`,
        // which runs before any scene connects, so the view-controller tracker sees the very
        // first screen appear.
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootTabBarController()
        window.makeKeyAndVisible()
        self.window = window

        if ProcessInfo.processInfo.arguments.contains("-CatchDevUITest") {
            attachDebugProbe(to: window)
        }
    }

    /// Wires the in-process mock server to a debug probe so the UI tests can assert what
    /// the SDK actually sent.
    private func attachDebugProbe(to window: UIWindow) {
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
}
