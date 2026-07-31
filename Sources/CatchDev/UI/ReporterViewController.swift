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
    private var isStartingRecording = false
    // Snapshot the global toggle once per presentation so `buildBody` (shows the field) and
    // `send` (reads it) always agree, even if a host flips the flag while the reporter is up.
    private let contactFieldEnabled = CatchDev.isContactFieldEnabled
    // Snapshotted for the same reason: `buildBody` decides whether the Area field exists, and
    // `presentAreaPicker` fills the wheel. A host mutating the list mid-presentation must not
    // leave a field whose picker has nothing in it.
    private let areas = CatchDev.areas

    // Views
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let tabsView = SegmentedTabsView()
    private let descriptionTextView = UITextView()
    private let placeholderLabel = UILabel()
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

    /// Borders are `CGColor` snapshots of dynamic colours (see ``UIView/cdvSetBorder(_:width:)``),
    /// so they are the one thing that does NOT follow a light↔dark switch made while the
    /// reporter is open. Re-resolve them; every other colour updates itself.
    ///
    /// Resolved against **this view controller's** traits, never the subviews' own: when this
    /// callback fires, UIKit has updated the VC's `traitCollection` but not yet the view subtree's
    /// (they still report the appearance the user just left), so a per-view refresh writes the
    /// stale colour straight back — see ``UIView/cdvRefreshBorders(with:)``.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previous) else { return }
        view.cdvRefreshBorders(with: traitCollection)
        // Belt and braces: resolve once more after the current run-loop turn, when EVERY trait
        // environment in the hierarchy has settled on the new appearance. It makes the refresh
        // independent of who UIKit updates first (the pass above assumes the VC — which is what
        // it observably does), and it is ~30 layer writes with nothing else to do.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.cdvRefreshBorders(with: self.traitCollection)
        }
    }

    /// The reporter can be built (and its borders first resolved) before it is in a window — and
    /// a detached view inherits whatever traits happened to be current, not the window's. Resolve
    /// them once more now that the hierarchy is real, so a reporter opened in dark mode never
    /// shows a light border.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.cdvRefreshBorders(with: traitCollection)
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
        // A host that supplies no areas gets no Area field — an empty picker is worse than none.
        if !areas.isEmpty {
            contentStack.addArrangedSubview(makeAreaSection())
        }
        contentStack.addArrangedSubview(makeAttachmentsSection())
        if contactFieldEnabled {
            contentStack.addArrangedSubview(makeContactSection())
        }
    }

    private func makeDescriptionSection() -> UIView {
        let box = UIView()
        box.backgroundColor = ReporterTheme.fieldBg
        box.layer.cornerRadius = 13
        box.cdvSetBorder(ReporterTheme.border)

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

        return box
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
        areaDropdown.onOpen = { [weak self] in self?.presentAreaPicker() }
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
        contactField.cdvSetBorder(ReporterTheme.border)
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
        tabsView.setSelected(reportType, animated: animated)
        let show = reportType == .bug
        UIView.animate(withDuration: animated ? 0.2 : 0) {
            self.severitySection.isHidden = !show
        }
    }

    private func presentAreaPicker() {
        descriptionTextView.resignFirstResponder()
        let picker = AreaPickerSheetViewController(
            areas: areas,
            selected: areaDropdown.selected,
            bottomInset: view.safeAreaInsets.bottom
        ) { [weak self] area in
            self?.areaDropdown.choose(area)
        }
        present(picker, animated: true)
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
        let contact = contactFieldEnabled ? contactField.text : nil
        // Hand the RAW bytes to the SDK: it persists the report + these blobs to the durable
        // outbox BEFORE any network call, then uploads and posts. Uploading here first would
        // fail offline before anything was saved — which is exactly the bug this replaces.
        let pending = attachments.map {
            PendingBlob(
                kind: $0.kind, data: $0.data, contentType: $0.contentType,
                filename: $0.filename, annotated: $0.annotated
            )
        }

        let overlay = SendingOverlayView(steps: [
            "Bundling breadcrumbs", "Attaching context", "Uploading attachments", "Posting to Catch",
        ])
        showOverlay(overlay)

        // `submit` persists the report and every attachment's bytes to disk SYNCHRONOUSLY, on the
        // thread that calls it, before it returns — that is what makes a submission survive the
        // process dying (see the persist comment in `CatchDev.submit`). A screen recording is
        // 25–40 MB, so that write must not happen on the main thread: run it on a background
        // queue and come back to main for the UI. The reporter's "Sending report…" overlay is
        // already up, so there is nothing for the user to interact with while it lands.
        //
        // Mirrors the Android reporter, which submits on its `uploadExecutor` for the same reason.
        let submitState = (
            type: reportType,
            severity: reportType == .bug ? severity : nil,
            area: area,
            screenName: screenName,
            excluded: excluded,
            reportId: reportId
        )
        // Backgrounding the app the instant you tap Send (home gesture, an incoming call) is an
        // ordinary thing to do, and iOS will suspend — later jetsam — the process part-way through
        // the write. Hold an assertion across it so the entry lands whole. Taken here, on the main
        // thread, because that is where UIApplication may be touched.
        var assertion: UIBackgroundTaskIdentifier = .invalid
        let endAssertion = {
            guard assertion != .invalid else { return }
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "dev.catch.send") {
            // Expired: iOS wants the time back. Must end it or the host app is killed.
            DispatchQueue.main.async(execute: endAssertion)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            CatchDev.shared.submit(
                message: message,
                imageData: nil,
                type: submitState.type,
                severity: submitState.severity,
                area: submitState.area,
                contactEmail: contact,
                pendingAttachments: pending,
                reportId: submitState.reportId,
                screenName: submitState.screenName,
                excludedDiagnostics: submitState.excluded
            ) { [weak self] result in
                DispatchQueue.main.async {
                    endAssertion()
                    guard let self else { return }
                    switch result {
                    case .success(.delivered(let id)):
                        self.showSuccess(reportId: id.isEmpty ? self.reportId : id, queued: false)
                    case .success(.queued(let id)):
                        // Durably saved, just not sent yet — a success, not an error. Distinguish
                        // "you're offline" from "the server was briefly unreachable" by the device's
                        // current reachability, so we don't claim offline to an online user.
                        self.showSuccess(reportId: id, queued: true, offline: CatchDev.shared.isCurrentlyOffline())
                    case .failure(let error):
                        self.hideOverlay()
                        self.presentError(error)
                    }
                }
            }
        }
    }

    private func showSuccess(reportId: String, queued: Bool, offline: Bool = false) {
        let success = SuccessOverlayView(type: reportType, reportId: reportId, queued: queued, offline: offline)
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
        // Debounce: the reporter stays up during ReplayKit's async start, so a second tap
        // could double-start the recorder (→ two Stop pills, or a lost draft when the second
        // start fails and clears pendingRestore mid-recording).
        guard !isStartingRecording else { return }
        isStartingRecording = true
        currentDraft = descriptionTextView.text ?? ""
        ReporterViewController.pendingRestore = ReporterRestoreState(
            drafts: drafts, tab: reportType, severity: severity, area: area,
            contact: contactField.text ?? "", excluded: excluded,
            attachments: attachments, screenName: screenName, reportId: reportId,
            droppedRecordingReason: nil
        )
        // Only tear the reporter down once recording is actually rolling. If it can't start
        // (Simulator, denied permission, ReplayKit error), keep the reporter up and tell the
        // user — never leave them dismissed-but-frozen. The reporter deallocates on dismiss,
        // so the recording flow is owned by a surviving singleton.
        ReporterRecordingSession.shared.begin(
            onStarted: { [weak self] in self?.dismiss(animated: true) },
            onUnavailable: { [weak self] in
                self?.isStartingRecording = false // let the user try again
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
        if let reason = state.droppedRecordingReason {
            // Surface it after the reporter is on screen, so the alert has a
            // presenter — the draft survived, only the clip was dropped.
            DispatchQueue.main.async { [weak self] in
                self?.presentAttachmentAlert(reason)
            }
        }
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
    }
}

extension ReporterViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let cap = AttachmentLimits.maxFileBytes
        let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let filename = url.lastPathComponent

        // Reject on the declared size first, so an oversized pick costs no bytes.
        let scopedForSize = url.startAccessingSecurityScopedResource()
        let declared = AttachmentLimits.declaredSize(of: url)
        if scopedForSize { url.stopAccessingSecurityScopedResource() }
        if let declared, declared > cap {
            showAttachmentTooLarge(cap: cap)
            return
        }

        // Read off the main thread and bounded: the picker allows any item, and
        // an un-materialised iCloud file blocks on a network fetch. Reading one
        // byte past the cap is what detects a file whose declared size lied.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            let data = AttachmentLimits.readCapped(url: url, limit: cap + 1)
            if scoped { url.stopAccessingSecurityScopedResource() }

            DispatchQueue.main.async {
                guard let self else { return }
                guard let data else {
                    self.showAttachmentUnreadable()
                    return
                }
                guard data.count <= cap else {
                    self.showAttachmentTooLarge(cap: cap)
                    return
                }
                self.attachments.append(PendingAttachment(
                    kind: .file, data: data, contentType: contentType, filename: filename
                ))
                self.refreshAttachments()
            }
        }
    }

    private func showAttachmentTooLarge(cap: Int) {
        presentAttachmentAlert(
            "That file is too large (max \(AttachmentLimits.humanReadable(cap)))."
        )
    }

    private func showAttachmentUnreadable() {
        presentAttachmentAlert("That file couldn’t be read. Try a different one.")
    }

    private func presentAttachmentAlert(_ message: String) {
        let alert = UIAlertController(
            title: "Couldn’t attach", message: message, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
