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

> **Early access**: the SDK is in early access — the API may change before 1.0.
> Questions and issues: support@catch.dev.

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

// The areas offered by the reporter's "Area" picker. Defaults to
// CatchDev.defaultAreas (Login / Payments / Performance / Other). The picker is a
// scrolling wheel, so a long list is fine. Area stays optional — the wheel has a
// "None" row. Set an empty array to hide the Area field entirely.
CatchDev.areas = ["Checkout", "Search", "Profile", "Notifications", "Billing"]
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
        osVersion, device, platform=ios, environment?, screenName?, locale, sdk,
        sdkVersion, meta (JSON), time
```

## Screen name & breadcrumbs

On `start`, the SDK also installs a lightweight screen tracker (by swizzling
`UIViewController.viewDidAppear`). It records:

- **`screenName`** — the screen the reporter was opened on, resolved at present-time.
- **breadcrumbs** — a bounded trail (last 20) of recently visited screens, sent inside
  `meta` under the reserved key `catchdev.breadcrumbs` (the `catchdev.` namespace is
  reserved; your own `meta` keys are never touched).

A screen's name is resolved as: a `CatchDevScreenNaming` override → the view
controller's `title` → its class name. Provide an explicit, PII-free name for any screen
whose `title` is dynamic/user-specific (e.g. a contact name):

```swift
extension CheckoutViewController: CatchDevScreenNaming {
    var catchdevScreenName: String? { "Checkout" }
}
```

Notes:
- A subclass that overrides `viewDidAppear(_:)` **must call `super`** to be recorded.
- Container controllers (navigation/tab/split/page) and framework-internal controllers
  (the keyboard, system alerts) are filtered out automatically.
- Disable automatic breadcrumb collection with
  `CatchDev.isAutomaticBreadcrumbsEnabled = false`.

## Reliability & offline delivery

Submissions are durable. On **Send**, the report (and its screenshot) is written to an
on-disk outbox in Application Support *before* the upload is attempted, so it survives
being offline or the app being killed mid-send. The report carries a stable `reportId`
that the server dedupes on, so replaying a "sent-but-unacknowledged" report is safe.

The outbox is drained automatically when:
- the SDK starts (`start`),
- connectivity is restored (watched with `NWPathMonitor`), and
- the app returns to the foreground.

Delivered reports are removed; a report the server *rejects* (e.g. a bad key) is dropped
rather than retried forever; a report that can't be sent because the device is offline
stays queued. `onFeedbackSent` fires when a report is actually delivered. The outbox is
bounded, so a long offline period can't grow it without limit. (This is an in-process
outbox — it uploads while the app is running, not while suspended/terminated, which keeps
the SDK self-contained with no host AppDelegate wiring required.)

## Privacy

Screenshots are taken on-device and can contain whatever is on screen (including
personal data). They are uploaded only when the user taps **Send**. Use
`isShakeToReportEnabled = false` and `presentReporter()` if you want to gate when
the reporter can appear.

Screen names and the breadcrumb trail are derived from view-controller titles/class
names. If your screen titles can contain personal data, give those screens an explicit
name via `CatchDevScreenNaming`, or turn off automatic collection with
`isAutomaticBreadcrumbsEnabled = false`. The SDK declares this as product-interaction
data in its `PrivacyInfo.xcprivacy`.

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
