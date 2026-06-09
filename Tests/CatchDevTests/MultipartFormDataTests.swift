import XCTest
@testable import CatchDev

final class MultipartFormDataTests: XCTestCase {
    func testFieldEncoding() {
        var form = MultipartFormData(boundary: "B")
        form.addField(name: "message", value: "hello")
        let body = String(decoding: form.encoded(), as: UTF8.self)
        XCTAssertEqual(
            body,
            "--B\r\nContent-Disposition: form-data; name=\"message\"\r\n\r\nhello\r\n--B--\r\n"
        )
    }

    func testMultipleFieldsKeepOrder() {
        var form = MultipartFormData(boundary: "B")
        form.addField(name: "a", value: "1")
        form.addField(name: "b", value: "2")
        let body = String(decoding: form.encoded(), as: UTF8.self)
        XCTAssertLessThan(
            body.range(of: "name=\"a\"")!.lowerBound,
            body.range(of: "name=\"b\"")!.lowerBound
        )
    }

    func testFileEncoding() {
        var form = MultipartFormData(boundary: "B")
        form.addFile(
            name: "screenshot",
            filename: "s.jpg",
            contentType: "image/jpeg",
            data: Data([0x01, 0x02, 0x03])
        )
        let body = String(decoding: form.encoded(), as: UTF8.self)
        XCTAssertTrue(
            body.contains(
                "Content-Disposition: form-data; name=\"screenshot\"; filename=\"s.jpg\""
            )
        )
        XCTAssertTrue(body.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(body.hasSuffix("--B--\r\n"))
    }

    func testContentTypeHeader() {
        let form = MultipartFormData(boundary: "XYZ")
        XCTAssertEqual(form.contentTypeHeader, "multipart/form-data; boundary=XYZ")
    }
}
