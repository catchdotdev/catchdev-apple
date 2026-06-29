import UIKit
import CatchDev

/// Base class for every demo screen: a system background, a "Send feedback" button on the
/// navigation bar (so the reporter opens on whichever screen is visible), and a helper to
/// lay out a stack of centered controls.
class DemoViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        addSendFeedbackButton()
    }

    private func addSendFeedbackButton() {
        let item = UIBarButtonItem(
            title: "Send feedback",
            style: .plain,
            target: self,
            action: #selector(sendFeedbackTapped)
        )
        item.accessibilityIdentifier = "example.sendFeedback"
        navigationItem.rightBarButtonItem = item
    }

    @objc private func sendFeedbackTapped() {
        CatchDev.presentReporter()
    }

    /// Lay out a vertical stack of views centered in the screen.
    func setContent(_ views: [UIView]) {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    /// A prominent button wired to `handler`, tagged with an accessibility id for tests.
    func makeButton(title: String, identifier: String, handler: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.borderedProminent()
        config.title = title
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in handler() })
        button.accessibilityIdentifier = identifier
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// A non-interactive caption label.
    func makeLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    /// Push another demo screen onto this navigation stack.
    func push(_ viewController: UIViewController) {
        navigationController?.pushViewController(viewController, animated: true)
    }
}
