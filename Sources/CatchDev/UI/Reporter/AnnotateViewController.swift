#if canImport(UIKit)
import UIKit

/// Full-screen dark annotation editor opened from a screenshot thumbnail. Offers four
/// tools — box, arrow, pen (freehand), blur — plus three ink colors, and flattens the
/// result onto the screenshot at its native resolution. Self-contained (no PencilKit), so
/// every tool behaves uniformly and the coordinate mapping is explicit.
final class AnnotateViewController: UIViewController {
    private let sourceImage: UIImage
    private let onDone: (UIImage) -> Void
    private let onCancel: () -> Void

    private let imageView = UIImageView()
    private let canvas = AnnotationCanvasView()

    private var toolButtons: [String: UIButton] = [:]
    private var swatches: [UIButton] = []

    init(image: UIImage, onDone: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.sourceImage = image
        self.onDone = onDone
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.04, alpha: 1)
        overrideUserInterfaceStyle = .dark
        buildTopBar()
        buildCanvas()
        buildToolbar()
        selectTool("box")
        canvas.color = .systemRed
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        canvas.displayedImageRect = displayedImageRect()
    }

    // MARK: - Layout

    private func buildTopBar() {
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.tintColor = .white
        cancel.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        cancel.accessibilityIdentifier = CatchDevReporterAccessibility.annotateCancel
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel() }, for: .touchUpInside)

        let title = UILabel()
        title.text = "Annotate"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white

        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.setTitleColor(UIColor(red: 0.29, green: 0.87, blue: 0.5, alpha: 1), for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        done.accessibilityIdentifier = CatchDevReporterAccessibility.annotateDone
        done.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)

        let bar = UIStackView(arrangedSubviews: [cancel, title, done])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.distribution = .equalSpacing
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        topBar = bar
    }
    private var topBar: UIStackView!

    private func buildCanvas() {
        let frame = UIView()
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.backgroundColor = UIColor(white: 0.1, alpha: 1)
        frame.layer.cornerRadius = 16
        frame.clipsToBounds = true
        view.addSubview(frame)

        imageView.image = sourceImage
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityIdentifier = CatchDevReporterAccessibility.screenshot
        frame.addSubview(imageView)

        canvas.backgroundColor = .clear
        canvas.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(canvas)

        NSLayoutConstraint.activate([
            frame.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            frame.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            frame.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            imageView.topAnchor.constraint(equalTo: frame.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: frame.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
        ])
        canvasFrame = frame
    }
    private var canvasFrame: UIView!

    private func buildToolbar() {
        let tools = UIStackView()
        tools.axis = .horizontal
        tools.spacing = 10
        tools.alignment = .center
        tools.translatesAutoresizingMaskIntoConstraints = false

        for (name, symbol) in [("box", "rectangle"), ("arrow", "arrow.up.left"), ("pen", "pencil.tip"), ("blur", "drop")] {
            let button = makeToolButton(name: name, symbol: symbol)
            toolButtons[name] = button
            tools.addArrangedSubview(button)
        }

        let divider = UIView()
        divider.backgroundColor = UIColor(white: 0.2, alpha: 1)
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 26).isActive = true
        tools.addArrangedSubview(divider)

        for color in [UIColor.systemRed, UIColor(red: 0.98, green: 0.75, blue: 0.14, alpha: 1), UIColor.white] {
            let swatch = makeSwatch(color)
            swatches.append(swatch)
            tools.addArrangedSubview(swatch)
        }

        view.addSubview(tools)
        NSLayoutConstraint.activate([
            tools.topAnchor.constraint(equalTo: canvasFrame.bottomAnchor, constant: 16),
            tools.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tools.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        updateSwatchSelection(.systemRed)
    }

    private func makeToolButton(name: String, symbol: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(ReporterStyle.symbolImage(symbol, pointSize: 17, weight: .medium), for: .normal)
        button.tintColor = UIColor(white: 0.83, alpha: 1)
        button.backgroundColor = UIColor(white: 0.11, alpha: 1)
        button.layer.cornerRadius = 12
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor(white: 0.18, alpha: 1).cgColor
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.accessibilityIdentifier = CatchDevReporterAccessibility.annotateTool(name)
        button.addAction(UIAction { [weak self] _ in self?.selectTool(name) }, for: .touchUpInside)
        return button
    }

    private func makeSwatch(_ color: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        button.backgroundColor = color
        button.layer.cornerRadius = 13
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        button.addAction(UIAction { [weak self] _ in
            self?.canvas.color = color
            self?.updateSwatchSelection(color)
        }, for: .touchUpInside)
        return button
    }

    private func selectTool(_ name: String) {
        canvas.tool = AnnotationCanvasView.Tool(rawValue: name) ?? .box
        for (key, button) in toolButtons {
            let on = key == name
            button.backgroundColor = on ? .systemRed : UIColor(white: 0.11, alpha: 1)
            button.tintColor = on ? .white : UIColor(white: 0.83, alpha: 1)
            button.layer.borderColor = (on ? UIColor.systemRed : UIColor(white: 0.18, alpha: 1)).cgColor
        }
    }

    private func updateSwatchSelection(_ color: UIColor) {
        for swatch in swatches {
            let on = swatch.backgroundColor == color
            swatch.layer.borderColor = UIColor(white: 1, alpha: on ? 0.95 : 0.25).cgColor
            swatch.layer.borderWidth = on ? 3 : 2
        }
    }

    private func finish() {
        let flattened = canvas.flatten(onto: sourceImage)
        onDone(flattened)
    }

    /// The aspect-fit rect the screenshot occupies inside the image view — the coordinate
    /// space annotations are drawn in.
    private func displayedImageRect() -> CGRect {
        let bounds = imageView.bounds
        let size = sourceImage.size
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let displayed = CGSize(width: size.width * fit, height: size.height * fit)
        return CGRect(
            x: bounds.midX - displayed.width / 2,
            y: bounds.midY - displayed.height / 2,
            width: displayed.width,
            height: displayed.height
        )
    }
}
#endif
