#if canImport(UIKit)
import UIKit

extension UIApplication {
    /// The top-most presented view controller in the active foreground scene,
    /// used as the presenter for the feedback reporter.
    @_spi(CatchDevTesting)
    public static func cdv_topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windowScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let keyWindow = windowScene?.windows.first { $0.isKeyWindow } ?? windowScene?.windows.first
        return cdv_topViewController(from: keyWindow?.rootViewController)
    }

    /// Walk down from `root` to the visible content controller, fully descending through
    /// nested containers (e.g. a tab bar whose selected tab is a navigation stack). Split
    /// out from window discovery so the unwrap logic is deterministically unit-testable.
    @_spi(CatchDevTesting)
    public static func cdv_topViewController(from root: UIViewController?) -> UIViewController? {
        var top = root
        // Cap the descent: each step moves to a distinct child in any real (acyclic) UIKit
        // hierarchy, but a misbehaving custom container could otherwise spin forever.
        var remaining = 100
        while let current = top, remaining > 0 {
            remaining -= 1
            // Stop at a presentation that is mid-dismissal: the controller above it is on
            // its way out and presenting from it would be rejected by UIKit.
            if let presented = current.presentedViewController, !presented.isBeingDismissed {
                top = presented
            } else if let navigation = current as? UINavigationController,
                      let visible = navigation.visibleViewController {
                top = visible
            } else if let tab = current as? UITabBarController,
                      let selected = tab.selectedViewController {
                top = selected
            } else {
                break
            }
        }
        return top
    }
}
#endif
