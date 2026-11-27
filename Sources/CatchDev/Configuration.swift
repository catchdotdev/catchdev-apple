import Foundation

/// Immutable SDK configuration created by ``CatchDev/start(apiKey:endpoint:)``.
public struct Configuration {
    /// The project access key (from **App → API Keys** in the catch.dev dashboard).
    public let apiKey: String

    /// Base URL of the catch.dev API. Feedback is POSTed to
    /// `<endpoint>/api/v1/feedback/report`.
    public let endpoint: URL

    /// Production catch.dev API host.
    public static let defaultEndpoint = URL(string: "https://api.catch.dev")!

    public init(apiKey: String, endpoint: URL = Configuration.defaultEndpoint) {
        self.apiKey = apiKey
        self.endpoint = endpoint
    }
}

/// Optional end-user identity attached to feedback reports.
struct FeedbackUser {
    let id: String?
    let email: String?
}

/// Errors surfaced by the SDK.
public enum CatchDevError: Error {
    /// `submit`/`presentReporter` was called before ``CatchDev/start(apiKey:)``.
    case notStarted
    /// The server rejected the report (non-2xx response).
    case server(status: Int)
    /// The network request failed.
    case transport(Error)
}

/// The report reached catch.dev, but some of its attachments never did. Their uploads kept
/// failing until the SDK's retry limits ran out, so it stopped retrying them.
///
/// ``CatchDev/onFeedbackSent`` receives this as the failure — the submission did not arrive
/// whole — even though the report itself is in the dashboard under ``reportId``.
public struct CatchDevAttachmentsNotDelivered: Error, LocalizedError {
    /// The id the server stored the report under. The report itself was delivered.
    public let reportId: String
    /// How many of the report's attachments the server does not have.
    public let missingCount: Int
    /// The last upload failure seen, if any. `nil` when the uploads themselves succeeded but
    /// the server could not find the bytes in storage.
    public let underlyingError: Error?

    public var errorDescription: String? {
        "The report was delivered, but \(missingCount) of its attachment"
            + (missingCount == 1 ? "" : "s") + " could not be uploaded."
    }
}
