#if canImport(UIKit)
import UIKit

/// Bottom-anchored area selector.
///
/// Replaces the `UIMenu` popover, which floated over the Area field itself — the field
/// appeared to vanish and reappear as the menu covered it. A sheet keeps the field in
/// place and reads as a deliberate selection step.
///
/// Rows are real `UIButton`s (not `UIAlertAction`s) so they can carry the
/// `catchdev.reporter.area.*` accessibility identifiers the UI tests select on;
/// `UIAlertAction` has no public identifier hook.
final class AreaPickerSheetViewController: UIViewController {
    private let areas: [String]
    private let selectedArea: String?
    private let onPick: (String?) -> Void

    private let rowHeight: CGFloat = 52
    private let headerHeight: CGFloat = 52

    init(areas: [String], selected: String?, onPick: @escaping (String?) -> Void) {
        self.areas = areas
        self.selectedArea = selected
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Height of the sheet's own content, so it hugs its rows rather than sitting at a
    /// half-screen detent with dead space below. Each row carries a 1pt separator, and the
    /// detent spans the home-indicator inset, so both are counted.
    private var contentHeight: CGFloat {
        let clearRow = selectedArea == nil ? 0 : rowHeight + 1
        return headerHeight
            + CGFloat(areas.count) * (rowHeight + 1)
            + clearRow
            + view.safeAreaInsets.bottom
            + 8
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReporterTheme.bg
        configureSheet()

        let header = UILabel()
        header.text = "Area"
        header.font = .systemFont(ofSize: 16, weight: .semibold)
        header.textColor = ReporterTheme.text
        header.textAlignment = .center
        header.heightAnchor.constraint(equalToConstant: headerHeight).isActive = true

        let stack = UIStackView(arrangedSubviews: [header])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false

        for area in areas {
            stack.addArrangedSubview(separator())
            stack.addArrangedSubview(makeRow(
                title: area,
                isSelected: area == selectedArea,
                destructive: false,
                identifier: CatchDevReporterAccessibility.areaOption(area)
            ) { [weak self] in self?.pick(area) })
        }

        if selectedArea != nil {
            stack.addArrangedSubview(separator())
            stack.addArrangedSubview(makeRow(
                title: "Clear",
                isSelected: false,
                destructive: true,
                identifier: CatchDevReporterAccessibility.areaClear
            ) { [weak self] in self?.pick(nil) })
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureSheet() {
        guard let sheet = sheetPresentationController else { return }
        sheet.prefersGrabberVisible = true
        sheet.preferredCornerRadius = 20
        if #available(iOS 16.0, *) {
            // Size the sheet to its rows. Pre-16 falls back to the medium detent.
            sheet.detents = [.custom(identifier: .init("cdv.area")) { [weak self] _ in
                self?.contentHeight
            }]
        } else {
            sheet.detents = [.medium()]
        }
    }

    private func pick(_ area: String?) {
        onPick(area)
        dismiss(animated: true)
    }

    /// A row is a plain `UIButton` hosting a leading label and a trailing checkmark.
    /// `UIButton.Configuration` centres its title when there is no image, which reads
    /// wrong in a list, so the content is laid out explicitly instead.
    private func makeRow(
        title: String,
        isSelected: Bool,
        destructive: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 16)
        label.textColor = destructive ? .systemRed : ReporterTheme.text

        let check = UIImageView(
            image: ReporterStyle.symbolImage("checkmark", pointSize: 14, weight: .semibold)?
                .withTintColor(ReporterTheme.text, renderingMode: .alwaysOriginal)
        )
        check.isHidden = !isSelected
        check.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [label, UIView(), check])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        // Let taps fall through to the button.
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: button.topAnchor),
            row.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = ReporterTheme.borderSoft
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}
#endif
