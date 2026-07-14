#if canImport(UIKit)
import UIKit

/// The full-cover "Sending report…" overlay: a spinner over an animated checklist of the
/// steps the SDK performs (bundling context, uploading, posting). The step animation is
/// cosmetic — the reporter swaps to ``SuccessOverlayView`` when the real work finishes.
final class SendingOverlayView: UIView {
    private let stepsStack = UIStackView()
    private var stepRows: [(dot: UIView, check: UIImageView, label: UILabel)] = []
    private var timer: Timer?

    init(steps: [String]) {
        super.init(frame: .zero)
        backgroundColor = ReporterTheme.bg

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = ReporterTheme.text
        spinner.hidesWhenStopped = false
        // A continuous spinner animation blocks XCUITest accessibility snapshots, making
        // the overlay unobservable in UI tests — keep it static under the test harness.
        if !ProcessInfo.processInfo.arguments.contains("-CatchDevUITest") {
            spinner.startAnimating()
        }

        let title = UILabel()
        title.text = "Sending report…"
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = ReporterTheme.text
        title.isAccessibilityElement = true
        title.accessibilityIdentifier = CatchDevReporterAccessibility.sending

        let subtitle = UILabel()
        subtitle.text = "Catch is bundling your debugging context."
        subtitle.font = .systemFont(ofSize: 13.5)
        subtitle.textColor = ReporterTheme.textMuted
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        stepsStack.axis = .vertical
        stepsStack.spacing = 9
        stepsStack.alignment = .leading
        for step in steps { stepsStack.addArrangedSubview(makeStepRow(step)) }

        let column = UIStackView(arrangedSubviews: [spinner, title, subtitle, stepsStack])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 8
        column.setCustomSpacing(20, after: spinner)
        column.setCustomSpacing(22, after: subtitle)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
        ])
        animateSteps()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    private func makeStepRow(_ text: String) -> UIView {
        let dot = UIView()
        dot.layer.cornerRadius = 8
        dot.cdvSetBorder(ReporterTheme.border, width: 1.5)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 16).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let check = UIImageView(image: ReporterStyle.symbolImage("checkmark", pointSize: 9, weight: .bold))
        check.tintColor = .white
        check.translatesAutoresizingMaskIntoConstraints = false
        check.isHidden = true
        dot.addSubview(check)
        NSLayoutConstraint.activate([
            check.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
        ])

        let label = UILabel()
        label.text = text
        label.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        label.textColor = ReporterTheme.textMuted
        label.alpha = 0.4

        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        stepRows.append((dot, check, label))
        return row
    }

    private func animateSteps() {
        var index = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: true) { [weak self] timer in
            guard let self, index < self.stepRows.count else { timer.invalidate(); return }
            let row = self.stepRows[index]
            UIView.animate(withDuration: 0.2) {
                row.dot.backgroundColor = ReporterTheme.bugAccent
                row.dot.cdvSetBorder(ReporterTheme.bugAccent, width: 1.5)
                row.check.isHidden = false
                row.label.alpha = 1
                row.label.textColor = ReporterTheme.textSoft
            }
            index += 1
        }
    }
}

/// The success overlay: a check, the report id, and a Done action. When `queued` (the report
/// is durably saved but the device is offline) it says so — a success-style state, never an
/// error: the SDK delivers it on reconnect.
final class SuccessOverlayView: UIView {
    var onDone: (() -> Void)?

    init(type: ReportType, reportId: String, queued: Bool = false) {
        super.init(frame: .zero)
        backgroundColor = ReporterTheme.bg
        accessibilityIdentifier = queued
            ? CatchDevReporterAccessibility.queued
            : CatchDevReporterAccessibility.success

        let checkWrap = UIView()
        checkWrap.backgroundColor = ReporterTheme.bugAccentBg
        checkWrap.layer.cornerRadius = 32
        checkWrap.translatesAutoresizingMaskIntoConstraints = false
        let symbol = queued ? "clock.arrow.circlepath" : "checkmark"
        let check = UIImageView(image: ReporterStyle.symbolImage(symbol, pointSize: 28, weight: .bold))
        check.tintColor = ReporterTheme.bugAccent
        check.translatesAutoresizingMaskIntoConstraints = false
        checkWrap.addSubview(check)

        let title = UILabel()
        title.text = queued ? "Saved for later" : "Report sent"
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = ReporterTheme.text

        let subtitle = UILabel()
        if queued {
            subtitle.text = "You're offline — we'll send it when you're back online."
        } else {
            subtitle.text = type == .bug
                ? "Thanks — the team can see exactly what happened."
                : "Thanks for helping make this better."
        }
        subtitle.font = .systemFont(ofSize: 13.5)
        subtitle.textColor = ReporterTheme.textMuted
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        let idLabel = PaddedLabel()
        idLabel.text = reportId
        idLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        idLabel.textColor = ReporterTheme.textMuted
        idLabel.backgroundColor = ReporterTheme.mutedBg
        idLabel.layer.cornerRadius = 8
        idLabel.clipsToBounds = true
        idLabel.insets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

        let done = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = "Done"
        config.baseBackgroundColor = ReporterTheme.actionBg
        config.baseForegroundColor = ReporterTheme.actionFg
        config.cornerStyle = .large
        done.configuration = config
        done.accessibilityIdentifier = CatchDevReporterAccessibility.successDone
        done.translatesAutoresizingMaskIntoConstraints = false
        done.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)

        let column = UIStackView(arrangedSubviews: [checkWrap, title, subtitle, idLabel])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 6
        column.setCustomSpacing(18, after: checkWrap)
        column.setCustomSpacing(18, after: subtitle)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        addSubview(done)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            checkWrap.widthAnchor.constraint(equalToConstant: 64),
            checkWrap.heightAnchor.constraint(equalToConstant: 64),
            check.centerXAnchor.constraint(equalTo: checkWrap.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: checkWrap.centerYAnchor),
            done.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 26),
            done.centerXAnchor.constraint(equalTo: centerXAnchor),
            done.widthAnchor.constraint(equalToConstant: 200),
            done.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A label with symmetric text insets (used by the success overlay's report-id chip).
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
