import XCTest
import UIKit
@_spi(CatchDevTesting) import CatchDev

/// UIKit-only logic that `swift test` (macOS, Foundation-only) can't reach.
final class ScreenNameResolutionTests: XCTestCase {
    func testUsesTitleWhenPresent() {
        let vc = UIViewController()
        vc.title = "Cart"
        XCTAssertEqual(ScreenName.resolve(vc), "Cart")
    }

    func testFallsBackToUnqualifiedClassName() {
        XCTAssertEqual(ScreenName.resolve(BareController()), "BareController")
    }

    func testEmptyTitleFallsBackToClassName() {
        let vc = BareController()
        vc.title = ""
        XCTAssertEqual(ScreenName.resolve(vc), "BareController")
    }

    func testOverrideWinsOverTitle() {
        let vc = NamedController()
        vc.title = "TitleShouldLose"
        XCTAssertEqual(ScreenName.resolve(vc), "Custom")
    }

    func testEmptyOverrideFallsThroughToTitle() {
        let vc = EmptyNamedController()
        vc.title = "FromTitle"
        XCTAssertEqual(ScreenName.resolve(vc), "FromTitle")
    }

    func testWhitespaceOnlyTitleFallsBackToClassName() {
        let vc = BareController()
        vc.title = "   \n\t "
        XCTAssertEqual(ScreenName.resolve(vc), "BareController")
    }

    func testWhitespaceOnlyOverrideFallsThroughToTitle() {
        let vc = WhitespaceNamedController()
        vc.title = "FromTitle"
        XCTAssertEqual(ScreenName.resolve(vc), "FromTitle")
    }
}

private final class BareController: UIViewController {}

private final class NamedController: UIViewController, CatchDevScreenNaming {
    var catchdevScreenName: String? { "Custom" }
}

private final class EmptyNamedController: UIViewController, CatchDevScreenNaming {
    var catchdevScreenName: String? { "" }
}

private final class WhitespaceNamedController: UIViewController, CatchDevScreenNaming {
    var catchdevScreenName: String? { "   " }
}
