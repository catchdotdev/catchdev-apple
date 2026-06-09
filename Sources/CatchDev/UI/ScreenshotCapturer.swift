#if canImport(UIKit)
import UIKit

/// Captures the current on-screen content of the active window as a `UIImage`.
/// Called at shake time, before the reporter is presented, so the reporter UI is
/// not part of the screenshot.
enum ScreenshotCapturer {
    static func capture() -> UIImage? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windowScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard
            let window = windowScene?.windows.first(where: { $0.isKeyWindow })
                ?? windowScene?.windows.first
        else { return nil }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}
#endif
