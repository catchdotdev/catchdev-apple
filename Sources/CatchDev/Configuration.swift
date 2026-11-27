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

/// The report reached catch.dev, but some of its attachments never did. Either their uploads
/// kept failing until the SDK's retry limits ran out, or the SDK's outbox filled up while they
/// were still waiting to be retried (``underlyingError`` is then ``CatchDevOutboxFull``).
///
/// ``CatchDev/onFeedbackSent`` receives this as the failure — the submission did not arrive
/// whole — even though the report itself is in the dashboard.
public struct CatchDevAttachmentsNotDelivered: Error, LocalizedError {
    /// The report's id. When the SDK gave up retrying, it is the id the server stored the report
    /// under. When the outbox evicted the report, it is the SDK's own id for it (the
    /// ``CatchDevOutboxFull/reportId``), because the server's id isn't kept on disk.
    public let reportId: String
    /// How many of the report's attachments the server does not have.
    public let missingCount: Int
    /// Why the attachments are missing, if known: the last upload failure seen, or
    /// ``CatchDevOutboxFull`` when the outbox evicted them. `nil` when the uploads themselves
    /// succeeded but the server could not find the bytes in storage.
    public let underlyingError: Error?

    public var errorDescription: String? {
        "The report was delivered, but \(missingCount) of its attachment"
            + (missingCount == 1 ? "" : "s") + " could not be uploaded."
    }
}

/// The SDK dropped a report it had not delivered yet, because its on-disk outbox was full: the
/// outbox is bounded (by count and by total size), and making room for a newer report evicts
/// the oldest queued one.
///
/// ``CatchDev/onFeedbackSent`` receives this as the failure when the report never reached
/// catch.dev: its text and attachments are lost. When the report itself had already arrived
/// and only attachments were still queued, the failure is ``CatchDevAttachmentsNotDelivered``
/// with this as its `underlyingError`.
///
/// A standalone type rather than a ``CatchDevError`` case, so host apps that switch over
/// ``CatchDevError`` exhaustively keep compiling.
public struct CatchDevOutboxFull: Error, LocalizedError {
    /// The SDK's own id for the report: the `reportId` it sends so the server can dedupe.
    public let reportId: String

    public var errorDescription: String? {
        "The report was dropped before it could be sent, because the queue of unsent reports was full."
    }
}
