import XCTest
@testable import CatchDev

/// Guards the memory cap on attachment reads. Without it the reporter pulls an
/// arbitrarily large user-picked file (or an unbounded screen recording) fully
/// into memory on the main thread, which OOM-kills the *host* app — a crash the
/// host's own reporting blames on the host, not on us.
final class AttachmentLimitsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catchdev-limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ byteCount: Int, name: String = "blob.bin") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: byteCount).write(to: url)
        return url
    }

    func testReadsSmallFileWhole() throws {
        let url = try write(1024)
        let data = AttachmentLimits.readCapped(url: url, limit: 4096)
        XCTAssertEqual(data?.count, 1024)
    }

    func testStopsAtTheLimitRatherThanReadingTheWholeFile() throws {
        // The caller passes cap + 1 and treats "reached the limit" as too large,
        // so the read must stop there instead of allocating the entire file.
        let url = try write(500_000)
        let data = AttachmentLimits.readCapped(url: url, limit: 1000)
        XCTAssertEqual(data?.count, 1000, "read must be bounded by limit, not by file size")
    }

    func testCapPlusOneDetectsAFileExactlyOverTheCap() throws {
        let cap = 2048
        let url = try write(cap + 1)
        let data = AttachmentLimits.readCapped(url: url, limit: cap + 1)
        XCTAssertEqual(data?.count, cap + 1)
        XCTAssertGreaterThan(data!.count, cap, "over-cap file must be detectable")
    }

    func testFileExactlyAtTheCapIsAccepted() throws {
        let cap = 2048
        let url = try write(cap)
        let data = AttachmentLimits.readCapped(url: url, limit: cap + 1)
        XCTAssertEqual(data?.count, cap)
        XCTAssertLessThanOrEqual(data!.count, cap, "a file exactly at the cap is allowed")
    }

    func testMissingFileReturnsNilRatherThanCrashing() {
        let missing = dir.appendingPathComponent("nope.bin")
        XCTAssertNil(AttachmentLimits.readCapped(url: missing, limit: 1024))
    }

    func testDeclaredSizeAllowsRejectionWithoutReading() throws {
        let url = try write(4096)
        XCTAssertEqual(AttachmentLimits.declaredSize(of: url), 4096)
    }

    func testDeclaredSizeIsNilForAMissingFile() {
        XCTAssertNil(AttachmentLimits.declaredSize(of: dir.appendingPathComponent("nope.bin")))
    }

    /// The caps are the client-side mirror of what the backend enforces when it
    /// mints an upload URL; drifting from them means uploads that only fail
    /// after the bytes are already in memory and on disk.
    func testCapsMatchTheBackendContract() {
        XCTAssertEqual(AttachmentLimits.maxImageBytes, 8 * 1024 * 1024)
        XCTAssertEqual(AttachmentLimits.maxFileBytes, 25 * 1024 * 1024)
        XCTAssertEqual(AttachmentLimits.maxRecordingBytes, 50 * 1024 * 1024)
    }

    func testHumanReadableIsUsedInUserFacingCopy() {
        XCTAssertEqual(AttachmentLimits.humanReadable(AttachmentLimits.maxFileBytes), "25 MB")
        XCTAssertEqual(AttachmentLimits.humanReadable(AttachmentLimits.maxRecordingBytes), "50 MB")
    }
}
