# CatchDev Example app + UI tests

A minimal SwiftUI app that demonstrates shake-to-report, plus an XCUITest target that
exercises the reporter end-to-end.

> Requires **full Xcode** (not just the Command Line Tools) and an iOS Simulator runtime.
> `swift build` works with the CLT, but running unit/UI tests needs Xcode.

## Quick start (XcodeGen)

The `.xcodeproj` is generated, not checked in. With [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd Examples
make test-ui        # xcodegen generate + xcodebuild test on a simulator
```

`make test-ui` generates `CatchDevExample.xcodeproj` (wired to the local `CatchDev`
package) and runs the UI tests on an auto-detected iPhone simulator (override with
`make test-ui DESTINATION='platform=iOS Simulator,name=iPhone 17'`). `make unit` runs
the library's unit tests from the package root.

> Requires `xcode-select` to point at Xcode (`sudo xcode-select -s
> /Applications/Xcode.app/Contents/Developer`), or prefix commands with
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

To just run the app: `make generate`, then open `CatchDevExample.xcodeproj`, set your
access key in `CatchDevExampleApp.swift`, and Run (⌘R). Trigger a shake with **⌃⌘Z**,
or tap *Send feedback manually*.

## Setting it up by hand (without XcodeGen)

1. **File → New → Project → iOS → App** (SwiftUI), name `CatchDevExample`.
2. Replace the generated files with those in `Examples/CatchDevExample/` (incl.
   `MockFeedbackServer.swift`).
3. **File → Add Package Dependencies… → Add Local…**, pick the repo root, add `CatchDev`.
4. **File → New → Target → UI Testing Bundle**, name `CatchDevExampleUITests`, Target to
   be Tested = `CatchDevExample`; replace its file with the one in
   `Examples/CatchDevExampleUITests/`.
5. Add `NSAppTransportSecurity → NSAllowsLocalNetworking = YES` to the app's Info.plist.

## How the e2e tests work

XCUITest is **black-box** (it only sees the screen), which drives three choices:

- **Triggering the reporter:** there is no public API to simulate a device shake in
  XCUITest, so the test taps the app's *Send feedback manually* button (which calls
  `CatchDev.presentReporter()`), tagged `example.sendFeedback`.
- **Finding controls:** the reporter exposes stable identifiers via
  `CatchDevReporterAccessibility` (`catchdev.reporter.message`, `.send`, `.cancel`,
  `.undo`, `.clear`, `.screenshot`).
- **Succeeding without a backend:** under `-CatchDevUITest` the app starts an in-process
  loopback HTTP server (`MockFeedbackServer`) and points `CatchDev` at it, so the
  Send → success → dismiss path runs deterministically. (A real loopback server is used
  rather than a `URLProtocol` stub because `URLSession.shared` — which the SDK uses —
  ignores globally registered `URLProtocol` subclasses.)

The provided tests cover: submit → reporter dismisses; cancel → dismisses; empty
message → reporter stays open.

> For a true full-stack e2e (SDK → real backend → dashboard), point the example app at a
> running backend instead and assert the row with the dashboard's Playwright suite —
> XCUITest only covers the on-device half.
