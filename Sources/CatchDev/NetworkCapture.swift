import Foundation
import ObjectiveC.runtime

/// Captures FAILED host network calls (non-2xx responses and transport errors) for the
/// reporter's "Failed network calls" diagnostic. **Opt-in** (off by default) because it
/// swizzles Foundation's session configuration globally — a host enables it deliberately
/// via `CatchDev.isNetworkCaptureEnabled = true`.
///
/// Mechanism: register a `URLProtocol` (covers `URLSession.shared`) and prepend it to
/// `URLSessionConfiguration.default`/`.ephemeral` so sessions built from those base
/// configs after install are observed. Traffic on a host's pre-built custom session is
/// not seen — a documented best-effort limitation. The SDK's own requests are excluded
/// via the `X-CatchDev-Internal` header. Records are REDACTED to method +
/// `scheme://host/path` + status; query strings, headers and bodies are never stored.
/// Bounded ring buffer keeps memory constant.
final class CatchDevNetworkCapture {
    static let shared = CatchDevNetworkCapture()

    private let lock = NSLock()
    private var records: [FailedRequest] = []
    private var installed = false
    private let capacity = 20

    private init() {}

    /// Idempotently install the interceptor. Safe to call more than once.
    func install() {
        lock.lock()
        let already = installed
        installed = true
        lock.unlock()
        guard !already else { return }
        CatchDevURLProtocol.onFailure = { [weak self] record in self?.record(record) }
        URLProtocol.registerClass(CatchDevURLProtocol.self)
        URLSessionConfiguration.cdv_installCaptureSwizzle()
    }

    private func record(_ record: FailedRequest) {
        lock.lock()
        records.append(record)
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
}

/// The interceptor. It transparently re-issues each request on a private session (so the
/// host sees identical behavior) while observing the outcome to record failures.
final class CatchDevURLProtocol: URLProtocol, URLSessionDataDelegate {
    static var onFailure: ((FailedRequest) -> Void)?
    private static let handledKey = "dev.catch.networkcapture.handled"

    private var proxySession: URLSession?
    private var proxyTask: URLSessionTask?
    private var lastStatus = 0

    override class func canInit(with request: URLRequest) -> Bool {
        // Don't re-handle our own re-issued request (prevents infinite recursion).
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        // Never capture the SDK's own traffic.
        if request.value(forHTTPHeaderField: catchDevInternalHeader) != nil { return false }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        // Re-issue on a session that explicitly excludes our protocol, so the proxied
        // request cannot recurse back through us.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = (config.protocolClasses ?? []).filter {
            ObjectIdentifier($0) != ObjectIdentifier(CatchDevURLProtocol.self)
        }
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        proxySession = session
        proxyTask = session.dataTask(with: mutable as URLRequest)
        proxyTask?.resume()
    }

    override func stopLoading() {
        proxyTask?.cancel()
        proxySession?.invalidateAndCancel()
        proxySession = nil
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse { lastStatus = http.statusCode }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            recordFailure(status: 0)
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            if !(200..<300).contains(lastStatus) { recordFailure(status: lastStatus) }
            client?.urlProtocolDidFinishLoading(self)
        }
        proxySession?.finishTasksAndInvalidate()
        proxySession = nil
    }

    private func recordFailure(status: Int) {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? "GET"
        var redacted = ""
        if let scheme = url.scheme { redacted += "\(scheme)://" }
        redacted += url.host ?? ""
        redacted += url.path
        Self.onFailure?(FailedRequest(method: method, url: redacted, status: status))
    }
}

// MARK: - URLSessionConfiguration swizzle

private var cdvSwizzleInstalled = false

extension URLSessionConfiguration {
    static func cdv_installCaptureSwizzle() {
        guard !cdvSwizzleInstalled else { return }
        cdvSwizzleInstalled = true
        cdv_wrapClassGetter(#selector(getter: URLSessionConfiguration.default))
        cdv_wrapClassGetter(#selector(getter: URLSessionConfiguration.ephemeral))
    }

    /// Replace a class getter with a wrapper that calls the captured original IMP and
    /// then injects our protocol — no self-reference, so dispatch stays unambiguous.
    private static func cdv_wrapClassGetter(_ selector: Selector) {
        guard let method = class_getClassMethod(URLSessionConfiguration.self, selector)
        else { return }
        typealias Getter = @convention(c) (AnyObject, Selector) -> URLSessionConfiguration
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (AnyObject) -> URLSessionConfiguration = { receiver in
            let config = original(receiver, selector)
            config.cdv_prependCaptureProtocol()
            return config
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private func cdv_prependCaptureProtocol() {
        var classes = protocolClasses ?? []
        let already = classes.contains {
            ObjectIdentifier($0) == ObjectIdentifier(CatchDevURLProtocol.self)
        }
        if !already {
            classes.insert(CatchDevURLProtocol.self, at: 0)
            protocolClasses = classes
        }
    }
}
