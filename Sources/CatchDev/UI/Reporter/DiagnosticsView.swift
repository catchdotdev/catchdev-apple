#if canImport(UIKit)
import UIKit

/// The "Included automatically" disclosure: a collapsible card listing the debugging
/// context the SDK attaches, with a per-row switch to exclude items before sending
/// (except locked rows like the session id).
final class DiagnosticsView: UIView {
    /// Called whenever the excluded set changes.
    var onChange: ((Set<DiagnosticID>) -> Void)?
    private(set) var excluded: Set<DiagnosticID> = []

    private var items: [DiagnosticItem] = []
    private var isOpen = false

    private let headerButton = UIButton(type: .system)
    private let countBadge = PaddedLabel()
    private let subtitleLabel = UILabel()
    private let chevron = UIImageView()
    private let bodyStack = UIStackView()
    private let titleLabel = UILabel()

    init() {
        super.init(frame: .zero)
        backgroundColor = ReporterTheme.elevated
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = ReporterTheme.border.cgColor
        clipsToBounds = true
        buildHeader()
        buildBody()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(items: [DiagnosticItem]) {
        self.items = items
        rebuildBodyRows()
        updateHeader()
    }

    // MARK: - Header

    private func buildHeader() {
        let shield = UIView()
        shield.backgroundColor = ReporterTheme.bugAccentBg
        shield.layer.cornerRadius = 9
        shield.translatesAutoresizingMaskIntoConstraints = false
        let shieldIcon = UIImageView(image: ReporterStyle.symbolImage("checkmark.shield", pointSize: 15, weight: .medium))
        shieldIcon.tintColor = ReporterTheme.bugAccent
        shieldIcon.translatesAutoresizingMaskIntoConstraints = false
        shield.addSubview(shieldIcon)

        titleLabel.text = "Included automatically"
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.textColor = ReporterTheme.text

        countBadge.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        countBadge.textColor = ReporterTheme.textMuted
        countBadge.backgroundColor = ReporterTheme.mutedBg
        countBadge.layer.cornerRadius = 5
        countBadge.clipsToBounds = true
        countBadge.insets = UIEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, countBadge])
        titleRow.axis = .horizontal
        titleRow.spacing = 7
        titleRow.alignment = .center

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = ReporterTheme.textMuted
        subtitleLabel.numberOfLines = 1

        let textColumn = UIStackView(arrangedSubviews: [titleRow, subtitleLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 2
        textColumn.alignment = .leading

        chevron.image = ReporterStyle.symbolImage("chevron.down", pointSize: 14, weight: .medium)
        chevron.tintColor = ReporterTheme.textMuted
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let headerRow = UIStackView(arrangedSubviews: [shield, textColumn, chevron])
        headerRow.axis = .horizontal
        headerRow.spacing = 12
        headerRow.alignment = .center
        headerRow.isUserInteractionEnabled = false
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.accessibilityIdentifier = CatchDevReporterAccessibility.diagnosticsHeader
        headerButton.addTarget(self, action: #selector(toggleOpen), for: .touchUpInside)
        addSubview(headerButton)
        headerButton.addSubview(headerRow)

        NSLayoutConstraint.activate([
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            shield.widthAnchor.constraint(equalToConstant: 32),
            shield.heightAnchor.constraint(equalToConstant: 32),
            shieldIcon.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
            shieldIcon.centerYAnchor.constraint(equalTo: shield.centerYAnchor),
            headerRow.topAnchor.constraint(equalTo: headerButton.topAnchor, constant: 13),
            headerRow.bottomAnchor.constraint(equalTo: headerButton.bottomAnchor, constant: -13),
            headerRow.leadingAnchor.constraint(equalTo: headerButton.leadingAnchor, constant: 14),
            headerRow.trailingAnchor.constraint(equalTo: headerButton.trailingAnchor, constant: -14),
        ])
    }

    private func buildBody() {
        bodyStack.axis = .vertical
        bodyStack.spacing = 0
        bodyStack.isHidden = true
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyStack)
        NSLayoutConstraint.activate([
            bodyStack.topAnchor.constraint(equalTo: headerButton.bottomAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func rebuildBodyRows() {
        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let note = UILabel()
        note.text = "Catch attaches this debugging context silently so you don’t have to describe it."
        note.font = .systemFont(ofSize: 12)
        note.textColor = ReporterTheme.textMuted
        note.numberOfLines = 0
        let noteWrap = UIView()
        noteWrap.addSubview(note)
        note.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: noteWrap.topAnchor),
            note.bottomAnchor.constraint(equalTo: noteWrap.bottomAnchor, constant: -10),
            note.leadingAnchor.constraint(equalTo: noteWrap.leadingAnchor, constant: 14),
            note.trailingAnchor.constraint(equalTo: noteWrap.trailingAnchor, constant: -14),
        ])
        bodyStack.addArrangedSubview(noteWrap)

        for item in items {
            bodyStack.addArrangedSubview(makeRow(item))
        }
    }

    private func makeRow(_ item: DiagnosticItem) -> UIView {
        let iconWrap = UIView()
        iconWrap.backgroundColor = ReporterTheme.mutedBg
        iconWrap.layer.cornerRadius = 8
        iconWrap.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: ReporterStyle.symbolImage(item.icon, pointSize: 13))
        icon.tintColor = ReporterTheme.textMuted
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.addSubview(icon)

        let key = UILabel()
        key.text = item.title
        key.font = .systemFont(ofSize: 13, weight: .medium)
        key.textColor = ReporterTheme.text

        let value = UILabel()
        value.text = item.value
        value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        value.textColor = ReporterTheme.textMuted
        value.lineBreakMode = .byTruncatingTail

        let textColumn = UIStackView(arrangedSubviews: [key, value])
        textColumn.axis = .vertical
        textColumn.spacing = 1
        textColumn.alignment = .leading

        let trailing: UIView
        if item.locked {
            let req = UILabel()
            req.text = "required"
            req.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            req.textColor = ReporterTheme.textFaint
            trailing = req
        } else {
            let toggle = UISwitch()
            toggle.onTintColor = ReporterTheme.bugAccent
            toggle.isOn = !excluded.contains(item.id)
            toggle.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
            toggle.accessibilityIdentifier = CatchDevReporterAccessibility.diagnosticsToggle(item.id)
            // Read the switch from the action's sender (don't capture `toggle` — that would
            // form a switch → action → switch retain cycle that leaks per presentation).
            toggle.addAction(UIAction { [weak self] action in
                let isOn = (action.sender as? UISwitch)?.isOn ?? true
                self?.setExcluded(item.id, excluded: !isOn)
            }, for: .valueChanged)
            trailing = toggle
        }
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [iconWrap, textColumn, trailing])
        row.axis = .horizontal
        row.spacing = 11
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)

        let container = UIView()
        container.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            iconWrap.widthAnchor.constraint(equalToConstant: 28),
            iconWrap.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: iconWrap.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWrap.centerYAnchor),
        ])
        return container
    }

    private func setExcluded(_ id: DiagnosticID, excluded shouldExclude: Bool) {
        if shouldExclude { excluded.insert(id) } else { excluded.remove(id) }
        updateHeader()
        onChange?(excluded)
    }

    private func updateHeader() {
        let active = items.count - excluded.count
        countBadge.text = "\(active) items"
        subtitleLabel.text = isOpen
            ? "Tap a switch to exclude an item before sending."
            : "Screen, version, device, breadcrumbs…"
    }

    @objc private func toggleOpen() {
        isOpen.toggle()
        updateHeader()
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut]) {
            self.bodyStack.isHidden = !self.isOpen
            self.chevron.transform = self.isOpen
                ? CGAffineTransform(rotationAngle: .pi)
                : .identity
            self.superview?.layoutIfNeeded()
        }
    }
}

/// A `UILabel` with content insets, used for the small "N items" pill.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}
#endif
