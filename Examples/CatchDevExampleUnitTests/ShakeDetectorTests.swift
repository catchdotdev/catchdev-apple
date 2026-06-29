import XCTest
@_spi(CatchDevTesting) import CatchDev

final class ShakeDetectorTests: XCTestCase {
    func testDisabledDoesNotFireEnabledDoes() {
        let detector = ShakeDetector.shared
        // The app under test has already wired this singleton — save and restore it.
        let savedEnabled = detector.isEnabled
        let savedHandler = detector.onShake
        defer {
            detector.isEnabled = savedEnabled
            detector.onShake = savedHandler
        }

        var fired = false
        detector.onShake = { fired = true }

        detector.isEnabled = false
        detector.handleShake()
        XCTAssertFalse(fired, "Shake must be ignored when disabled")

        detector.isEnabled = true
        detector.handleShake()
        XCTAssertTrue(fired, "Shake must fire when enabled")
    }
}
