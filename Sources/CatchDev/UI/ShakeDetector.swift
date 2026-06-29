#if canImport(UIKit)
import UIKit

/// Detects a device shake anywhere in the host app by swizzling
/// `UIWindow.motionEnded(_:with:)`. Installed once from ``CatchDev/start(apiKey:)``.
@_spi(CatchDevTesting)
public final class ShakeDetector {
    @_spi(CatchDevTesting)
    public static let shared = ShakeDetector()

    @_spi(CatchDevTesting)
    public var isEnabled = true
    @_spi(CatchDevTesting)
    public var onShake: (() -> Void)?

    private var installed = false
    private init() {}

    @_spi(CatchDevTesting)
    public func install() {
        guard !installed else { return }
        installed = true
        UIWindow.cdv_installShakeSwizzle()
    }

    @_spi(CatchDevTesting)
    public func handleShake() {
        guard isEnabled else { return }
        onShake?()
    }
}

private extension UIWindow {
    /// Canonical "add-or-exchange" swizzle so only `UIWindow` is affected and the
    /// original `motionEnded` behaviour is preserved.
    static func cdv_installShakeSwizzle() {
        let originalSelector = #selector(UIResponder.motionEnded(_:with:))
        let swizzledSelector = #selector(UIWindow.cdv_motionEnded(_:with:))
        guard
            let originalMethod = class_getInstanceMethod(UIWindow.self, originalSelector),
            let swizzledMethod = class_getInstanceMethod(UIWindow.self, swizzledSelector)
        else { return }

        let didAddMethod = class_addMethod(
            UIWindow.self,
            originalSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )
        if didAddMethod {
            class_replaceMethod(
                UIWindow.self,
                swizzledSelector,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    @objc func cdv_motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            ShakeDetector.shared.handleShake()
        }
        // After swizzling, this selector points at the original implementation.
        cdv_motionEnded(motion, with: event)
    }
}
#endif
