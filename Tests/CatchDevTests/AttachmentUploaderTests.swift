import XCTest
@testable import CatchDev

/// Exercises the two-hop attachment upload (mint a presigned URL → PUT the bytes) against
/// a stubbed network, so the handshake is verified deterministically without a simulator.
final class AttachmentUploaderTests: XCTestCase {
    private let config = Configuration(apiKey: "k", endpoint: URL(string: "https://api.catch.dev")!)

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testUploadMintsURLThenPutsAndReturnsAttachment() {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        let lock = NSLock()
        var seenPaths: [String] = []
        var mintBody = Data()

        MockURLProtocol.handler = { request in
            lock.lock(); defer { lock.unlock() }
            let path = request.url?.path ?? ""
            seenPaths.append(path)
            if path.hasSuffix("/feedback/upload-url") {
                mintBody = Self.bodyData(request)
                let json = #"{"uploadUrl":"https://r2.example.com/put/abc","key":"feedback/uploads/abc.png","expiresIn":600}"#
                return (Self.ok(request), Data(json.utf8))
            }
            return (Self.ok(request), Data()) // the PUT
        }

        let uploader = AttachmentUploader(session: session)
        let done = expectation(description: "done")
        uploader.upload(
            data: Data([1, 2, 3, 4]), kind: .screenshot, contentType: "image/png",
            filename: "a.png", annotated: true, configuration: config
        ) { result in
            switch result {
            case .success(let attachment):
                XCTAssertEqual(attachment.key, "feedback/uploads/abc.png")
                XCTAssertEqual(attachment.kind, .screenshot)
                XCTAssertEqual(attachment.size, 4)
                XCTAssertEqual(attachment.contentType, "image/png")
                XCTAssertEqual(attachment.annotated, true)
            case .failure(let error):
                XCTFail("unexpected failure: \(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertTrue(seenPaths.contains { $0.hasSuffix("/feedback/upload-url") }, "should mint a URL")
        XCTAssertTrue(seenPaths.contains { $0.contains("/put/abc") }, "should PUT to the minted URL")
        let mint = String(decoding: mintBody, as: UTF8.self)
        XCTAssertTrue(mint.contains("\"kind\":\"screenshot\"") || mint.contains("\"kind\": \"screenshot\""))
        XCTAssertTrue(mint.contains("\"size\":4") || mint.contains("\"size\": 4"))
    }

    func testUploadFailsWhenMintRejected() {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let uploader = AttachmentUploader(session: session)
        let done = expectation(description: "done")
        uploader.upload(
            data: Data([1]), kind: .file, contentType: "application/pdf",
            filename: "x.pdf", annotated: false, configuration: config
        ) { result in
            if case .failure(CatchDevError.server(let status)) = result {
                XCTAssertEqual(status, 401)
            } else {
                XCTFail("expected a server error, got \(result)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testUploadFailsWhenMintResponseMalformed() {
        let session = URLSession(configuration: MockURLProtocol.sessionConfiguration())
        MockURLProtocol.handler = { request in
            (Self.ok(request), Data("{\"no\":\"url\"}".utf8))
        }
        let uploader = AttachmentUploader(session: session)
        let done = expectation(description: "done")
        uploader.upload(
            data: Data([1]), kind: .screenshot, contentType: "image/png",
            filename: nil, annotated: false, configuration: config
        ) { result in
            if case .failure = result {} else { XCTFail("expected failure for malformed mint, got \(result)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    // MARK: - Helpers

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    /// URLSession often converts `httpBody` to a stream by the time a `URLProtocol` sees it.
    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
