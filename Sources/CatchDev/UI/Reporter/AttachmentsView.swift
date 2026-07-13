#if canImport(UIKit)
import UIKit

/// The "Add more" block: a row of Screenshot / Record / Attach tools plus a horizontal
/// strip of attached thumbnails (screenshot with an Annotate badge, recording with a
/// duration, file with name + size), each removable.
final class AttachmentsView: UIView {
    var onScreenshot: (() -> Void)?
    var onRecord: (() -> Void)?
    var onAttach: (() -> Void)?
    var onRemove: ((String) -> Void)?
    var onAnnotate: ((String) -> Void)?

    private let thumbsScroll = UIScrollView()
    private let thumbsStack = UIStackView()
    private let toolsRow = UIStackView()

    init() {
        super.init(frame: .zero)
        buildThumbs()
        buildTools()

        let column = UIStackView(arrangedSubviews: [thumbsScroll, toolsRow])
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
        toolsRow.addArrangedSubview(makeTool(
            "Screenshot", "camera", CatchDevReporterAccessibility.toolScreenshot
        ) { [weak self] in self?.onScreenshot?() })
        toolsRow.addArrangedSubview(makeTool(
            "Record", "video", CatchDevReporterAccessibility.toolRecord
        ) { [weak self] in self?.onRecord?() })
        toolsRow.addArrangedSubview(makeTool(
            "Attach", "paperclip", CatchDevReporterAccessibility.toolAttach
        ) { [weak self] in self?.onAttach?() })
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
        button.layer.borderWidth = 1
        button.layer.borderColor = ReporterTheme.border.cgColor
        button.accessibilityIdentifier = id
        button.heightAnchor.constraint(equalToConstant: 62).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    // MARK: - Thumbnails

    func setAttachments(_ attachments: [PendingAttachment]) {
        thumbsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        thumbsScroll.isHidden = attachments.isEmpty
        for (index, attachment) in attachments.enumerated() {
            thumbsStack.addArrangedSubview(makeThumb(attachment, index: index))
        }
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
        card.layer.borderWidth = 1
        card.layer.borderColor = ReporterTheme.border.cgColor
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
            let badge = makeBadge(
                title: attachment.annotated ? "Annotated" : "Annotate",
                symbol: "pencil"
            ) { [weak self] in self?.onAnnotate?(attachment.id) }
            card.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 5),
                badge.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -5),
            ])
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
            let badge = makeBadge(title: "Video", symbol: "video", action: nil)
            card.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 5),
                badge.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -5),
            ])
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

        let remove = UIButton(type: .system)
        remove.setImage(ReporterStyle.symbolImage("xmark", pointSize: 9, weight: .bold), for: .normal)
        remove.tintColor = .white
        remove.backgroundColor = UIColor(white: 0, alpha: 0.7)
        remove.layer.cornerRadius = 10
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.accessibilityIdentifier = CatchDevReporterAccessibility.attachmentRemove(index)
        remove.addAction(UIAction { [weak self] _ in self?.onRemove?(attachment.id) }, for: .touchUpInside)
        card.addSubview(remove)
        NSLayoutConstraint.activate([
            remove.widthAnchor.constraint(equalToConstant: 20),
            remove.heightAnchor.constraint(equalToConstant: 20),
            remove.topAnchor.constraint(equalTo: card.topAnchor, constant: 5),
            remove.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -5),
        ])
        return card
    }

    private func makeBadge(title: String, symbol: String, action: (() -> Void)?) -> UIView {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = ReporterStyle.symbolImage(symbol, pointSize: 9)
        config.imagePadding = 4
        config.contentInsets = .init(top: 3, leading: 7, bottom: 3, trailing: 7)
        config.titleTextAttributesTransformer = .init { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 10.5, weight: .medium)
            return out
        }
        button.configuration = config
        button.tintColor = .white
        button.backgroundColor = UIColor(white: 0, alpha: 0.78)
        button.layer.cornerRadius = 11
        button.clipsToBounds = true
        button.isUserInteractionEnabled = action != nil
        if let action { button.addAction(UIAction { _ in action() }, for: .touchUpInside) }
        return button
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
