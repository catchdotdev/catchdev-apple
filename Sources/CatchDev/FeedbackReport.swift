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
    /// Name of the screen the reporter was opened on. Sent as the dedicated
    /// `screenName` multipart field.
    var screenName: String?
    var locale: String?

    var sdk: String = SDKInfo.name
    var sdkVersion: String = SDKInfo.version
    var time: String = Timestamp.now()

    /// Client-generated idempotency key, stable across retries of the same report —
    /// the server dedupes on it, so the transport-error retry can't duplicate a row.
    var reportId: String = UUID().uuidString.lowercased()

    /// Arbitrary custom key/values (``CatchDev/setMetadata(_:)``). Sent as a single
    /// JSON-encoded `meta` form field.
    var metadata: [String: String] = [:]

    /// Automatically collected screen-visit trail. Serialized into `meta` under the
    /// reserved key `catchdev.breadcrumbs` (the `catchdev.` namespace is reserved).
    var breadcrumbs: [Breadcrumb] = []

    /// Optional annotated screenshot, already encoded (JPEG by default).
    var imageData: Data?
    var imageContentType = "image/jpeg"

    init(message: String) {
        self.message = message
    }

    /// Reserved `meta` key the breadcrumb trail is serialized under.
    static let breadcrumbsMetaKey = "catchdev.breadcrumbs"

    /// JSON string for the `meta` field: the user's custom metadata merged with the
    /// reserved breadcrumb trail. `nil` when there is neither. The user's own keys are
    /// never mutated; the SDK only sets the reserved `catchdev.breadcrumbs` key. When
    /// there are no breadcrumbs the output is byte-identical to the metadata-only JSON.
    var metaJSONString: String? {
        var object = metadata as [String: Any]
        if !breadcrumbs.isEmpty {
            object[Self.breadcrumbsMetaKey] = breadcrumbs.map {
                ["screen": $0.screen, "time": $0.time]
            }
        }
        guard !object.isEmpty else { return nil }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
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
}
