import XCTest
import UIKit
@_spi(CatchDevTesting) import CatchDev

final class ViewControllerTrackerTests: XCTestCase {
    func testForwardsContentControllersAndFiltersContainers() {
        let tracker = ViewControllerTracker.shared
        let saved = tracker.onAppear
        defer { tracker.onAppear = saved }

        var captured: [UIViewController] = []
        tracker.onAppear = { captured.append($0) }

        // An app-defined controller (this test bundle, not UIKitCore) is host content.
        let content = HostContentController()
        tracker.handleAppear(content)
        tracker.handleAppear(UINavigationController())
        tracker.handleAppear(UITabBarController())
        tracker.handleAppear(UISplitViewController())
        tracker.handleAppear(UIPageViewController())
        // A bare UIKit controller is framework-internal and must be filtered.
        tracker.handleAppear(UIViewController())

        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured.first === content)
    }
}

private final class HostContentController: UIViewController {}
