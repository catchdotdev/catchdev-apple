import XCTest
@testable import CatchDev

/// Exercises the `CatchDev` orchestration layer on an isolated instance (via the
/// `init(client:)` test seam), so the shared singleton and cross-test state are avoided.
final class CatchDevTests: XCTestCase {
    private let endpoint = URL(string: "https://api.catch.dev")!
    private var tempDirs: [URL] = []

    override func tearDown() {
        MockURLProtocol.handler = nil
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// A throwaway outbox in a unique temp directory (so tests never touch the real
    /// Application Support outbox and never leak state between tests).
    private func tempOutbox() -> FeedbackOutbox {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catchdev-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(dir)
        return FeedbackOutbox(directory: dir)
    }

    /// A CatchDev backed by a mock URLSession that records the request body and replies 200,
    /// plus a throwaway outbox.
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
        return CatchDev(
            client: FeedbackClient(session: session, boundaryProvider: { "B" }),
            outbox: tempOutbox()
        )
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

    func testSubmitOmitsUserIdWhenOnlyEmailIsSet() {
        var body = ""
        let captured = expectation(description: "captured")
        let sdk = makeSDK(capture: { body = $0; captured.fulfill() })
        sdk.configure(apiKey: "ck", endpoint: endpoint)
        sdk.setUser(id: nil, email: "only@email.com")

        sdk.submit(message: "hi", imageData: nil) { _ in }
        wait(for: [captured], timeout: 5)

        XCTAssertTrue(body.contains("name=\"email\"\r\n\r\nonly@email.com"))
        XCTAssertFalse(body.contains("name=\"userId\""))
    }

    func testSuccessfulSubmitRemovesReportFromOutbox() {
        let outbox = tempOutbox()
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"id\":\"fb_1\"}".utf8))
        }
        let sdk = CatchDev(client: FeedbackClient(session: session, boundaryProvider: { "B" }), outbox: outbox)
        sdk.configure(apiKey: "ck", endpoint: endpoint)

        let done = expectation(description: "done")
        sdk.submit(message: "hi", imageData: nil) { result in
            if case .success = result {} else { XCTFail("expected success, got \(result)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outbox.count, 0, "a delivered report must be removed from the outbox")
    }

    func testServerRejectionRemovesReportFromOutboxAndReportsFailure() {
        let outbox = tempOutbox()
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let sdk = CatchDev(client: FeedbackClient(session: session, boundaryProvider: { "B" }), outbox: outbox)
        sdk.configure(apiKey: "ck", endpoint: endpoint)

        let done = expectation(description: "done")
        sdk.submit(message: "hi", imageData: nil) { result in
            if case .failure(CatchDevError.server(let status)) = result { XCTAssertEqual(status, 401) }
            else { XCTFail("expected server failure, got \(result)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outbox.count, 0, "a server-rejected report must be dropped, not retried forever")
    }

    func testOfflineSubmitQueuesThenDeliversAndClearsOnFlush() {
        let outbox = tempOutbox()
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let sdk = CatchDev(client: FeedbackClient(session: session, boundaryProvider: { "B" }), outbox: outbox)
        sdk.configure(apiKey: "ck", endpoint: endpoint)

        // Offline: the submit is accepted (queued) rather than failing.
        let accepted = expectation(description: "accepted")
        sdk.submit(message: "offline", imageData: nil) { result in
            if case .success = result {} else { XCTFail("offline submit should be accepted/queued, got \(result)") }
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 5)
        XCTAssertEqual(outbox.count, 1, "an offline report must stay queued")

        // Reconnect: the server now accepts, and a flush delivers + clears it.
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"id\":\"fb_flushed\"}".utf8))
        }
        let delivered = expectation(description: "delivered")
        sdk.onFeedbackSent = { result in
            if case .success(let id) = result { XCTAssertEqual(id, "fb_flushed") }
            else { XCTFail("expected delivery success, got \(result)") }
            delivered.fulfill()
        }
        sdk.flushPending()
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(outbox.count, 0, "a flushed report must be removed from the outbox")
    }

    func testConcurrentBreadcrumbAndStateMutationsStayConsistentUnderLock() {
        var body = ""
        let captured = expectation(description: "captured")
        let sdk = makeSDK(capture: { body = $0; captured.fulfill() })
        sdk.configure(apiKey: "ck", endpoint: endpoint)

        // Hammer the shared state from many threads at once; the single lock must keep the
        // ring buffer consistent (no crash, no torn writes) and bounded to capacity.
        let group = DispatchGroup()
        for i in 0..<1000 {
            group.enter()
            DispatchQueue.global().async {
                sdk.recordBreadcrumb(screen: "S\(i)")
                sdk.setMetadata(["k": "\(i)"])
                sdk.setUser(id: "u\(i)", email: nil)
                sdk.setEnvironment("env\(i)")
                group.leave()
            }
        }
        let finished = expectation(description: "threads finished")
        group.notify(queue: .global()) { finished.fulfill() }
        wait(for: [finished], timeout: 30)

        sdk.submit(message: "hi", imageData: nil) { _ in }
        wait(for: [captured], timeout: 5)

        let breadcrumbCount = body.components(separatedBy: "\"screen\":").count - 1
        XCTAssertEqual(breadcrumbCount, CatchDev.breadcrumbCapacity,
                       "trail must be bounded to capacity even under concurrent writes")
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
