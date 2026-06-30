#if canImport(UIKit)
import UIKit

/// Records the screens a user visits by swizzling `UIViewController.viewDidAppear(_:)`.
/// Installed once from ``CatchDev/start(apiKey:)``. Container controllers and the SDK's
/// own reporter are filtered out, so the trail reflects host content screens only.
@_spi(CatchDevTesting)
public final class ViewControllerTracker {
    @_spi(CatchDevTesting)
    public static let shared = ViewControllerTracker()

    /// Invoked on the main thread when a non-ignored content controller appears.
    @_spi(CatchDevTesting)
    public var onAppear: ((UIViewController) -> Void)?

    private var installed = false
    private init() {}

    @_spi(CatchDevTesting)
    public func install() {
        guard !installed else { return }
        installed = true
        UIViewController.cdv_installAppearSwizzle()
    }

    @_spi(CatchDevTesting)
    public func handleAppear(_ viewController: UIViewController) {
        guard !Self.isIgnored(viewController) else { return }
        onAppear?(viewController)
    }

    /// Container controllers forward to a content child that fires its own
    /// `viewDidAppear`, so recording them would double-count; the SDK's reporter must
    /// never appear in its own trail; and framework-internal controllers (the keyboard's
    /// `UIPredictionViewController`, input/host windows, system alerts) are noise — the
    /// trail should reflect the host app's own screens.
    private static func isIgnored(_ viewController: UIViewController) -> Bool {
        if viewController is UINavigationController
            || viewController is UITabBarController
            || viewController is UISplitViewController
            || viewController is UIPageViewController {
            return true
        }
        if viewController is ReporterViewController
            || viewController is ReporterContainer
            || viewController is AnnotateViewController {
            return true
        }
        if isSystemController(viewController) {
            return true
        }
        return false
    }

    /// True for controllers whose class is defined in UIKit itself or another OS bundle —
    /// i.e. not authored by the host app or an embedded framework.
    private static func isSystemController(_ viewController: UIViewController) -> Bool {
        let bundle = Bundle(for: type(of: viewController))
        if bundle == Bundle(for: UIViewController.self) { return true } // UIKitCore
        let path = bundle.bundlePath
        return path.hasPrefix("/System/") || path.hasPrefix("/Library/") || path.hasPrefix("/usr/")
    }
}

private extension UIViewController {
    /// Canonical "add-or-exchange" swizzle so the original `viewDidAppear` behaviour is
    /// preserved (mirrors `UIWindow.cdv_installShakeSwizzle`).
    static func cdv_installAppearSwizzle() {
        let originalSelector = #selector(UIViewController.viewDidAppear(_:))
        let swizzledSelector = #selector(UIViewController.cdv_viewDidAppear(_:))
        guard
            let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector),
            let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzledSelector)
        else { return }

        let didAddMethod = class_addMethod(
            UIViewController.self,
            originalSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )
        if didAddMethod {
            class_replaceMethod(
                UIViewController.self,
                swizzledSelector,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    @objc func cdv_viewDidAppear(_ animated: Bool) {
        ViewControllerTracker.shared.handleAppear(self)
        // After swizzling, this selector points at the original implementation.
        cdv_viewDidAppear(animated)
    }
}
#endif
