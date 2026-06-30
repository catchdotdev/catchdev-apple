import Foundation

/// Identifies this SDK to the catch.dev backend (sent as the `sdk` / `sdkVersion`
/// fields of every feedback report).
public enum SDKInfo {
    public static let name = "catchdev-apple"
    public static let version = "0.2.0"
}
