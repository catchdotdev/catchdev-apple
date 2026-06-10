#if canImport(UIKit)
import UIKit
#if canImport(PencilKit)
import PencilKit
#endif

/// Navigation container for the feedback reporter. Also a marker type so the SDK
/// never presents the reporter on top of itself.
final class ReporterContainer: UINavigationController {}

/// Stable accessibility identifiers for the reporter's controls. Shared with UI tests.
public enum CatchDevReporterAccessibility {
    public static let message = "catchdev.reporter.message"
    public static let send = "catchdev.reporter.send"
    public static let cancel = "catchdev.reporter.cancel"
    public static let undo = "catchdev.reporter.undo"
    public static let clear = "catchdev.reporter.clear"
    public static let screenshot = "catchdev.reporter.screenshot"
}

/// The shake-to-report feedback sheet: an (optionally annotated) screenshot plus a
/// message field. Built in UIKit so it presents identically from UIKit, SwiftUI and
/// Objective-C host apps.
final class ReporterViewController: UIViewController {

    private let screenshot: UIImage?

    /// Called when the reporter is dismissed, so the SDK can clear its present latch.
    var onClose: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let imageContainer = UIView()
    private let imageView = UIImageView()
    private let messageTextView = UITextView()
    private let placeholderLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private lazy var sendButton = UIBarButtonItem(
        title: "Send",
        style: .done,
        target: self,
        action: #selector(sendTapped)
    )

    #if canImport(PencilKit)
    private let canvasView = PKCanvasView()
    #endif

    init(screenshot: UIImage?) {
        self.screenshot = screenshot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Send feedback"

        let cancelButton = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        cancelButton.accessibilityIdentifier = CatchDevReporterAccessibility.cancel
        navigationItem.leftBarButtonItem = cancelButton

        sendButton.accessibilityIdentifier = CatchDevReporterAccessibility.send
        navigationItem.rightBarButtonItem = sendButton

        configureLayout()
        configureAnnotation()
        observeKeyboard()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || (navigationController?.isBeingDismissed ?? false) {
            onClose?()
        }
    }

    // MARK: - Layout

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        if let screenshot = screenshot {
            imageView.image = screenshot
            imageView.contentMode = .scaleAspectFit
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.isAccessibilityElement = true
            imageView.accessibilityIdentifier = CatchDevReporterAccessibility.screenshot
            imageView.accessibilityLabel = "Screenshot"

            imageContainer.translatesAutoresizingMaskIntoConstraints = false
            imageContainer.layer.cornerRadius = 8
            imageContainer.layer.borderWidth = 1
            imageContainer.layer.borderColor = UIColor.separator.cgColor
            imageContainer.clipsToBounds = true
            imageContainer.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
                imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            ])

            // Keep the screenshot's aspect ratio, but cap the height so a tall phone
            // screenshot doesn't dominate the sheet and bury the message field.
            let ratio = screenshot.size.height / max(screenshot.size.width, 1)
            let aspect = imageContainer.heightAnchor
                .constraint(equalTo: imageContainer.widthAnchor, multiplier: ratio)
            aspect.priority = .defaultHigh
            aspect.isActive = true
            imageContainer.heightAnchor
                .constraint(lessThanOrEqualToConstant: 360)
                .isActive = true

            contentStack.addArrangedSubview(imageContainer)
            contentStack.addArrangedSubview(
                makeHintLabel("Draw on the screenshot to highlight the problem.")
            )
        }

        messageTextView.font = .preferredFont(forTextStyle: .body)
        messageTextView.layer.cornerRadius = 8
        messageTextView.layer.borderWidth = 1
        messageTextView.layer.borderColor = UIColor.separator.cgColor
        messageTextView.translatesAutoresizingMaskIntoConstraints = false
        messageTextView.delegate = self
        messageTextView.accessibilityIdentifier = CatchDevReporterAccessibility.message
        messageTextView.accessibilityLabel = "Feedback message"
        messageTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        contentStack.addArrangedSubview(messageTextView)

        placeholderLabel.text = "Tell us what happened…"
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        messageTextView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: messageTextView.topAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: messageTextView.leadingAnchor, constant: 5),
        ])
    }

    private func makeHintLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }

    private func configureAnnotation() {
        guard screenshot != nil else { return }
        #if canImport(PencilKit)
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: .systemRed, width: 6)
        imageContainer.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
        ])

        let undo = UIBarButtonItem(
            image: UIImage(systemName: "arrow.uturn.backward"),
            style: .plain,
            target: self,
            action: #selector(undoTapped)
        )
        let clear = UIBarButtonItem(
            image: UIImage(systemName: "trash"),
            style: .plain,
            target: self,
            action: #selector(clearTapped)
        )
        undo.accessibilityIdentifier = CatchDevReporterAccessibility.undo
        undo.accessibilityLabel = "Undo"
        clear.accessibilityIdentifier = CatchDevReporterAccessibility.clear
        clear.accessibilityLabel = "Clear drawing"
        navigationItem.rightBarButtonItems = [sendButton, clear, undo]
        #endif
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    #if canImport(PencilKit)
    @objc private func undoTapped() {
        canvasView.undoManager?.undo()
    }

    @objc private func clearTapped() {
        canvasView.drawing = PKDrawing()
    }
    #endif

    @objc private func sendTapped() {
        let message = (messageTextView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            shake(messageTextView)
            messageTextView.becomeFirstResponder()
            return
        }
        view.endEditing(true)
        setLoading(true)

        let imageData = composedImage()?.jpegData(compressionQuality: 0.8)
        CatchDev.shared.submit(message: message, imageData: imageData) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setLoading(false)
                switch result {
                case .success:
                    self.dismiss(animated: true)
                case .failure(let error):
                    self.presentSendError(error)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Flatten the displayed screenshot and any annotation into a single image.
    private func composedImage() -> UIImage? {
        guard screenshot != nil else { return nil }
        let bounds = imageContainer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return screenshot }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in
            imageContainer.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    private func setLoading(_ loading: Bool) {
        sendButton.isEnabled = !loading
        navigationItem.leftBarButtonItem?.isEnabled = !loading
        messageTextView.isEditable = !loading
        if loading {
            activityIndicator.startAnimating()
            navigationItem.titleView = activityIndicator
        } else {
            activityIndicator.stopAnimating()
            navigationItem.titleView = nil
        }
    }

    private func presentSendError(_ error: Error) {
        let message: String
        switch error {
        case CatchDevError.transport:
            message = "Couldn’t reach the server. Check your connection and try again."
        case CatchDevError.server(let status) where status == 401 || status == 403:
            message = "Feedback isn’t set up correctly for this app. Please contact the developer."
        default:
            message = "Something went wrong. Please try again."
        }
        let alert = UIAlertController(
            title: "Couldn’t send feedback",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func shake(_ target: UIView) {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [-8, 8, -6, 6, -3, 3, 0]
        animation.duration = 0.4
        target.layer.add(animation, forKey: "cdv.shake")
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let overlap = view.bounds.maxY - view.convert(frame, from: nil).minY
        scrollView.contentInset.bottom = max(0, overlap)
        scrollView.verticalScrollIndicatorInsets.bottom = max(0, overlap)
    }

    @objc private func keyboardWillHide() {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }
}

extension ReporterViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
    }
}
#endif
