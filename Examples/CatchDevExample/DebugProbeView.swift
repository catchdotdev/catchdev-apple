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
    }

    private let screenNameLabel = DebugProbeView.makeLabel(AccessibilityID.screenName)
    private let breadcrumbsLabel = DebugProbeView.makeLabel(AccessibilityID.breadcrumbs)
    private let messageLabel = DebugProbeView.makeLabel(AccessibilityID.message)
    private let container = UIView()

    func attach(to window: UIWindow) {
        container.isUserInteractionEnabled = false
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [screenNameLabel, breadcrumbsLabel, messageLabel])
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

    func update(screenName: String?, breadcrumbs: [String], message: String?) {
        // Keep a sentinel for empty values so the labels stay addressable in the a11y tree.
        screenNameLabel.text = screenName?.isEmpty == false ? screenName : "-"
        breadcrumbsLabel.text = breadcrumbs.isEmpty ? "-" : breadcrumbs.joined(separator: " > ")
        messageLabel.text = message?.isEmpty == false ? message : "-"
        // Keep the probe above anything else on the window when the assertion is read.
        container.superview?.bringSubviewToFront(container)
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
