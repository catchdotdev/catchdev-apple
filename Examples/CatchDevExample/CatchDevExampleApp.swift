import SwiftUI
import CatchDev

@main
struct CatchDevExampleApp: App {
    init() {
        if ProcessInfo.processInfo.arguments.contains("-CatchDevUITest") {
            // Point the SDK at an in-process server so Send succeeds without a backend.
            let port = MockFeedbackServer.shared.start()
            CatchDev.start(
                apiKey: "ck_uitest",
                endpoint: URL(string: "http://localhost:\(port)")
            )
        } else {
            // Paste your App access key from the catch.dev dashboard (App → API Keys).
            // For a local backend, pass `endpoint: URL(string: "http://localhost:4000")`.
            CatchDev.start(apiKey: "ck_replace_me")
        }
        CatchDev.setEnvironment("development")
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
