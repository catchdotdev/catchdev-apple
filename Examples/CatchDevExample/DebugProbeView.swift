import UIKit

/// Surfaces the payload parsed by `MockFeedbackServer` into the accessibility tree so the
/// (out-of-process) XCUITests can assert what the SDK actually sent. Only attached under
/// `-CatchDevUITest`. The labels are transparent (clear text) so they don't visually
/// interfere with the app, but their accessibility values are still readable by XCUITest.
final class DebugProbeView {
    enum AccessibilityID {
        static let screenName = "catchdev.debug.lastScreenName"
        static let breadcrumbs = "catchdev.debug.lastBreadcrumbs"
        static let message = "catchdev.debug.lastMessage"
        static let type = "catchdev.debug.lastType"
        static let severity = "catchdev.debug.lastSeverity"
        static let area = "catchdev.debug.lastArea"
        static let contact = "catchdev.debug.lastContact"
        static let attachmentCount = "catchdev.debug.lastAttachmentCount"
        static let sessionId = "catchdev.debug.lastSessionId"
        static let mockPort = "catchdev.debug.mockPort"
        static let requestLog = "catchdev.debug.requestLog"
    }

    private let screenNameLabel = DebugProbeView.makeLabel(AccessibilityID.screenName)
    private let breadcrumbsLabel = DebugProbeView.makeLabel(AccessibilityID.breadcrumbs)
    private let messageLabel = DebugProbeView.makeLabel(AccessibilityID.message)
    private let typeLabel = DebugProbeView.makeLabel(AccessibilityID.type)
    private let severityLabel = DebugProbeView.makeLabel(AccessibilityID.severity)
    private let areaLabel = DebugProbeView.makeLabel(AccessibilityID.area)
    private let contactLabel = DebugProbeView.makeLabel(AccessibilityID.contact)
    private let attachmentCountLabel = DebugProbeView.makeLabel(AccessibilityID.attachmentCount)
    private let sessionIdLabel = DebugProbeView.makeLabel(AccessibilityID.sessionId)
    private let mockPortLabel = DebugProbeView.makeLabel(AccessibilityID.mockPort)
    private let requestLogLabel = DebugProbeView.makeLabel(AccessibilityID.requestLog)
    private var requestCount = 0
    private let container = UIView()

    func attach(to window: UIWindow) {
        container.isUserInteractionEnabled = false
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            screenNameLabel, breadcrumbsLabel, messageLabel, typeLabel, severityLabel,
            areaLabel, contactLabel, attachmentCountLabel, sessionIdLabel,
            mockPortLabel, requestLogLabel,
        ])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        window.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func update(_ received: MockFeedbackServer.ReceivedRequest) {
        // Keep a sentinel for empty values so the labels stay addressable in the a11y tree.
        screenNameLabel.text = nonEmpty(received.screenName)
        breadcrumbsLabel.text = received.breadcrumbs.isEmpty ? "-" : received.breadcrumbs.joined(separator: " > ")
        messageLabel.text = nonEmpty(received.message)
        typeLabel.text = nonEmpty(received.type)
        severityLabel.text = nonEmpty(received.severity)
        areaLabel.text = nonEmpty(received.area)
        contactLabel.text = nonEmpty(received.email)
        attachmentCountLabel.text = String(received.attachmentCount)
        sessionIdLabel.text = nonEmpty(received.sessionId)
        container.superview?.bringSubviewToFront(container)
    }

    func setMockPort(_ port: UInt16) {
        mockPortLabel.text = String(port)
    }

    func noteRequest(method: String, path: String) {
        requestCount += 1
        requestLogLabel.text = "\(requestCount) last=\(method) \(path)"
        container.superview?.bringSubviewToFront(container)
    }

    private func nonEmpty(_ value: String?) -> String {
        value?.isEmpty == false ? value! : "-"
    }

    private static func makeLabel(_ identifier: String) -> UILabel {
        let label = UILabel()
        label.text = "-"
        label.font = .systemFont(ofSize: 8)
        label.textColor = .clear
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
