#if canImport(UIKit)
import UIKit

/// Bottom-anchored **Area** picker: a `UIPickerView` wheel in a sheet, with a Cancel/Done bar.
///
/// A wheel always has a value under the indicator, so "no area" has to be an explicit row —
/// index 0 is a synthetic "None" (``noneTitle``) rather than a real area. Selection is
/// committed on **Done**; Cancel (and a swipe-down) leave the previous value untouched.
///
/// The areas come from ``CatchDev/areas``, so a host can supply as many as it likes; the wheel
/// scrolls. A popover menu was tried first and covered the very field it belonged to.
final class AreaPickerSheetViewController: UIViewController {
    /// The synthetic first row. Area is optional, and a wheel cannot express "nothing selected".
    static let noneTitle = "None"

    private let areas: [String]
    private let onPick: (String?) -> Void

    /// Home-indicator inset, passed in by the presenter. The sheet's own `safeAreaInsets` are
    /// still zero when the detent resolver runs, so reading them there sizes the sheet ~34pt
    /// short and clips the bottom rows off the wheel.
    private let bottomInset: CGFloat

    /// Row currently under the indicator. 0 == None, so a real area is `rows[selectedRow]`.
    private var selectedRow: Int
    private let picker = UIPickerView()

    /// Wheel rows: the synthetic None, then every configured area.
    private var rows: [String] { [Self.noneTitle] + areas }

    init(areas: [String], selected: String?, bottomInset: CGFloat, onPick: @escaping (String?) -> Void) {
        self.areas = areas
        self.onPick = onPick
        self.bottomInset = bottomInset
        // An area that is no longer in the list (the host changed `areas` after a pick) falls
        // back to None rather than silently selecting whatever now sits at that index.
        self.selectedRow = selected.flatMap { areas.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private let barHeight: CGFloat = 52
    private let wheelHeight: CGFloat = 216 // UIPickerView's natural height.

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReporterTheme.bg
        configureSheet()

        let cancel = barButton(title: "Cancel", id: CatchDevReporterAccessibility.areaCancel) { [weak self] in
            self?.dismiss(animated: true)
        }
        cancel.setTitleColor(ReporterTheme.textMuted, for: .normal)

        let done = barButton(title: "Done", id: CatchDevReporterAccessibility.areaDone) { [weak self] in
            guard let self else { return }
            // Row 0 is None -> clear the area.
            self.onPick(self.selectedRow == 0 ? nil : self.rows[self.selectedRow])
            self.dismiss(animated: true)
        }
        done.setTitleColor(ReporterTheme.text, for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)

        let title = UILabel()
        title.text = "Area"
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = ReporterTheme.text
        title.textAlignment = .center

        let bar = UIStackView(arrangedSubviews: [cancel, title, done])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.distribution = .equalCentering
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        bar.heightAnchor.constraint(equalToConstant: barHeight).isActive = true

        let separator = UIView()
        separator.backgroundColor = ReporterTheme.borderSoft
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        picker.dataSource = self
        picker.delegate = self
        picker.accessibilityIdentifier = CatchDevReporterAccessibility.areaWheel
        picker.selectRow(selectedRow, inComponent: 0, animated: false)
        picker.heightAnchor.constraint(equalToConstant: wheelHeight).isActive = true

        let column = UIStackView(arrangedSubviews: [bar, separator, picker])
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The column is its own height: the bar (52) + separator (1) + the wheel (216) are
            // all required, fixed heights. Pinning BOTH edges as well over-determines it, and
            // that is unsatisfiable at any sheet height other than the exact custom detent —
            // i.e. on iOS 15, where the detent falls back to `.medium()`, and on iPad. Anchor
            // the content to the bottom (where a picker belongs) and let the top float.
            column.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            column.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor),
        ])
    }

    /// Sheet height: the bar + the wheel + the home-indicator inset, so it hugs its content
    /// instead of sitting at a half-screen detent with dead space below.
    private var contentHeight: CGFloat {
        barHeight + 1 + wheelHeight + bottomInset
    }

    private func configureSheet() {
        guard let sheet = sheetPresentationController else { return }
        sheet.prefersGrabberVisible = true
        sheet.preferredCornerRadius = 20
        if #available(iOS 16.0, *) {
            sheet.detents = [.custom(identifier: .init("cdv.area")) { [weak self] _ in
                self?.contentHeight
            }]
        } else {
            sheet.detents = [.medium()]
        }
    }

    private func barButton(title: String, id: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16)
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}

/// Test seam for the app-hosted layout tests. The package's own `swift test` target is
/// Foundation-only (macOS) and cannot see UIKit, so the sheet's Auto Layout — which is
/// over-determined the moment its content column is pinned to both edges — is only reachable
/// from the example app's unit tests.
@_spi(CatchDevTesting)
public enum CatchDevAreaPickerTesting {
    public static func make(areas: [String], selected: String?, bottomInset: CGFloat) -> UIViewController {
        AreaPickerSheetViewController(
            areas: areas, selected: selected, bottomInset: bottomInset, onPick: { _ in }
        )
    }
}

extension AreaPickerSheetViewController: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        rows.count
    }

    func pickerView(
        _ pickerView: UIPickerView,
        attributedTitleForRow row: Int,
        forComponent component: Int
    ) -> NSAttributedString? {
        // Themed rather than plain `titleForRow`, so the wheel follows the reporter's palette
        // in dark mode instead of defaulting to the system label colour.
        NSAttributedString(
            string: rows[row],
            attributes: [
                .foregroundColor: row == 0 ? ReporterTheme.textMuted : ReporterTheme.text,
                .font: UIFont.systemFont(ofSize: 20),
            ]
        )
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        selectedRow = row
    }
}
#endif
