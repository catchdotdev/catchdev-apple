import XCTest
@testable import CatchDev

/// Wire-contract coverage for the redesigned reporter's new fields: report-model
/// serialization, Codable round-trip (for the offline outbox), and the
/// diagnostics-exclusion logic in `submit`. All deterministic and Foundation-only.
final class ReporterWireTests: XCTestCase {
    private let endpoint = URL(string: "https://api.catch.dev")!

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Report serialization

    func testMetaJSONIncludesSessionIdAndFailedRequests() {
        var report = FeedbackReport(message: "x")
        report.sessionId = "ses_1"
        report.failedRequests = [FailedRequest(method: "GET", url: "https://h/p", status: 404)]
        let json = report.metaJSONString
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("catchdev.sessionId"))
        XCTAssertTrue(json!.contains("ses_1"))
        XCTAssertTrue(json!.contains("catchdev.failedRequests"))
        XCTAssertTrue(json!.contains("\"status\":404"))
    }

    func testAttachmentsJSONStringEncodesEntries() {
        var report = FeedbackReport(message: "x")
        XCTAssertNil(report.attachmentsJSONString, "no attachments → nil")
        report.attachments = [
            Attachment(key: "feedback/uploads/a.png", kind: .screenshot,
                       contentType: "image/png", size: 5, filename: "a.png", annotated: true),
        ]
        let json = report.attachmentsJSONString
        XCTAssertNotNil(json)
        // JSONEncoder escapes forward slashes (valid JSON; the backend decodes it back),
        // so assert on slash-free tokens.
        XCTAssertTrue(json!.contains("a.png"))
        XCTAssertTrue(json!.contains("\"kind\":\"screenshot\""))
        XCTAssertTrue(json!.contains("\"annotated\":true"))
    }

    func testCodableRoundTripPreservesNewFields() throws {
        var report = FeedbackReport(message: "x")
        report.type = .bug
        report.severity = .annoying
        report.area = "Login"
        report.sessionId = "ses_2"
        report.failedRequests = [FailedRequest(method: "POST", url: "https://h/c", status: 500)]
        report.attachments = [
            Attachment(key: "feedback/uploads/b.mp4", kind: .recording,
                       contentType: "video/mp4", size: 9, filename: nil, annotated: nil),
        ]
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(FeedbackReport.self, from: data)
        XCTAssertEqual(decoded.type, .bug)
        XCTAssertEqual(decoded.severity, .annoying)
        XCTAssertEqual(decoded.area, "Login")
        XCTAssertEqual(decoded.sessionId, "ses_2")
        XCTAssertEqual(decoded.failedRequests.count, 1)
        XCTAssertEqual(decoded.attachments.first?.kind, .recording)
    }

    // MARK: - submit() diagnostics + exclusion

    func testSubmitAttachesSessionIdAndHonorsExclusions() {
        var body = ""
        let captured = expectation(description: "captured")
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        MockURLProtocol.handler = { request in
            body = Self.bodyString(request)
            captured.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"id\":\"x\"}".utf8))
        }
        let sdk = CatchDev(client: FeedbackClient(session: session, boundaryProvider: { "B" }))
        sdk.configure(apiKey: "k", endpoint: endpoint)
        sdk.setUser(id: "u1", email: "e@x.com")
        sdk.recordBreadcrumb(screen: "Home")

        sdk.submit(
            message: "x", imageData: nil, type: .bug, severity: .blocks, area: "Payments",
            screenName: "Cart", excludedDiagnostics: [.screen, .breadcrumbs, .user]
        ) { _ in }
        wait(for: [captured], timeout: 5)

        // Always included:
        XCTAssertTrue(body.contains("catchdev.sessionId"), "session id is locked-in")
        XCTAssertTrue(body.contains("name=\"type\"\r\n\r\nbug"))
        XCTAssertTrue(body.contains("name=\"severity\"\r\n\r\nblocks"))
        XCTAssertTrue(body.contains("name=\"area\"\r\n\r\nPayments"))
        // Excluded → omitted:
        XCTAssertFalse(body.contains("name=\"screenName\""), "excluded screen must be dropped")
        XCTAssertFalse(body.contains("name=\"userId\""), "excluded user id must be dropped")
        XCTAssertFalse(body.contains("catchdev.breadcrumbs"), "excluded breadcrumbs must be dropped")
    }

    func testSubmitContactEmailOverridesConfiguredUser() {
        var body = ""
        let captured = expectation(description: "captured")
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        MockURLProtocol.handler = { request in
            body = Self.bodyString(request)
            captured.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"id\":\"x\"}".utf8))
        }
        let sdk = CatchDev(client: FeedbackClient(session: session, boundaryProvider: { "B" }))
        sdk.configure(apiKey: "k", endpoint: endpoint)
        sdk.setUser(id: "u1", email: "configured@x.com")

        sdk.submit(message: "x", imageData: nil, contactEmail: "typed@x.com") { _ in }
        wait(for: [captured], timeout: 5)
        XCTAssertTrue(body.contains("name=\"email\"\r\n\r\ntyped@x.com"))
        XCTAssertFalse(body.contains("configured@x.com"))
    }

    // MARK: - Helper

    private static func bodyString(_ request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 8192
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
