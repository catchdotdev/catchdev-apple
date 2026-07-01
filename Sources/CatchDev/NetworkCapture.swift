import Foundation

/// Bounded store of FAILED host network calls (non-2xx responses + transport errors) for
/// the reporter's "Failed network calls" diagnostic. **Host-fed and opt-in** (matches the
/// Android SDK): the host enables it (`CatchDev.isNetworkCaptureEnabled = true`) and reports
/// failures via `CatchDev.recordFailedRequest(...)` — e.g. from a `URLSession` delegate, an
/// async wrapper, or an Alamofire/AFNetworking event monitor.
///
/// The SDK deliberately does **not** swizzle or proxy the host's `URLSession`: transparently
/// re-issuing a request loses the originating session's cookies, auth, certificate pinning,
/// and (for `uploadTask`) the request body — which would silently break the host app's
/// networking. Records are REDACTED to method + `scheme://host/path` + status; the query
/// string, headers, and body are never stored. Bounded ring buffer keeps memory constant.
final class CatchDevNetworkCapture {
    static let shared = CatchDevNetworkCapture()

    private let lock = NSLock()
    private var records: [FailedRequest] = []
    private let capacity = 20

    private init() {}

    func record(method: String, url: String, status: Int) {
        let entry = FailedRequest(method: method.uppercased(), url: Self.redact(url), status: status)
        lock.lock()
        records.append(entry)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
        lock.unlock()
    }

    /// A snapshot of recently failed requests, oldest first.
    func snapshot() -> [FailedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func clear() {
        lock.lock()
        records.removeAll()
        lock.unlock()
    }

    /// Keep `scheme://host/path` only — never the query string, headers, or body.
    private static func redact(_ url: String) -> String {
        guard let components = URLComponents(string: url) else {
            return String(url.prefix(while: { $0 != "?" }))
        }
        var out = ""
        if let scheme = components.scheme { out += "\(scheme)://" }
        if let host = components.host { out += host }
        out += components.path
        return out.isEmpty ? url : out
    }
}
