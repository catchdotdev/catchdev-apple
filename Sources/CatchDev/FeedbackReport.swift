import Foundation

/// The payload for one user feedback submission. Mirrors the multipart fields of
/// `POST /api/v1/feedback/report`. Foundation-only and value-typed for testability.
struct FeedbackReport {
    var message: String

    var email: String?
    var userId: String?

    var appVersion: String?
    var appBuild: String?
    var osVersion: String?
    var device: String?
    var platform: String?
    var environment: String?
    var locale: String?

    var sdk: String = SDKInfo.name
    var sdkVersion: String = SDKInfo.version
    var time: String = FeedbackReport.timestamp()

    /// Client-generated idempotency key, stable across retries of the same report —
    /// the server dedupes on it, so the transport-error retry can't duplicate a row.
    var reportId: String = UUID().uuidString.lowercased()

    /// Arbitrary custom key/values (``CatchDev/setMetadata(_:)``). Sent as a single
    /// JSON-encoded `meta` form field.
    var metadata: [String: String] = [:]

    /// Optional annotated screenshot, already encoded (JPEG by default).
    var imageData: Data?
    var imageContentType = "image/jpeg"

    init(message: String) {
        self.message = message
    }

    /// JSON string for the `meta` field, or `nil` when there is no custom metadata.
    var metadataJSONString: String? {
        guard !metadata.isEmpty else { return nil }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: metadata,
                options: [.sortedKeys]
            )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Fill in the device/app context fields.
    mutating func applyDeviceContext() {
        appVersion = DeviceContext.appVersion
        appBuild = DeviceContext.appBuild
        osVersion = DeviceContext.osVersion
        device = DeviceContext.deviceModel
        platform = DeviceContext.platform
        locale = DeviceContext.locale
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
