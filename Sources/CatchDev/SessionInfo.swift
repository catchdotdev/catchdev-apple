import Foundation

/// A per-launch ("session") identifier, minted once on first access and stable for the
/// life of the process. Attached to every report as the `catchdev.sessionId` diagnostic
/// so multiple reports from one app run can be correlated in the dashboard. Foundation-
/// only and side-effect-free, so it works on every platform and is trivial to test.
enum SessionInfo {
    /// Format `ses_<16 lowercase hex>`, e.g. `ses_2f9100ab4c7d1e88`.
    static let sessionId: String = {
        let hex = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(16)
        return "ses_\(hex)"
    }()
}
