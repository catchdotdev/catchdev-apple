import Foundation

/// Installs an in-process stub for the feedback endpoint so XCUITests can exercise
/// the full submit flow (tap Send → success → reporter dismisses) without a backend.
///
/// `URLProtocol.registerClass` intercepts requests made through `URLSession.shared`,
/// which is what `CatchDev`'s `FeedbackClient` uses by default.
enum UITestStub {
    static func install() {
        URLProtocol.registerClass(StubURLProtocol.self)
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("/api/v1/feedback/report") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"uitest-123"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
