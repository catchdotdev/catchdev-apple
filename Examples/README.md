# CatchDev Example app

A minimal SwiftUI app that demonstrates shake-to-report.

There is no checked-in `.xcodeproj` (it's noisy to maintain). To run it:

1. In Xcode: **File → New → Project → iOS → App** (SwiftUI). Name it `CatchDevExample`.
2. Delete the generated `App.swift` / `ContentView.swift` and drag in the two files
   from `Examples/CatchDevExample/` instead.
3. Add the package: **File → Add Package Dependencies… → Add Local…** and pick the
   repository root (this folder's parent). Add the `CatchDev` library to the app target.
4. Set your access key in `CatchDevExampleApp.swift`. To test against a **local**
   backend, pass `endpoint: URL(string: "http://localhost:4000")` and allow
   cleartext HTTP (add `NSAppTransportSecurity → NSAllowsLocalNetworking = YES`
   to Info.plist).
5. Run on a simulator and trigger a shake with **⌃⌘Z**, or tap *Send feedback manually*.

The report appears in the catch.dev dashboard under **App → Feedback**.
