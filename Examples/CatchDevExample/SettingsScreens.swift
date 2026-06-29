import UIKit

final class SettingsViewController: DemoViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        setContent([
            makeLabel("Settings"),
            makeButton(title: "Open Account", identifier: "example.settings.account") { [weak self] in
                self?.push(AccountViewController())
            },
        ])
    }
}

final class AccountViewController: DemoViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Account"
        setContent([makeLabel("Account")])
    }
}
