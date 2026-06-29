// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CatchDev",
    // v1 is iOS/iPadOS only (shake-to-report + screenshot + PencilKit annotation).
    // The Foundation-only core still compiles for the host (macOS) so `swift build`
    // and `swift test` work from the command line; all UIKit code is gated behind
    // `#if canImport(UIKit)`. The macOS floor is set only so that host build has the
    // APIs the core uses (e.g. NWPathMonitor, 10.14+) available.
    platforms: [
        .iOS(.v15),
        .macOS(.v11)
    ],
    products: [
        .library(name: "CatchDev", targets: ["CatchDev"])
    ],
    targets: [
        .target(
            name: "CatchDev",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "CatchDevTests", dependencies: ["CatchDev"])
    ]
)
