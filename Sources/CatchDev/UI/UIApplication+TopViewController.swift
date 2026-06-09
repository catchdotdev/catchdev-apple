#if canImport(UIKit)
import UIKit

extension UIApplication {
    /// The top-most presented view controller in the active foreground scene,
    /// used as the presenter for the feedback reporter.
    static func cdv_topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windowScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let keyWindow = windowScene?.windows.first { $0.isKeyWindow } ?? windowScene?.windows.first

        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        if let navigation = top as? UINavigationController {
            top = navigation.visibleViewController ?? navigation
        }
        if let tab = top as? UITabBarController {
            top = tab.selectedViewController ?? tab
        }
        return top
    }
}
#endif
