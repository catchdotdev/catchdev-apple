import Foundation

/// Which kind of report the user is filing. Drives the reporter's accent + which
/// fields show (severity is bug-only). Sent as the `type` field.
public enum ReportType: String, Codable {
    case feedback
    case bug
}

/// How badly a bug affects the user (bug reports only, optional). Sent as `severity`.
public enum Severity: String, Codable {
    case blocks
    case annoying
    case minor
}

/// The kind of an uploaded attachment. Sent inside each `attachments` entry.
public enum AttachmentKind: String, Codable {
    case screenshot
    case recording
    case file
}

/// One attachment the SDK uploaded directly to R2 via a backend-minted presigned PUT
/// URL. Only the lightweight reference travels in the report (`attachments` JSON field);
/// the bytes never pass through the catch.dev API.
struct Attachment: Codable, Equatable {
    /// Relative R2 object key returned by `/feedback/upload-url`
    /// (e.g. `feedback/uploads/<uuid>.png`).
    let key: String
    let kind: AttachmentKind
    let contentType: String
    let size: Int
    var filename: String?
    /// True for a screenshot the user drew on in the annotate screen.
    var annotated: Bool?
}

/// One failed network call captured by ``CatchDevNetworkCapture`` for the
/// "Failed network calls" diagnostic. Redacted to method + host/path + status — no
/// query string, headers, or body is ever recorded.
struct FailedRequest: Codable, Equatable {
    let method: String
    let url: String
    let status: Int
}

/// Identifies one row in the reporter's "Included automatically" diagnostics list, so a
/// user can exclude individual items before sending. `session` is always included
/// (locked in the UI). Raw values are stable identifiers shared with the UI + tests.
public enum DiagnosticID: String, CaseIterable {
    case screen
    case version
    case device
    case user
    case breadcrumbs
    case network
    case session
}

/// The payload for one user feedback submission. Mirrors the multipart fields of
/// `POST /api/v1/feedback/report`. Foundation-only and value-typed for testability.
/// `Codable` so a pending report can be persisted to the offline outbox — the bulky
/// `imageData` is deliberately excluded (the outbox stores the screenshot as a side file).
struct FeedbackReport: Codable {
    var message: String

    /// Report classification from the reporter's segmented tabs.
    var type: ReportType = .feedback
    /// How bad the bug is (bug reports only).
    var severity: Severity?
    /// Optional area/category the user picked (e.g. "Login", "Payments").
    var area: String?

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
    /// IANA timezone identifier, e.g. `America/New_York`.
    var timezone: String?

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

    /// Per-launch session id, serialized into `meta` under `catchdev.sessionId`.
    var sessionId: String?

    /// Recently failed network calls captured by the SDK, serialized into `meta` under
    /// `catchdev.failedRequests`.
    var failedRequests: [FailedRequest] = []

    /// References to attachments already uploaded to R2 (screenshots, recordings, files).
    /// Sent as the `attachments` JSON form field — the bytes go straight to R2, not here.
    var attachments: [Attachment] = []

    /// Optional annotated screenshot, already encoded (JPEG by default). Legacy single
    /// screenshot path (web SDK / older versions); the new reporter uploads screenshots
    /// as `attachments` instead.
    var imageData: Data?
    var imageContentType = "image/jpeg"

    init(message: String) {
        self.message = message
    }

    /// Persisted fields. `imageData` is intentionally omitted — the outbox writes the
    /// screenshot to a separate file rather than base64-bloating the JSON.
    private enum CodingKeys: String, CodingKey {
        case message, type, severity, area
        case email, userId, appVersion, appBuild, osVersion, device, platform
        case environment, screenName, locale, timezone, sdk, sdkVersion, time, reportId
        case metadata, breadcrumbs, sessionId, failedRequests, attachments
        case imageContentType
    }

    /// Reserved `meta` key the breadcrumb trail is serialized under.
    static let breadcrumbsMetaKey = "catchdev.breadcrumbs"
    /// Reserved `meta` key for the per-launch session id.
    static let sessionIdMetaKey = "catchdev.sessionId"
    /// Reserved `meta` key for the captured failed-network-call list.
    static let failedRequestsMetaKey = "catchdev.failedRequests"

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
        if let sessionId, !sessionId.isEmpty {
            object[Self.sessionIdMetaKey] = sessionId
        }
        if !failedRequests.isEmpty {
            object[Self.failedRequestsMetaKey] = failedRequests.map {
                ["method": $0.method, "url": $0.url, "status": $0.status] as [String: Any]
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

    /// JSON string for the `attachments` form field, or `nil` when there are none. Each
    /// entry is a lightweight reference to bytes already uploaded to R2.
    var attachmentsJSONString: String? {
        guard !attachments.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(attachments) else { return nil }
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
        timezone = DeviceContext.timezone
    }
}
