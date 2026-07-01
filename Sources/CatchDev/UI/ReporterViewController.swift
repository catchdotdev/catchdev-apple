#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

/// Navigation container for the feedback reporter. Also a marker type so the SDK never
/// presents the reporter on top of itself. The reporter draws its own top bar, so the
/// navigation bar is hidden.
final class ReporterContainer: UINavigationController {}

/// The shake-to-report sheet: report-type tabs, a description, optional severity/area,
/// multiple attachments (screenshot/recording/file) with annotation, an auto-attached
/// diagnostics disclosure, and a sticky Send. Built in UIKit so it presents identically
/// from UIKit, SwiftUI and Objective-C hosts.
final class ReporterViewController: UIViewController {
    /// State preserved across the Record flow's dismiss → record → re-present round-trip.
    /// Consumed by ``CatchDev/presentReporter()`` so a recording resumes the same draft.
    static var pendingRestore: ReporterRestoreState?

    static func consumePendingRestore() -> ReporterRestoreState? {
        defer { pendingRestore = nil }
        return pendingRestore
    }

    private let originalScreenshot: UIImage?
    private let screenName: String?
    private let restoreState: ReporterRestoreState?
    private var reportId: String

    var onClose: (() -> Void)?
    private var closeNotified = false

    // Form state
    private var reportType: ReportType = .feedback
    private var drafts: [String: String] = [:]
    private var severity: Severity?
    private var area: String?
    private var attachments: [PendingAttachment] = []
    private var excluded: Set<DiagnosticID> = []

    // Views
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let tabsView = SegmentedTabsView()
    private let descriptionTextView = UITextView()
    private let placeholderLabel = UILabel()
    private let titlePreviewLabel = UILabel()
    private let severityView = SeverityView()
    private var severitySection: UIView!
    private let areaDropdown = AreaDropdownView()
    private let attachmentsView = AttachmentsView()
    private let contactField = UITextField()
    private let footerView = UIView()
    private let sendButton = UIButton(type: .system)

    private var sendingOverlay: UIView?

    init(screenshot: UIImage?, screenName: String? = nil) {
        self.originalScreenshot = screenshot
        self.screenName = screenName
        self.restoreState = nil
        self.reportId = UUID().uuidString.lowercased()
        super.init(nibName: nil, bundle: nil)
    }

    init(restoring state: ReporterRestoreState) {
        self.originalScreenshot = state.attachments.first(where: { $0.kind == .screenshot })?.thumbnail
        self.screenName = state.screenName
        self.restoreState = state
        self.reportId = state.reportId
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        notifyClose()
    }

    private func notifyClose() {
        guard !closeNotified else { return }
        closeNotified = true
        onClose?()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.setNavigationBarHidden(true, animated: false)
        view.backgroundColor = ReporterTheme.bg

        buildTopBar()
        buildTabs()
        buildBody()
        buildFooter()
        observeKeyboard()

        if let restoreState {
            apply(restoreState)
        } else if let screenshot = originalScreenshot {
            seedScreenshot(screenshot)
        }
        refreshForTab(animated: false)
        refreshAttachments()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || (navigationController?.isBeingDismissed ?? false) {
            notifyClose()
        }
    }

    // MARK: - Build UI

    private func buildTopBar() {
        let title = UILabel()
        title.text = "Send report"
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = ReporterTheme.text

        let close = UIButton(type: .system)
        close.setImage(ReporterStyle.symbolImage("xmark", pointSize: 16, weight: .medium), for: .normal)
        close.tintColor = ReporterTheme.textSoft
        close.accessibilityIdentifier = CatchDevReporterAccessibility.close
        close.accessibilityLabel = "Close"
        close.setContentHuggingPriority(.required, for: .horizontal)
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        // A low-hugging spacer absorbs the slack so the close button sits at the trailing edge.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = UIStackView(arrangedSubviews: [title, spacer, close])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        topBar = bar
    }
    private var topBar: UIStackView!

    private func buildTabs() {
        tabsView.translatesAutoresizingMaskIntoConstraints = false
        tabsView.onChange = { [weak self] type in self?.switchTab(to: type) }
        view.addSubview(tabsView)
        NSLayoutConstraint.activate([
            tabsView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            tabsView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tabsView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    private func buildBody() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: tabsView.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        contentStack.addArrangedSubview(makeDescriptionSection())
        severitySection = makeSeveritySection()
        contentStack.addArrangedSubview(severitySection)
        contentStack.addArrangedSubview(makeAreaSection())
        contentStack.addArrangedSubview(makeAttachmentsSection())
        if CatchDev.isContactFieldEnabled {
            contentStack.addArrangedSubview(makeContactSection())
        }
    }

    private func makeDescriptionSection() -> UIView {
        let box = UIView()
        box.backgroundColor = ReporterTheme.fieldBg
        box.layer.cornerRadius = 13
        box.layer.borderWidth = 1
        box.layer.borderColor = ReporterTheme.border.cgColor

        descriptionTextView.backgroundColor = .clear
        descriptionTextView.font = .systemFont(ofSize: 16)
        descriptionTextView.textColor = ReporterTheme.text
        descriptionTextView.delegate = self
        descriptionTextView.translatesAutoresizingMaskIntoConstraints = false
        descriptionTextView.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        descriptionTextView.accessibilityIdentifier = CatchDevReporterAccessibility.message
        descriptionTextView.accessibilityLabel = "Description"
        box.addSubview(descriptionTextView)

        placeholderLabel.font = .systemFont(ofSize: 16)
        placeholderLabel.textColor = ReporterTheme.textFaint
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(placeholderLabel)

        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            descriptionTextView.topAnchor.constraint(equalTo: box.topAnchor),
            descriptionTextView.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            descriptionTextView.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            descriptionTextView.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            descriptionTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            placeholderLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            placeholderLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 15),
        ])

        titlePreviewLabel.font = .systemFont(ofSize: 12)
        titlePreviewLabel.textColor = ReporterTheme.textMuted
        titlePreviewLabel.accessibilityIdentifier = CatchDevReporterAccessibility.titlePreview
        titlePreviewLabel.isHidden = true

        let column = UIStackView(arrangedSubviews: [box, titlePreviewLabel])
        column.axis = .vertical
        column.spacing = 8
        return column
    }

    private func makeSeveritySection() -> UIView {
        severityView.onChange = { [weak self] value in self?.severity = value }
        let column = UIStackView(arrangedSubviews: [
            ReporterStyle.sectionLabel("How bad is this?", optional: true),
            severityView,
        ])
        column.axis = .vertical
        column.spacing = 9
        return column
    }

    private func makeAreaSection() -> UIView {
        areaDropdown.onChange = { [weak self] value in self?.area = value }
        let column = UIStackView(arrangedSubviews: [
            ReporterStyle.sectionLabel("Area", optional: true),
            areaDropdown,
        ])
        column.axis = .vertical
        column.spacing = 9
        return column
    }

    private func makeAttachmentsSection() -> UIView {
        attachmentsView.onScreenshot = { [weak self] in self?.annotatePrimaryScreenshot() }
        attachmentsView.onRecord = { [weak self] in self?.startRecording() }
        attachmentsView.onAttach = { [weak self] in self?.pickFile() }
        attachmentsView.onRemove = { [weak self] id in self?.removeAttachment(id) }
        attachmentsView.onAnnotate = { [weak self] id in self?.annotateAttachment(id) }
        let column = UIStackView(arrangedSubviews: [
            ReporterStyle.sectionLabel("Add more", optional: true),
            attachmentsView,
        ])
        column.axis = .vertical
        column.spacing = 9
        return column
    }

    private func makeContactSection() -> UIView {
        contactField.placeholder = "you@email.com"
        contactField.font = .systemFont(ofSize: 15)
        contactField.textColor = ReporterTheme.text
        contactField.backgroundColor = ReporterTheme.fieldBg
        contactField.layer.cornerRadius = 12
        contactField.layer.borderWidth = 1
        contactField.layer.borderColor = ReporterTheme.border.cgColor
        contactField.keyboardType = .emailAddress
        contactField.autocapitalizationType = .none
        contactField.autocorrectionType = .no
        contactField.accessibilityIdentifier = CatchDevReporterAccessibility.contact
        contactField.translatesAutoresizingMaskIntoConstraints = false
        contactField.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let inset = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        contactField.leftView = inset
        contactField.leftViewMode = .always

        let column = UIStackView(arrangedSubviews: [
            ReporterStyle.sectionLabel("Contact email", optional: true),
            contactField,
        ])
        column.axis = .vertical
        column.spacing = 9
        return column
    }

    private func buildFooter() {
        footerView.backgroundColor = ReporterTheme.bg
        footerView.translatesAutoresizingMaskIntoConstraints = false
        let separator = UIView()
        separator.backgroundColor = ReporterTheme.borderSoft
        separator.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.filled()
        config.title = "Send report"
        config.image = ReporterStyle.symbolImage("paperplane.fill", pointSize: 15)
        config.imagePadding = 9
        config.baseBackgroundColor = ReporterTheme.actionBg
        config.baseForegroundColor = ReporterTheme.actionFg
        config.cornerStyle = .large
        config.titleTextAttributesTransformer = .init { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 15.5, weight: .semibold)
            return out
        }
        sendButton.configuration = config
        sendButton.accessibilityIdentifier = CatchDevReporterAccessibility.send
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)

        view.addSubview(footerView)
        footerView.addSubview(separator)
        footerView.addSubview(sendButton)
        NSLayoutConstraint.activate([
            footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footerView.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separator.topAnchor.constraint(equalTo: footerView.topAnchor),
            separator.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            sendButton.topAnchor.constraint(equalTo: footerView.topAnchor, constant: 12),
            sendButton.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 16),
            sendButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -16),
            sendButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            sendButton.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    // MARK: - State sync

    private var currentDraft: String {
        get { drafts[reportType.rawValue] ?? "" }
        set { drafts[reportType.rawValue] = newValue }
    }

    private func switchTab(to type: ReportType) {
        currentDraft = descriptionTextView.text ?? ""
        reportType = type
        refreshForTab(animated: true)
    }

    private func refreshForTab(animated: Bool) {
        descriptionTextView.text = currentDraft
        placeholderLabel.text = reportType == .bug
            ? "What happened? What did you expect?"
            : "What would make this better?"
        placeholderLabel.isHidden = !currentDraft.isEmpty
        updateTitlePreview()
        tabsView.setSelected(reportType, animated: animated)
        let show = reportType == .bug
        UIView.animate(withDuration: animated ? 0.2 : 0) {
            self.severitySection.isHidden = !show
        }
    }

    private func updateTitlePreview() {
        let title = Self.deriveTitle(descriptionTextView.text ?? "")
        if let title {
            titlePreviewLabel.text = "TITLE  “\(title)” · auto"
            titlePreviewLabel.isHidden = false
        } else {
            titlePreviewLabel.isHidden = true
        }
    }

    static func deriveTitle(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard trimmed.count >= 6 else { return nil }
        let words = trimmed.split(separator: " ")
        let head = words.prefix(7).joined(separator: " ")
        let capitalized = head.prefix(1).uppercased() + head.dropFirst()
        return capitalized + (words.count > 7 ? "…" : "")
    }

    private func refreshAttachments() {
        attachmentsView.setAttachments(attachments)
    }

    // MARK: - Attachments

    private func seedScreenshot(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        attachments.append(PendingAttachment(
            kind: .screenshot, data: data, contentType: "image/jpeg",
            filename: "screenshot.jpg", annotated: false, thumbnail: image
        ))
    }

    private func annotatePrimaryScreenshot() {
        if let index = attachments.firstIndex(where: { $0.kind == .screenshot }) {
            annotate(at: index)
        } else if let original = originalScreenshot {
            seedScreenshot(original)
            refreshAttachments()
            if let index = attachments.firstIndex(where: { $0.kind == .screenshot }) { annotate(at: index) }
        }
    }

    private func annotateAttachment(_ id: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }),
              attachments[index].kind == .screenshot else { return }
        annotate(at: index)
    }

    private func annotate(at index: Int) {
        let image = attachments[index].thumbnail ?? UIImage()
        let annotator = AnnotateViewController(image: image, onDone: { [weak self] flattened in
            guard let self else { return }
            self.dismiss(animated: true)
            if let data = flattened.jpegData(compressionQuality: 0.8) {
                self.attachments[index].data = data
                self.attachments[index].thumbnail = flattened
                self.attachments[index].annotated = true
                self.refreshAttachments()
            }
        }, onCancel: { [weak self] in self?.dismiss(animated: true) })
        present(annotator, animated: true)
    }

    private func removeAttachment(_ id: String) {
        attachments.removeAll { $0.id == id }
        refreshAttachments()
    }

    private func pickFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    // MARK: - Send

    private func send() {
        let message = (descriptionTextView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            shake(descriptionTextView)
            descriptionTextView.becomeFirstResponder()
            return
        }
        view.endEditing(true)
        let contact = CatchDev.isContactFieldEnabled ? contactField.text : nil
        let pending = attachments

        let overlay = SendingOverlayView(steps: [
            "Bundling breadcrumbs", "Attaching context", "Uploading attachments", "Posting to Catch",
        ])
        showOverlay(overlay)

        uploadAll(pending, uploaded: []) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.hideOverlay()
                    self.presentError(error)
                }
            case .success(let uploaded):
                CatchDev.shared.submit(
                    message: message,
                    imageData: nil,
                    type: self.reportType,
                    severity: self.reportType == .bug ? self.severity : nil,
                    area: self.area,
                    contactEmail: contact,
                    attachments: uploaded,
                    reportId: self.reportId,
                    screenName: self.screenName,
                    excludedDiagnostics: self.excluded
                ) { submitResult in
                    DispatchQueue.main.async {
                        switch submitResult {
                        case .success(let id):
                            self.showSuccess(reportId: id.isEmpty ? self.reportId : id)
                        case .failure(let error):
                            self.hideOverlay()
                            self.presentError(error)
                        }
                    }
                }
            }
        }
    }

    /// Upload pending attachments one at a time, collecting their references.
    private func uploadAll(
        _ remaining: [PendingAttachment],
        uploaded: [Attachment],
        completion: @escaping (Result<[Attachment], Error>) -> Void
    ) {
        guard let next = remaining.first else { completion(.success(uploaded)); return }
        CatchDev.shared.uploadAttachment(
            data: next.data, kind: next.kind, contentType: next.contentType,
            filename: next.filename, annotated: next.annotated
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let attachment):
                self.uploadAll(Array(remaining.dropFirst()), uploaded: uploaded + [attachment], completion: completion)
            }
        }
    }

    private func showSuccess(reportId: String) {
        let success = SuccessOverlayView(type: reportType, reportId: reportId)
        success.onDone = { [weak self] in self?.dismiss(animated: true) }
        showOverlay(success)
    }

    private func showOverlay(_ overlay: UIView) {
        sendingOverlay?.removeFromSuperview()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        sendingOverlay = overlay
    }

    private func hideOverlay() {
        sendingOverlay?.removeFromSuperview()
        sendingOverlay = nil
    }

    private func presentError(_ error: Error) {
        let message: String
        switch error {
        case CatchDevError.transport:
            message = "Couldn’t reach the server. Check your connection and try again."
        case CatchDevError.server(let status) where status == 401 || status == 403:
            message = "Feedback isn’t set up correctly for this app. Please contact the developer."
        default:
            message = "Something went wrong. Please try again."
        }
        let alert = UIAlertController(title: "Couldn’t send report", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Record

    private func startRecording() {
        currentDraft = descriptionTextView.text ?? ""
        ReporterViewController.pendingRestore = ReporterRestoreState(
            drafts: drafts, tab: reportType, severity: severity, area: area,
            contact: contactField.text ?? "", excluded: excluded,
            attachments: attachments, screenName: screenName, reportId: reportId
        )
        // Only tear the reporter down once recording is actually rolling. If it can't start
        // (Simulator, denied permission, ReplayKit error), keep the reporter up and tell the
        // user — never leave them dismissed-but-frozen. The reporter deallocates on dismiss,
        // so the recording flow is owned by a surviving singleton.
        ReporterRecordingSession.shared.begin(
            onStarted: { [weak self] in self?.dismiss(animated: true) },
            onUnavailable: { [weak self] in
                ReporterViewController.pendingRestore = nil
                self?.presentRecordingUnavailable()
            }
        )
    }

    private func presentRecordingUnavailable() {
        let alert = UIAlertController(
            title: "Recording unavailable",
            message: "Screen recording isn’t available on this device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func apply(_ state: ReporterRestoreState) {
        drafts = state.drafts
        reportType = state.tab
        severity = state.severity
        area = state.area
        attachments = state.attachments
        excluded = state.excluded
        contactField.text = state.contact
        severityView.setSelected(state.severity)
        areaDropdown.setSelected(state.area)
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = view.bounds.maxY - view.convert(frame, from: nil).minY
        scrollView.contentInset.bottom = max(0, overlap - footerView.bounds.height)
        scrollView.verticalScrollIndicatorInsets.bottom = max(0, overlap)
    }

    @objc private func keyboardWillHide() {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }

    private func shake(_ target: UIView) {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [-8, 8, -6, 6, -3, 3, 0]
        animation.duration = 0.4
        target.layer.add(animation, forKey: "cdv.shake")
    }
}

extension ReporterViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
        updateTitlePreview()
    }
}

extension ReporterViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        attachments.append(PendingAttachment(
            kind: .file, data: data, contentType: contentType, filename: url.lastPathComponent
        ))
        refreshAttachments()
    }
}
#endif
