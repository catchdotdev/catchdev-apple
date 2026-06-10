# CatchDev — Apple SDK

Shake-to-report **user feedback** for iOS apps, by [catch.dev](https://catch.dev).

Your users shake their device → a sheet appears with a screenshot of the current
screen → they annotate it and add a note → it lands in your catch.dev dashboard
under **App → Feedback**.

- 📸 Automatic screenshot capture on shake
- ✏️ On-image annotation (PencilKit)
- 💬 A short message + optional user identity
- 🪶 ~Zero config — one line to start
- 🧩 Swift + Objective-C

> **Scope:** v1 is **user feedback only** — it is *not* a crash reporter. iOS / iPadOS 15+.

## Installation

### Swift Package Manager (recommended)

In Xcode: **File → Add Package Dependencies…** and enter:

```
https://github.com/catchdotdev/catchdev-apple.git
```

Or in `Package.swift`:

```swift
.package(url: "https://github.com/catchdotdev/catchdev-apple.git", from: "0.1.0")
```

### CocoaPods

```ruby
pod 'CatchDev'
```

## Quick start

Get your **App access key** from the catch.dev dashboard (**App → API Keys**), then
start the SDK once at launch.

**SwiftUI**

```swift
import SwiftUI
import CatchDev

@main
struct MyApp: App {
    init() {
        CatchDev.start(apiKey: "ck_your_key")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

**UIKit**

```swift
import CatchDev

func application(_ application: UIApplication,
                didFinishLaunchingWithOptions launchOptions: ...) -> Bool {
    CatchDev.start(apiKey: "ck_your_key")
    return true
}
```

**Objective-C**

```objc
@import CatchDev;
[CDVCatchDev startWithApiKey:@"ck_your_key"];
```

That's it — shake the device (Simulator: **⌃⌘Z**) to open the reporter.

## API

```swift
CatchDev.start(apiKey:)                 // start against api.catch.dev
CatchDev.start(apiKey:endpoint:)        // custom / self-hosted endpoint
CatchDev.setUser(id:email:)             // attach an end-user identity
CatchDev.setMetadata(["screen": "Cart"])// arbitrary custom key/values
CatchDev.setEnvironment("production")   // tag reports with an environment
CatchDev.isShakeToReportEnabled = false // disable the shake trigger
CatchDev.presentReporter()              // open the reporter manually (e.g. a button)
CatchDev.isDebugLoggingEnabled = true   // print SDK diagnostics while integrating

// Confirm delivery / instrument analytics (Swift only). Called on the main thread.
CatchDev.onFeedbackSent = { result in
    switch result {
    case .success(let id): print("sent:", id)
    case .failure(let error): print("failed:", error)
    }
}
```

All of the above are available to Objective-C via the `CDVCatchDev` class.

## How it works

On `start`, the SDK installs a lightweight shake detector (by swizzling
`UIWindow.motionEnded`). On shake it captures the key window to a `UIImage`,
presents the reporter, and on **Send** flattens the annotation onto the image and
uploads everything as `multipart/form-data` to:

```
POST <endpoint>/api/v1/feedback/report
Header: x-access-token: <apiKey>
Fields: message, screenshot (file), email?, userId?, appVersion, appBuild,
        osVersion, device, platform=ios, environment?, locale, sdk, sdkVersion,
        meta (JSON), time
```

## Privacy

Screenshots are taken on-device and can contain whatever is on screen (including
personal data). They are uploaded only when the user taps **Send**. Use
`isShakeToReportEnabled = false` and `presentReporter()` if you want to gate when
the reporter can appear.

## Platform support

| Platform | Status |
|---|---|
| iOS / iPadOS 15+ | ✅ |
| macOS / tvOS / visionOS | ⏳ planned (manual `presentReporter()` only) |

## Development

```bash
swift build      # builds the Foundation-only core for the host (macOS)
swift test       # runs the core unit tests (requires Xcode for XCTest)
```

The UI layer (`Sources/CatchDev/UI/`) is gated behind `#if canImport(UIKit)` and is
exercised on the iOS Simulator in CI. See `Examples/` for a runnable sample app.

## License

MIT — see [LICENSE](LICENSE).
