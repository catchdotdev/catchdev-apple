import UIKit

/// Three tabs, each a navigation stack, so the UI tests can traverse a non-trivial path
/// (push within a tab, switch tabs) and verify the resulting breadcrumb trail.
///
/// ```
/// Home     → Home → Product Detail → Reviews
/// Explore  → Explore → Category
/// Settings → Settings → Account
/// ```
final class RootTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let home = UINavigationController(rootViewController: HomeViewController())
        home.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house"), tag: 0)

        let explore = UINavigationController(rootViewController: ExploreViewController())
        explore.tabBarItem = UITabBarItem(
            title: "Explore", image: UIImage(systemName: "magnifyingglass"), tag: 1
        )

        let settings = UINavigationController(rootViewController: SettingsViewController())
        settings.tabBarItem = UITabBarItem(
            title: "Settings", image: UIImage(systemName: "gearshape"), tag: 2
        )

        viewControllers = [home, explore, settings]
    }
}
