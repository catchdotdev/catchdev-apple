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
