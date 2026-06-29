import XCTest
import UIKit
@_spi(CatchDevTesting) import CatchDev

final class TopViewControllerTests: XCTestCase {
    func testUnwrapsNavigationVisibleViewController() {
        let leaf = UIViewController()
        let nav = UINavigationController(rootViewController: leaf)
        XCTAssertTrue(UIApplication.cdv_topViewController(from: nav) === leaf)
    }

    func testUnwrapsTabSelectedViewController() {
        let first = UIViewController()
        let second = UIViewController()
        let tab = UITabBarController()
        tab.viewControllers = [first, second]
        tab.selectedViewController = second
        XCTAssertTrue(UIApplication.cdv_topViewController(from: tab) === second)
    }

    // The example app's shape: a tab bar whose selected tab is a navigation stack — must
    // descend all the way to the visible content controller, not stop at the nav.
    func testUnwrapsTabContainingNavigation() {
        let leaf = UIViewController()
        let nav = UINavigationController(rootViewController: leaf)
        let tab = UITabBarController()
        tab.viewControllers = [nav]
        tab.selectedViewController = nav
        XCTAssertTrue(UIApplication.cdv_topViewController(from: tab) === leaf)
    }

    func testPlainViewControllerIsReturnedAsIs() {
        let vc = UIViewController()
        XCTAssertTrue(UIApplication.cdv_topViewController(from: vc) === vc)
    }

    func testNilRootReturnsNil() {
        XCTAssertNil(UIApplication.cdv_topViewController(from: nil))
    }
}
