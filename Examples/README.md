# CatchDev Example app + UI tests

A minimal SwiftUI app that demonstrates shake-to-report, plus an XCUITest target that
exercises the reporter end-to-end.

There is no checked-in `.xcodeproj` (it's noisy to maintain). To set it up:

## 1. Create the app

1. In Xcode: **File → New → Project → iOS → App** (SwiftUI). Name it `CatchDevExample`.
2. Replace the generated `App.swift` / `ContentView.swift` with the files in
   `Examples/CatchDevExample/` and add `UITestStub.swift`.
3. Add the package: **File → Add Package Dependencies… → Add Local…**, pick the repo
   root, and add the `CatchDev` library to the app target.
4. Set your access key in `CatchDevExampleApp.swift`. To test against a **local**
   backend, pass `endpoint: URL(string: "http://localhost:4000")` and allow cleartext
   HTTP (`NSAppTransportSecurity → NSAllowsLocalNetworking = YES` in Info.plist).
5. Run and trigger a shake with **⌃⌘Z**, or tap *Send feedback manually*.

## 2. Add the UI test target

1. **File → New → Target → UI Testing Bundle**, name it `CatchDevExampleUITests`,
   Target to be Tested = `CatchDevExample`.
2. Replace the generated test file with
   `Examples/CatchDevExampleUITests/CatchDevExampleUITests.swift`.
3. Run with **⌘U** (or `xcodebuild test -scheme CatchDevExample -destination
   'platform=iOS Simulator,name=iPhone 16'`).

### How the e2e tests work

XCUITest is **black-box** (it only sees the screen), which drives three choices:

- **Triggering the reporter:** there is no public API to simulate a device shake in
  XCUITest, so the test taps the app's *Send feedback manually* button (which calls
  `CatchDev.presentReporter()`). Tag that button with
  `.accessibilityIdentifier("example.sendFeedback")` (already done in `ContentView`).
- **Finding controls:** the reporter's elements expose stable identifiers via
  `CatchDevReporterAccessibility` (`catchdev.reporter.message`, `.send`, `.cancel`,
  `.undo`, `.clear`, `.screenshot`). The tests look those up.
- **Stubbing the network:** the app installs `UITestStub` (a `URLProtocol` returning a
  200 for `/api/v1/feedback/report`) when launched with `-CatchDevUITest`, so the
  Send → success → dismiss path runs without a backend. The test passes that launch
  argument.

The provided tests cover: submit a message → reporter dismisses; cancel → reporter
dismisses; empty message → reporter stays open.

> For a true full-stack e2e (SDK → real backend → dashboard), point the example app at
> a running backend and assert the row via the dashboard's Playwright suite instead —
> XCUITest only covers the on-device half.
