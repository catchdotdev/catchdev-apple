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
        XCTAssertTrue(body.contains("name=\"screenshot\"; filename=\"screenshot.jpg\""))
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
            case .success(let id): XCTAssertEqual(id, "fb_123")
            case .failure(let error): XCTFail("unexpected failure: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
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
}

/// In-memory URLProtocol used to stub network responses in tests.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

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
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
