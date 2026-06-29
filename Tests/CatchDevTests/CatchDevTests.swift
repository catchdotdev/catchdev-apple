import XCTest
@testable import CatchDev

/// Exercises the `CatchDev` orchestration layer on an isolated instance (via the
/// `init(client:)` test seam), so the shared singleton and cross-test state are avoided.
final class CatchDevTests: XCTestCase {
    private let endpoint = URL(string: "https://api.catch.dev")!

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// A CatchDev backed by a mock URLSession that records the request body and replies 200.
    private func makeSDK(
        capture: ((String) -> Void)? = nil,
        responseId: String = "fb_test"
    ) -> CatchDev {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        MockURLProtocol.handler = { request in
            capture?(Self.bodyString(from: request))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{\"id\":\"\(responseId)\"}".utf8))
        }
        return CatchDev(client: FeedbackClient(session: session, boundaryProvider: { "B" }))
    }

    /// Extract the request body whether URLSession kept it inline or moved it to a stream.
    private static func bodyString(from request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Tests

    func testSubmitBeforeStartFailsNotStartedAndNotifiesHandler() {
        let sdk = CatchDev(client: FeedbackClient())
        let handlerCalled = expectation(description: "handler")
        let completionCalled = expectation(description: "completion")
        sdk.onFeedbackSent = { result in
            if case .failure(CatchDevError.notStarted) = result {} else {
                XCTFail("expected notStarted, got \(result)")
            }
            handlerCalled.fulfill()
        }
        sdk.submit(message: "hi", imageData: nil) { result in
            if case .failure(CatchDevError.notStarted) = result {} else {
                XCTFail("expected notStarted, got \(result)")
            }
            completionCalled.fulfill()
        }
        wait(for: [handlerCalled, completionCalled], timeout: 5)
    }

    func testSubmitSuccessNotifiesHandlerOnMainThreadWithServerId() {
        let sdk = makeSDK(responseId: "fb_42")
        sdk.configure(apiKey: "ck", endpoint: endpoint)
        let handlerCalled = expectation(description: "handler")
        sdk.onFeedbackSent = { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .success(let id) = result {
                XCTAssertEqual(id, "fb_42")
            } else {
                XCTFail("expected success, got \(result)")
            }
            handlerCalled.fulfill()
        }
        sdk.submit(message: "hi", imageData: nil) { _ in }
        wait(for: [handlerCalled], timeout: 5)
    }

    func testSubmitPopulatesReportFromStateAndArguments() {
        var body = ""
        let captured = expectation(description: "captured")
        let sdk = makeSDK(capture: { body = $0; captured.fulfill() })
        sdk.configure(apiKey: "ck", endpoint: endpoint)
        sdk.setUser(id: "u1", email: "a@b.com")
        sdk.setMetadata(["k": "v"])
        sdk.setEnvironment("staging")
        sdk.recordBreadcrumb(screen: "Home")

        sdk.submit(message: "broken", imageData: nil, screenName: "Checkout") { _ in }
        wait(for: [captured], timeout: 5)

        XCTAssertTrue(body.contains("name=\"message\"\r\n\r\nbroken"))
        XCTAssertTrue(body.contains("name=\"email\"\r\n\r\na@b.com"))
        XCTAssertTrue(body.contains("name=\"userId\"\r\n\r\nu1"))
        XCTAssertTrue(body.contains("name=\"environment\"\r\n\r\nstaging"))
        XCTAssertTrue(body.contains("name=\"screenName\"\r\n\r\nCheckout"))
        XCTAssertTrue(body.contains("name=\"meta\""))
        XCTAssertTrue(body.contains("\"k\":\"v\""))
        XCTAssertTrue(body.contains("catchdev.breadcrumbs"))
        XCTAssertTrue(body.contains("\"screen\":\"Home\""))
    }

    func testRecordBreadcrumbBoundsToCapacityInSubmittedReport() {
        var body = ""
        let captured = expectation(description: "captured")
        let sdk = makeSDK(capture: { body = $0; captured.fulfill() })
        sdk.configure(apiKey: "ck", endpoint: endpoint)

        // Record more than the capacity; the oldest must be evicted.
        let total = CatchDev.breadcrumbCapacity + 5
        for i in 0..<total { sdk.recordBreadcrumb(screen: "S\(i)") }

        sdk.submit(message: "hi", imageData: nil) { _ in }
        wait(for: [captured], timeout: 5)

        // Oldest five (S0...S4) dropped; newest kept.
        XCTAssertFalse(body.contains("\"screen\":\"S0\""))
        XCTAssertFalse(body.contains("\"screen\":\"S4\""))
        XCTAssertTrue(body.contains("\"screen\":\"S5\""))
        XCTAssertTrue(body.contains("\"screen\":\"S\(total - 1)\""))
    }

    func testDisablingAutomaticBreadcrumbsStopsRecording() {
        var body = ""
        let captured = expectation(description: "captured")
        let sdk = makeSDK(capture: { body = $0; captured.fulfill() })
        sdk.configure(apiKey: "ck", endpoint: endpoint)
        sdk.isAutomaticBreadcrumbsEnabled = false
        sdk.recordBreadcrumb(screen: "Home")
        sdk.recordBreadcrumb(screen: "Detail")

        sdk.submit(message: "hi", imageData: nil) { _ in }
        wait(for: [captured], timeout: 5)

        XCTAssertFalse(body.contains("catchdev.breadcrumbs"))
        XCTAssertFalse(body.contains("\"screen\":\"Home\""))
    }
}
