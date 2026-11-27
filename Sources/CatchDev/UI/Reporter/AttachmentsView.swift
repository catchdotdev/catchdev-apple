#if canImport(UIKit)
import UIKit

/// The "Add more" block: a row of Screenshot / Record / Attach tools plus a horizontal
/// strip of attached thumbnails (screenshot with an Annotate badge, recording with a
/// duration, file with name + size), each removable. Once the report holds as many
/// attachments as it can carry, the tools that would add one are disabled and a hint says so.
final class AttachmentsView: UIView {
    var onScreenshot: (() -> Void)?
    var onRecord: (() -> Void)?
    var onAttach: (() -> Void)?
    var onRemove: ((String) -> Void)?
    var onAnnotate: ((String) -> Void)?

    private let thumbsScroll = UIScrollView()
    private let thumbsStack = UIStackView()
    private let toolsRow = UIStackView()
    private var screenshotTool: UIButton!
    private var recordTool: UIButton!
    private var attachTool: UIButton!
    private let limitHint = UILabel()

    init() {
        super.init(frame: .zero)
        buildThumbs()
        buildTools()
        buildLimitHint()

        let column = UIStackView(arrangedSubviews: [thumbsScroll, toolsRow, limitHint])
        column.axis = .vertical
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildThumbs() {
        thumbsScroll.showsHorizontalScrollIndicator = false
        thumbsScroll.translatesAutoresizingMaskIntoConstraints = false
        thumbsStack.axis = .horizontal
        thumbsStack.spacing = 10
        thumbsStack.translatesAutoresizingMaskIntoConstraints = false
        thumbsScroll.addSubview(thumbsStack)
        NSLayoutConstraint.activate([
            thumbsStack.topAnchor.constraint(equalTo: thumbsScroll.topAnchor),
            thumbsStack.bottomAnchor.constraint(equalTo: thumbsScroll.bottomAnchor),
            thumbsStack.leadingAnchor.constraint(equalTo: thumbsScroll.leadingAnchor),
            thumbsStack.trailingAnchor.constraint(equalTo: thumbsScroll.trailingAnchor),
            thumbsStack.heightAnchor.constraint(equalTo: thumbsScroll.heightAnchor),
        ])
        thumbsScroll.isHidden = true
    }

    private func buildTools() {
        toolsRow.axis = .horizontal
        toolsRow.distribution = .fillEqually
        toolsRow.spacing = 8
        let screenshot = makeTool(
            "Screenshot", "camera", CatchDevReporterAccessibility.toolScreenshot
        ) { [weak self] in self?.onScreenshot?() }
        let record = makeTool(
            "Record", "video", CatchDevReporterAccessibility.toolRecord
        ) { [weak self] in self?.onRecord?() }
        let attach = makeTool(
            "Attach", "paperclip", CatchDevReporterAccessibility.toolAttach
        ) { [weak self] in self?.onAttach?() }
        [screenshot, record, attach].forEach { toolsRow.addArrangedSubview($0) }
        (screenshotTool, recordTool, attachTool) = (screenshot, record, attach)
    }

    private func buildLimitHint() {
        limitHint.text = "Up to \(AttachmentLimits.maxPerReport) attachments"
        limitHint.font = .systemFont(ofSize: 12.5)
        limitHint.textColor = ReporterTheme.textMuted
        limitHint.accessibilityIdentifier = CatchDevReporterAccessibility.attachmentLimit
        limitHint.isHidden = true
    }

    private func makeTool(_ title: String, _ symbol: String, _ id: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = ReporterStyle.symbolImage(symbol, pointSize: 17)
        config.imagePlacement = .top
        config.imagePadding = 5
        config.titleTextAttributesTransformer = .init { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 11.5, weight: .medium)
            return out
        }
        button.configuration = config
        button.tintColor = ReporterTheme.textSoft
        button.backgroundColor = ReporterTheme.elevated
        button.layer.cornerRadius = 13
        button.cdvSetBorder(ReporterTheme.border)
        button.accessibilityIdentifier = id
        button.heightAnchor.constraint(equalToConstant: 62).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    // MARK: - Thumbnails

    /// Show `attachments`. With `limitReached`, nothing more may be added: Record and Attach
    /// are disabled and the hint shows. The Screenshot tool stays enabled while a screenshot is
    /// attached, because it then marks that one up instead of adding another.
    func setAttachments(_ attachments: [PendingAttachment], limitReached: Bool) {
        thumbsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        thumbsScroll.isHidden = attachments.isEmpty
        for (index, attachment) in attachments.enumerated() {
            thumbsStack.addArrangedSubview(makeThumb(attachment, index: index))
        }
        let hasScreenshot = attachments.contains { $0.kind == .screenshot }
        screenshotTool.isEnabled = !limitReached || hasScreenshot
        recordTool.isEnabled = !limitReached
        attachTool.isEnabled = !limitReached
        limitHint.isHidden = !limitReached
    }

    private func makeThumb(_ attachment: PendingAttachment, index: Int) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = ReporterTheme.mutedBg
        card.layer.cornerRadius = 12
        // Without a border a light screenshot is indistinguishable from the sheet behind it —
        // the thumbnail reads as floating in space. Drawn on the card's own layer, so it sits
        // above the image (CALayer renders its border above its sublayers) and applies to every
        // attachment kind. Matches the 1pt border on the description box and the Area field.
        card.cdvSetBorder(ReporterTheme.border)
        card.clipsToBounds = true
        card.accessibilityIdentifier = CatchDevReporterAccessibility.attachment(index)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 74),
            card.heightAnchor.constraint(equalToConstant: 98),
        ])

        switch attachment.kind {
        case .screenshot:
            let imageView = UIImageView(image: attachment.thumbnail)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(imageView)
            pin(imageView, to: card)

            // Mark up an existing screenshot. Mirrors the remove button in the opposite corner,
            // so both actions on a thumbnail are where the eye already looks.
            let edit = makeCornerButton(
                symbol: "pencil",
                identifier: CatchDevReporterAccessibility.attachmentEdit(index),
                label: "Annotate screenshot"
            ) { [weak self] in self?.onAnnotate?(attachment.id) }
            card.addSubview(edit)
            NSLayoutConstraint.activate([
                edit.topAnchor.constraint(equalTo: card.topAnchor, constant: 5),
                edit.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 5),
            ])

            // State only — the pencil above is the action. No icon: "Annotated" is already the
            // widest label a 74pt card can take (see `addBadge`).
            if attachment.annotated {
                addBadge(title: "Annotated", symbol: nil, to: card)
            }
        case .recording:
            card.backgroundColor = UIColor(white: 0.1, alpha: 1)
            let play = UIImageView(image: ReporterStyle.symbolImage("play.fill", pointSize: 16))
            play.tintColor = .white
            play.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(play)
            NSLayoutConstraint.activate([
                play.centerXAnchor.constraint(equalTo: card.centerXAnchor),
                play.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            ])
            addBadge(title: "Video", symbol: "video", to: card)
        case .file:
            card.backgroundColor = ReporterTheme.elevated
            let icon = UIImageView(image: ReporterStyle.symbolImage("paperclip", pointSize: 15))
            icon.tintColor = ReporterTheme.accent(for: .feedback)
            icon.translatesAutoresizingMaskIntoConstraints = false
            let name = UILabel()
            name.text = attachment.filename ?? "file"
            name.font = .systemFont(ofSize: 11, weight: .semibold)
            name.textColor = ReporterTheme.text
            name.lineBreakMode = .byTruncatingMiddle
            let size = UILabel()
            size.text = Self.formatBytes(attachment.data.count)
            size.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            size.textColor = ReporterTheme.textMuted
            let column = UIStackView(arrangedSubviews: [name, size])
            column.axis = .vertical
            column.spacing = 1
            column.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(icon)
            card.addSubview(column)
            NSLayoutConstraint.activate([
                icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
                icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
                column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
                column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
                column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            ])
        }

        let remove = makeCornerButton(
            symbol: "xmark",
            identifier: CatchDevReporterAccessibility.attachmentRemove(index),
            label: "Remove attachment"
        ) { [weak self] in self?.onRemove?(attachment.id) }
        card.addSubview(remove)
        NSLayoutConstraint.activate([
            remove.topAnchor.constraint(equalTo: card.topAnchor, constant: 5),
            remove.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -5),
        ])
        return card
    }

    /// A 20pt circular action pinned to a thumbnail's corner (annotate, remove).
    private func makeCornerButton(
        symbol: String,
        identifier: String,
        label: String,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(ReporterStyle.symbolImage(symbol, pointSize: 9, weight: .bold), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor(white: 0, alpha: 0.7)
        button.layer.cornerRadius = 10
        button.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
        return button
    }

    /// A state pill in a thumbnail's bottom-left corner ("Annotated", "Video"). Never
    /// interactive — the corner buttons are the actions.
    ///
    /// The card is only 74pt wide and clips to its bounds, so a badge that overflows is not
    /// merely ugly, it is *cut in half*: "Annotated" at the old metrics (10.5pt + a checkmark
    /// + 14pt of insets) wanted ~79pt against the 64pt between the two 5pt margins. It fits now
    /// on two counts — the metrics are sized for the card (no icon on the long label), and the
    /// trailing constraint is a hard ceiling, so any future label compresses rather than
    /// spilling under the clip.
    private func addBadge(title: String, symbol: String?, to card: UIView) {
        let badge = UIButton(type: .system)
        // Callers pin this with Auto Layout. Without this the autoresizing-mask constraints
        // fight those, UIKit resolves the conflict by collapsing the badge to zero size, and it
        // silently never renders — which is exactly what happened to the Annotate/Video badges.
        badge.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()
        config.title = title
        config.titleLineBreakMode = .byTruncatingTail
        if let symbol {
            config.image = ReporterStyle.symbolImage(symbol, pointSize: 8.5)
            config.imagePadding = 3
        }
        config.contentInsets = .init(top: 3, leading: 6, bottom: 3, trailing: 6)
        config.titleTextAttributesTransformer = .init { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 9.5, weight: .semibold)
            return out
        }
        badge.configuration = config
        badge.tintColor = .white
        badge.backgroundColor = UIColor(white: 0, alpha: 0.78)
        badge.layer.cornerRadius = 9
        badge.clipsToBounds = true
        badge.isUserInteractionEnabled = false

        card.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 5),
            badge.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -5),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -5),
        ])
    }

    private func pin(_ view: UIView, to container: UIView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    static func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(n / 1024) KB" }
        return String(format: "%.1f MB", Double(n) / (1024 * 1024))
    }
}
#endif
