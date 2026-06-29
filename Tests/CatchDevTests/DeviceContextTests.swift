import XCTest
@testable import CatchDev

final class DeviceContextTests: XCTestCase {
    func testOSVersionLooksLikeAVersion() {
        let version = DeviceContext.osVersion
        XCTAssertFalse(version.isEmpty)
        XCTAssertTrue(version.contains("."))
    }

    func testDeviceModelNotEmpty() {
        XCTAssertFalse(DeviceContext.deviceModel.isEmpty)
    }

    func testPlatformIsNonEmptyAndLowercased() {
        XCTAssertFalse(DeviceContext.platform.isEmpty)
        XCTAssertEqual(DeviceContext.platform.lowercased(), DeviceContext.platform)
    }
}
