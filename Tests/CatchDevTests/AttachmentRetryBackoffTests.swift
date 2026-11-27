import XCTest
@testable import CatchDev

/// The wait between attachment retries, shared verbatim with the Android SDK
/// (`OutboxDelivery.retryDelayMs`): min(60 s × 2^(attempts − 1), 6 h) after a counted attempt.
final class AttachmentRetryBackoffTests: XCTestCase {
    func testTheStandardWaitDoublesFromAMinuteUpToSixHours() {
        let backoff = CatchDev.AttachmentRetryBackoff.standard
        XCTAssertEqual(
            (1...11).map { backoff.delay(afterAttempts: $0) },
            [60, 120, 240, 480, 960, 1920, 3840, 7680, 15360, 21600, 21600]
        )
    }

    func testNoCountedAttemptMeansNoWait() {
        XCTAssertEqual(CatchDev.AttachmentRetryBackoff.standard.delay(afterAttempts: 0), 0)
    }

    func testAHugeAttemptCountStaysAtTheCapWithoutOverflowing() {
        XCTAssertEqual(CatchDev.AttachmentRetryBackoff.standard.delay(afterAttempts: Int.max), 6 * 60 * 60)
    }
}
