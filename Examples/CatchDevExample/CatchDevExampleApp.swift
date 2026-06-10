import SwiftUI
import CatchDev

@main
struct CatchDevExampleApp: App {
    init() {
        // Under UI tests, stub the network so "Send" succeeds without a real backend.
        // (XCUITest is black-box, so the stub must be installed by the app itself,
        // gated on a launch argument the test passes.)
        if ProcessInfo.processInfo.arguments.contains("-CatchDevUITest") {
            UITestStub.install()
        }

        // Paste your App access key from the catch.dev dashboard (App → API Keys).
        // For local backend testing, point at your machine:
        //   CatchDev.start(apiKey: "ck_...", endpoint: URL(string: "http://localhost:4000"))
        CatchDev.start(apiKey: "ck_replace_me")
        CatchDev.setEnvironment("development")
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
