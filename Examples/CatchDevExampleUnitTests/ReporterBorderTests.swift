import XCTest
@_spi(CatchDevTesting) import CatchDev

/// The reporter's borders are the one colour that does not follow a light↔dark switch on its own
/// (`CALayer.borderColor` is a `CGColor` — a *snapshot* of a dynamic `UIColor`), so the reporter
/// re-resolves them when the appearance changes.
///
/// The bug this pins: the refresh used to resolve each border against **the view's own**
/// `traitCollection`. When a view controller is told the appearance changed, UIKit has updated the
/// VC's traits but has NOT yet propagated them into the view subtree — every view still reports the
/// appearance the user just LEFT — so the refresh dutifully re-wrote the stale colour and the fix
/// was a no-op in both directions: flipping to dark left #e4e4e7 (the light border) on a #09090b
/// page, and flipping back left #27272a on white. The refresh must resolve against the traits the
/// caller hands down (the view controller's, already updated).
final class ReporterBorderTests: XCTestCase {
    /// A real window so the subtree's `traitCollection` genuinely carries `style` — the whole
    /// point is what happens when those traits are STALE relative to the appearance change.
    private func tree(style: UIUserInterfaceStyle) throws -> (box: UIView, field: UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.overrideUserInterfaceStyle = style
        let box = UIView()
        let field = UIView()
        box.addSubview(field)
        window.addSubview(box)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)

        XCTAssertEqual(box.traitCollection.userInterfaceStyle, style, "precondition: the subtree is on \(style)")
        XCTAssertEqual(field.traitCollection.userInterfaceStyle, style)
        return (box, field)
    }

    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows = []
        super.tearDown()
    }

    private func rgb(_ cgColor: CGColor?) throws -> [CGFloat] {
        try XCTUnwrap(cgColor?.components).map { ($0 * 1000).rounded() / 1000 }
    }

    /// Light → dark. The views still report `.light` (UIKit has not propagated yet); the refresh
    /// is told the appearance is now `.dark` and every border must take the DARK colour.
    func testRefreshResolvesAgainstThePassedTraitsNotTheSubtreesStaleOnes() throws {
        let (box, field) = try tree(style: .light)
        CatchDevBorderTesting.setBorder(on: box)
        CatchDevBorderTesting.setBorder(on: field)
        XCTAssertEqual(
            try rgb(CatchDevBorderTesting.borderColor(of: box)),
            try rgb(CatchDevBorderTesting.expectedBorderColor(style: .light)),
            "sanity: it starts out light"
        )

        CatchDevBorderTesting.refreshBorders(in: box, style: .dark)

        XCTAssertEqual(
            try rgb(CatchDevBorderTesting.borderColor(of: box)),
            try rgb(CatchDevBorderTesting.expectedBorderColor(style: .dark)),
            "the border must take the NEW appearance, not the stale one the view still reports"
        )
        XCTAssertEqual(
            try rgb(CatchDevBorderTesting.borderColor(of: field)),
            try rgb(CatchDevBorderTesting.expectedBorderColor(style: .dark)),
            "…all the way down the subtree"
        )
        XCTAssertEqual(
            box.traitCollection.userInterfaceStyle, .light,
            "the subtree really was still light while we refreshed — that is the bug's setup"
        )
    }

    /// Dark → light, the same failure in reverse: it used to leave #27272a on a white page.
    func testRefreshBackToLightAlsoTakesTheNewAppearance() throws {
        let (box, _) = try tree(style: .dark)
        CatchDevBorderTesting.setBorder(on: box)
        XCTAssertEqual(
            try rgb(CatchDevBorderTesting.borderColor(of: box)),
            try rgb(CatchDevBorderTesting.expectedBorderColor(style: .dark)),
            "sanity: it starts out dark"
        )

        CatchDevBorderTesting.refreshBorders(in: box, style: .light)

        XCTAssertEqual(
            try rgb(CatchDevBorderTesting.borderColor(of: box)),
            try rgb(CatchDevBorderTesting.expectedBorderColor(style: .light))
        )
    }
}
