import XCTest
@testable import CatchDev

final class FeedbackClientTests: XCTestCase {
    private let config = Configuration(
        apiKey: "secret-key",
        endpoint: URL(string: "https://api.catch.dev")!
    )

    func testMakeRequestTargetsReportEndpoint() {
        let client = FeedbackClient(boundaryProvider: { "B" })
        let request = client.makeRequest(report: FeedbackReport(message: "x"), configuration: config)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.catch.dev/api/v1/feedback/report"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-access-token"), "secret-key")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=B"
        )
    }

    func testMakeRequestEncodesFieldsAndFile() {
        let client = FeedbackClient(boundaryProvider: { "B" })
        var report = FeedbackReport(message: "Login is broken")
        report.email = "a@b.com"
        report.platform = "ios"
        report.metadata = ["screen": "Login"]
        report.imageData = Data([0xFF, 0xD8, 0xFF])
        let request = client.makeRequest(report: report, configuration: config)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"message\"\r\n\r\nLogin is broken"))
        XCTAssertTrue(body.contains("name=\"email\"\r\n\r\na@b.com"))
        XCTAssertTrue(body.contains("name=\"platform\"\r\n\r\nios"))
        XCTAssertTrue(body.contains("name=\"sdk\"\r\n\r\ncatchdev-apple"))
        XCTAssertTrue(body.contains("name=\"meta\"\r\n\r\n{\"screen\":\"Login\"}"))
        XCTAssertTrue(body.contains("name=\"reportId\"\r\n\r\n\(report.reportId)"))
        XCTAssertTrue(body.contains("name=\"screenshot\"; filename=\"screenshot.jpg\""))
    }

    func testMakeRequestEncodesScreenNameWhenSet() {
        let client = FeedbackClient(boundaryProvider: { "B" })
        var report = FeedbackReport(message: "x")
        report.screenName = "CartViewController"
        let request = client.makeRequest(report: report, configuration: config)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"screenName\"\r\n\r\nCartViewController"))
    }

    func testMakeRequestOmitsScreenNameWhenNil() {
        let client = FeedbackClient(boundaryProvider: { "B" })
        let request = client.makeRequest(report: FeedbackReport(message: "x"), configuration: config)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"screenName\""))
    }

    func testMakeRequestEncodesBreadcrumbsIntoMeta() {
        let client = FeedbackClient(boundaryProvider: { "B" })
        var report = FeedbackReport(message: "x")
        report.breadcrumbs = [Breadcrumb(screen: "Home", time: "t1")]
        let request = client.makeRequest(report: report, configuration: config)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"meta\""))
        XCTAssertTrue(body.contains("catchdev.breadcrumbs"))
        XCTAssertTrue(body.contains("\"screen\":\"Home\""))
    }

    func testMakeRequestEncodesTypeSeverityAreaAndAttachments() {
        let client = FeedbackClient(boundaryProvider: { "B" })
        var report = FeedbackReport(message: "Crash on launch")
        report.type = .bug
        report.severity = .blocks
        report.area = "Payments"
        report.attachments = [
            Attachment(
                key: "feedback/uploads/a.png", kind: .screenshot,
                contentType: "image/png", size: 12, filename: "a.png", annotated: true
            ),
            Attachment(
                key: "feedback/uploads/b.mp4", kind: .recording,
                contentType: "video/mp4", size: 99, filename: "b.mp4", annotated: nil
            ),
        ]
        let request = client.makeRequest(report: report, configuration: config)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"type\"\r\n\r\nbug"))
        XCTAssertTrue(body.contains("name=\"severity\"\r\n\r\nblocks"))
        XCTAssertTrue(body.contains("name=\"area\"\r\n\r\nPayments"))
        XCTAssertTrue(body.contains("name=\"attachments\""))
        // JSONEncoder escapes slashes, so assert on slash-free tokens.
        XCTAssertTrue(body.contains("a.png"))
        XCTAssertTrue(body.contains("\"kind\":\"screenshot\""))
        XCTAssertTrue(body.contains("b.mp4"))
        XCTAssertTrue(body.contains("\"kind\":\"recording\""))
    }

    func testMakeRequestAlwaysSendsTypeAndOmitsUnsetOptionalFields() {
        let client = FeedbackClient(boundaryProvider: { "B" })
        let request = client.makeRequest(report: FeedbackReport(message: "x"), configuration: config)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"type\"\r\n\r\nfeedback"))
        XCTAssertFalse(body.contains("name=\"severity\""))
        XCTAssertFalse(body.contains("name=\"area\""))
        XCTAssertFalse(body.contains("name=\"attachments\""))
    }

    func testMakeRequestEncodesSessionIdAndFailedRequestsIntoMeta() {
        let client = FeedbackClient(boundaryProvider: { "B" })
        var report = FeedbackReport(message: "x")
        report.sessionId = "ses_abc123"
        report.failedRequests = [FailedRequest(method: "POST", url: "https://api.x/charge", status: 500)]
        let request = client.makeRequest(report: report, configuration: config)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("catchdev.sessionId"))
        XCTAssertTrue(body.contains("ses_abc123"))
        XCTAssertTrue(body.contains("catchdev.failedRequests"))
        XCTAssertTrue(body.contains("\"status\":500"))
    }

    func testMakeRequestSetsInternalHeaderSoCaptureIgnoresOwnTraffic() {
        let client = FeedbackClient(boundaryProvider: { "B" })
        let request = client.makeRequest(report: FeedbackReport(message: "x"), configuration: config)
        XCTAssertEqual(request.value(forHTTPHeaderField: catchDevInternalHeader), "1")
    }

    func testReportIdIsStablePerReportAndUniqueAcrossReports() {
        let a = FeedbackReport(message: "a")
        let b = FeedbackReport(message: "b")
        XCTAssertFalse(a.reportId.isEmpty)
        XCTAssertNotEqual(a.reportId, b.reportId)

        // The same report encodes the same reportId every time — the retry replays it.
        let client = FeedbackClient(boundaryProvider: { "B" })
        let first = client.makeRequest(report: a, configuration: config)
        let second = client.makeRequest(report: a, configuration: config)
        XCTAssertEqual(first.httpBody, second.httpBody)
    }

    func testSendParsesReturnedId() {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{\"id\":\"fb_123\"}".utf8))
        }
        let client = FeedbackClient(session: session, boundaryProvider: { "B" })
        let expectation = expectation(description: "completion")
        client.send(FeedbackReport(message: "x"), configuration: config) { result in
            switch result {
            case .success(let ack):
                XCTAssertEqual(ack.id, "fb_123")
                XCTAssertNil(ack.storedAttachments, "no `attachments` field — nothing to report")
            case .failure(let error): XCTFail("unexpected failure: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    /// The backend answers `attachments: <stored count>` whenever the report listed any, so
    /// the SDK can tell "listed 1, stored 0" apart from a full delivery.
    func testSendParsesTheStoredAttachmentCount() {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"id\":\"fb_123\",\"attachments\":0}".utf8))
        }
        let client = FeedbackClient(session: session, boundaryProvider: { "B" })
        let done = expectation(description: "completion")
        client.send(FeedbackReport(message: "x"), configuration: config) { result in
            if case .success(let ack) = result {
                XCTAssertEqual(ack, ReportAck(id: "fb_123", storedAttachments: 0))
            } else {
                XCTFail("expected success, got \(result)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testSendSurfacesServerError() {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let client = FeedbackClient(session: session, boundaryProvider: { "B" })
        let expectation = expectation(description: "completion")
        client.send(FeedbackReport(message: "x"), configuration: config) { result in
            if case .failure(CatchDevError.server(let status)) = result {
                XCTAssertEqual(status, 401)
            } else {
                XCTFail("expected server error")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    // MARK: - Retry / transport edge cases

    private func ok(_ request: URLRequest, id: String = "fb_ok") -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data("{\"id\":\"\(id)\"}".utf8))
    }

    func testTransientTransportErrorIsRetriedOnceThenSucceeds() {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        let attempts = AttemptCounter()
        MockURLProtocol.handler = { request in
            if attempts.increment() == 1 { throw URLError(.networkConnectionLost) }
            return self.ok(request, id: "fb_retry")
        }
        let client = FeedbackClient(session: session, boundaryProvider: { "B" })
        let done = expectation(description: "done")
        client.send(FeedbackReport(message: "x"), configuration: config) { result in
            if case .success(let ack) = result { XCTAssertEqual(ack.id, "fb_retry") }
            else { XCTFail("expected success after retry, got \(result)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(attempts.count, 2, "should retry exactly once")
    }

    func testTwoTransportErrorsFailAfterExactlyTwoAttempts() {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        let attempts = AttemptCounter()
        MockURLProtocol.handler = { _ in
            _ = attempts.increment()
            throw URLError(.timedOut)
        }
        let client = FeedbackClient(session: session, boundaryProvider: { "B" })
        let done = expectation(description: "done")
        client.send(FeedbackReport(message: "x"), configuration: config) { result in
            if case .failure(CatchDevError.transport) = result {} else {
                XCTFail("expected transport failure, got \(result)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(attempts.count, 2, "one initial attempt + one retry, then give up")
    }

    func testServerErrorIsNotRetried() {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        let attempts = AttemptCounter()
        MockURLProtocol.handler = { request in
            _ = attempts.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = FeedbackClient(session: session, boundaryProvider: { "B" })
        let done = expectation(description: "done")
        client.send(FeedbackReport(message: "x"), configuration: config) { result in
            if case .failure(CatchDevError.server(let status)) = result { XCTAssertEqual(status, 500) }
            else { XCTFail("expected server error, got \(result)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(attempts.count, 1, "server errors must not be retried")
    }

    func testSuccessWithEmptyOrMalformedBodyYieldsEmptyId() {
        for body in ["", "not json", "{}", "{\"notid\":1}"] {
            let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
            MockURLProtocol.handler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(body.utf8))
            }
            let client = FeedbackClient(session: session, boundaryProvider: { "B" })
            let done = expectation(description: "done-\(body)")
            client.send(FeedbackReport(message: "x"), configuration: config) { result in
                if case .success(let ack) = result { XCTAssertEqual(ack.id, "", "body=\(body)") }
                else { XCTFail("expected success for 2xx, got \(result) for body=\(body)") }
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
    }

    func testRetryReplaysIdenticalBodyIncludingReportId() {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        let attempts = AttemptCounter()
        var bodies: [Data] = []
        let lock = NSLock()
        MockURLProtocol.handler = { request in
            lock.lock()
            if let body = request.httpBody { bodies.append(body) }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); let size = 4096
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size); defer { buf.deallocate() }
                while stream.hasBytesAvailable { let n = stream.read(buf, maxLength: size); if n <= 0 { break }; data.append(buf, count: n) }
                bodies.append(data)
            }
            lock.unlock()
            if attempts.increment() == 1 { throw URLError(.networkConnectionLost) }
            return self.ok(request)
        }
        let client = FeedbackClient(session: session, boundaryProvider: { "B" })
        let done = expectation(description: "done")
        client.send(FeedbackReport(message: "x"), configuration: config) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(bodies.count, 2, "should have sent two requests")
        XCTAssertEqual(bodies.first, bodies.last, "retry must replay the identical body (same reportId)")
    }
}

/// In-memory URLProtocol used to stub network responses in tests. The handler may `throw`
/// to simulate a transport-level failure (so the client's retry path is testable).
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Thread-safe attempt counter shared with a `MockURLProtocol` handler that runs on
/// URLSession's background queue.
final class AttemptCounter {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
