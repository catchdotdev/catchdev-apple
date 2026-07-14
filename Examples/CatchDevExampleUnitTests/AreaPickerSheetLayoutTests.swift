import XCTest
@_spi(CatchDevTesting) import CatchDev

/// A3. The Area sheet's content column is bar (52) + separator (1) + wheel (216) = 269pt of
/// REQUIRED, fixed child heights. It used to be pinned to the sheet's top AND bottom as well,
/// which over-determines it: at any sheet height other than the exact custom detent the layout
/// engine must break one of those required constraints, and which one it sacrifices is not ours
/// to choose. That is not hypothetical — it is every iOS 15 presentation (where the detent falls
/// back to `.medium()`) and iPad.
///
/// So: host the sheet at a height that is NOT its content height and assert the layout still
/// resolves the way it must — the wheel at its natural size, the content anchored to the bottom,
/// nothing stretched to fill.
final class AreaPickerSheetLayoutTests: XCTestCase {
    private let contentHeight: CGFloat = 52 + 1 + 216

    /// Lay the sheet out at a given height and hand back its content column + wheel.
    private func layout(sheetHeight: CGFloat) throws -> (view: UIView, column: UIStackView, wheel: UIPickerView) {
        let sheet = CatchDevAreaPickerTesting.make(
            areas: ["Login", "Payments", "Performance"], selected: nil, bottomInset: 34
        )
        sheet.loadViewIfNeeded()
        sheet.view.frame = CGRect(x: 0, y: 0, width: 390, height: sheetHeight)
        sheet.view.setNeedsLayout()
        sheet.view.layoutIfNeeded()

        let column = try XCTUnwrap(sheet.view.subviews.compactMap { $0 as? UIStackView }.first)
        let wheel = try XCTUnwrap(column.arrangedSubviews.compactMap { $0 as? UIPickerView }.first)
        return (sheet.view, column, wheel)
    }

    func testContentIsNotStretchedWhenTheSheetIsTallerThanItsContent() throws {
        // ~ what `.medium()` resolves to on an iPhone — far taller than the 269pt of content.
        let (view, column, wheel) = try layout(sheetHeight: 420)

        XCTAssertEqual(
            column.frame.height, contentHeight, accuracy: 0.5,
            "the content column must keep its own height, not be stretched to fill the sheet"
        )
        XCTAssertEqual(
            wheel.frame.height, 216, accuracy: 0.5,
            "the wheel must keep its natural height — a stretched or squashed wheel means a "
                + "required constraint had to be broken to make the layout fit"
        )
        XCTAssertEqual(
            column.frame.maxY, view.safeAreaLayoutGuide.layoutFrame.maxY, accuracy: 0.5,
            "the content stays anchored to the bottom (above the home indicator)"
        )
        XCTAssertGreaterThanOrEqual(column.frame.minY, 0, "and inside the sheet")
        XCTAssertFalse(view.hasAmbiguousLayout)
    }

    /// The exact custom-detent height (iOS 16+) must still lay out flush — the fix must not have
    /// traded one broken height for another.
    func testContentFillsTheSheetExactlyAtItsContentHeight() throws {
        let (view, column, wheel) = try layout(sheetHeight: contentHeight)

        XCTAssertEqual(column.frame.minY, 0, accuracy: 0.5, "flush to the top at the exact detent")
        XCTAssertEqual(column.frame.maxY, view.safeAreaLayoutGuide.layoutFrame.maxY, accuracy: 0.5)
        XCTAssertEqual(column.frame.height, contentHeight, accuracy: 0.5)
        XCTAssertEqual(wheel.frame.height, 216, accuracy: 0.5)
        XCTAssertFalse(view.hasAmbiguousLayout)
    }
}
