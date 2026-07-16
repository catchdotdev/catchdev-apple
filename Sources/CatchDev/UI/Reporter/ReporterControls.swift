#if canImport(UIKit)
import UIKit

// MARK: - Shared style helpers

enum ReporterStyle {
    /// A section header like "Area  •  optional".
    static func sectionLabel(_ text: String, optional: Bool = false) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .firstBaseline

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = ReporterTheme.textMuted
        row.addArrangedSubview(label)

        if optional {
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)

            let opt = UILabel()
            opt.text = "optional"
            opt.font = .systemFont(ofSize: 12, weight: .regular)
            opt.textColor = ReporterTheme.textFaint
            row.addArrangedSubview(opt)
        }
        return row
    }

    static func symbolImage(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        )
    }
}

// MARK: - Segmented tabs (Feedback / Bug report)

final class SegmentedTabsView: UIView {
    var onChange: ((ReportType) -> Void)?
    private(set) var selected: ReportType = .feedback

    private let thumb = UIView()
    private let feedbackButton = UIButton(type: .system)
    private let bugButton = UIButton(type: .system)
    private let stack = UIStackView()

    init() {
        super.init(frame: .zero)
        backgroundColor = ReporterTheme.mutedBg
        layer.cornerRadius = 11

        thumb.backgroundColor = ReporterTheme.bg
        thumb.layer.cornerRadius = 8
        thumb.layer.shadowColor = UIColor.black.cgColor
        thumb.layer.shadowOpacity = 0.10
        thumb.layer.shadowRadius = 2
        thumb.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(thumb)

        configure(feedbackButton, title: "Feedback", symbol: "bubble.left",
                  id: CatchDevReporterAccessibility.tabFeedback)
        configure(bugButton, title: "Bug report", symbol: "ladybug",
                  id: CatchDevReporterAccessibility.tabBug)
        feedbackButton.addTarget(self, action: #selector(tapFeedback), for: .touchUpInside)
        bugButton.addTarget(self, action: #selector(tapBug), for: .touchUpInside)

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(feedbackButton)
        stack.addArrangedSubview(bugButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ button: UIButton, title: String, symbol: String, id: String) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = ReporterStyle.symbolImage(symbol, pointSize: 13, weight: .medium)
        config.imagePadding = 6
        config.contentInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)
        config.titleTextAttributesTransformer = .init { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 14, weight: .medium)
            return out
        }
        button.configuration = config
        button.accessibilityIdentifier = id
    }

    @objc private func tapFeedback() { setSelected(.feedback, animated: true); onChange?(.feedback) }
    @objc private func tapBug() { setSelected(.bug, animated: true); onChange?(.bug) }

    func setSelected(_ type: ReportType, animated: Bool) {
        selected = type
        let move = { self.setNeedsLayout(); self.layoutIfNeeded() }
        if animated {
            UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseOut]) { move() }
        } else {
            move()
        }
        updateColors()
    }

    private func updateColors() {
        feedbackButton.tintColor = selected == .feedback ? ReporterTheme.text : ReporterTheme.textMuted
        bugButton.tintColor = selected == .bug ? ReporterTheme.text : ReporterTheme.textMuted
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let half = (bounds.width - 6) / 2
        let x = selected == .feedback ? CGFloat(3) : 3 + half
        thumb.frame = CGRect(x: x, y: 3, width: half, height: bounds.height - 6)
    }
}

// MARK: - Severity (bug only)

final class SeverityView: UIView {
    var onChange: ((Severity) -> Void)?
    private(set) var selected: Severity?
    private var buttons: [Severity: UIButton] = [:]

    private static let order: [(Severity, String)] = [
        (.blocks, "Blocks me"), (.annoying, "Annoying"), (.minor, "Minor"),
    ]

    init() {
        super.init(frame: .zero)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: 44),
        ])
        for (severity, label) in Self.order {
            let button = makeButton(severity, label)
            buttons[severity] = button
            stack.addArrangedSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(_ severity: Severity, _ label: String) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = label
        config.titleTextAttributesTransformer = .init { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 13, weight: .medium)
            return out
        }
        let tone = ReporterTheme.severityTone(severity)
        let dot = ReporterStyle.symbolImage("circle.fill", pointSize: 9)?
            .withTintColor(tone.color, renderingMode: .alwaysOriginal)
        config.image = dot
        config.imagePadding = 7
        button.configuration = config
        button.layer.cornerRadius = 999
        button.cdvSetBorder(ReporterTheme.border)
        button.backgroundColor = ReporterTheme.elevated
        button.tintColor = ReporterTheme.textSoft
        button.accessibilityIdentifier = CatchDevReporterAccessibility.severity(severity)
        button.addAction(UIAction { [weak self] _ in self?.select(severity) }, for: .touchUpInside)
        return button
    }

    func setSelected(_ severity: Severity?) {
        selected = severity
        for (sev, button) in buttons {
            let tone = ReporterTheme.severityTone(sev)
            let on = sev == severity
            button.backgroundColor = on ? tone.bg : ReporterTheme.elevated
            button.cdvSetBorder(on ? tone.color : ReporterTheme.border)
            button.tintColor = on ? tone.color : ReporterTheme.textSoft
        }
    }

    private func select(_ severity: Severity) {
        setSelected(severity)
        onChange?(severity)
    }
}

// MARK: - Area dropdown

final class AreaDropdownView: UIView {
    var onChange: ((String?) -> Void)?
    /// Fired when the field is tapped; the reporter presents the picker sheet.
    var onOpen: (() -> Void)?
    private(set) var selected: String?
    private let button = UIButton(type: .system)

    init() {
        super.init(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = ReporterTheme.fieldBg
        button.layer.cornerRadius = 12
        button.cdvSetBorder(ReporterTheme.border)
        button.contentHorizontalAlignment = .fill
        button.accessibilityIdentifier = CatchDevReporterAccessibility.area
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.heightAnchor.constraint(equalToConstant: 48),
        ])
        button.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Applies a selection made in the picker sheet and notifies the reporter.
    func choose(_ area: String?) {
        selected = area
        render()
        onChange?(area)
    }

    func setSelected(_ area: String?) {
        selected = area
        render()
    }

    private func render() {
        var config = UIButton.Configuration.plain()
        config.title = selected ?? "Choose an area"
        config.baseForegroundColor = selected == nil ? ReporterTheme.textFaint : ReporterTheme.text
        config.titleTextAttributesTransformer = .init { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 15, weight: .regular)
            return out
        }
        config.image = ReporterStyle.symbolImage("chevron.down", pointSize: 13, weight: .medium)?
            .withTintColor(ReporterTheme.textMuted, renderingMode: .alwaysOriginal)
        config.imagePlacement = .trailing
        config.contentInsets = .init(top: 0, leading: 14, bottom: 0, trailing: 14)
        // Push the chevron to the trailing edge.
        config.titleAlignment = .leading
        button.configuration = config
        // Stretch the title so the chevron sits at the far edge.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
}
#endif
