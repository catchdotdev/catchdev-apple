import XCTest
import UIKit
@_spi(CatchDevTesting) import CatchDev

final class ViewControllerTrackerTests: XCTestCase {
    func testForwardsHostContentAndFiltersContainersAndSystemControllers() {
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

    func testViewDidAppearSwizzleRecordsAndStillRunsTheOriginalImplementation() {
        ViewControllerTracker.shared.install() // idempotent; the host app already installed it
        let saved = ViewControllerTracker.shared.onAppear
        defer { ViewControllerTracker.shared.onAppear = saved }

        var captured: [UIViewController] = []
        ViewControllerTracker.shared.onAppear = { captured.append($0) }

        let vc = OverridingController()
        vc.viewDidAppear(false)

        XCTAssertTrue(vc.didRunOwnViewDidAppear, "the subclass override (and super) must still run")
        XCTAssertTrue(captured.contains { $0 === vc }, "the appearance must be recorded by the swizzle")
    }
}

private final class HostContentController: UIViewController {}

private final class OverridingController: UIViewController {
    var didRunOwnViewDidAppear = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didRunOwnViewDidAppear = true
    }
}
