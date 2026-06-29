#if canImport(UIKit)
import UIKit

/// Adopt this on a `UIViewController` to give the SDK an explicit, stable screen name
/// for breadcrumbs and the current-screen field — useful when a controller's `title` is
/// empty or its class name isn't meaningful (e.g. a generic hosting controller).
///
/// ```swift
/// extension CheckoutViewController: CatchDevScreenNaming {
///     var catchdevScreenName: String? { "Checkout" }
/// }
/// ```
public protocol CatchDevScreenNaming {
    /// The name to report for this screen, or `nil` to fall back to the default.
    var catchdevScreenName: String? { get }
}

/// Resolves a stable, human-readable screen name for a view controller. Single source
/// of truth shared by the breadcrumb tracker and the current-screen capture.
@_spi(CatchDevTesting)
public enum ScreenName {
    /// Resolution order: `CatchDevScreenNaming` override → `title` → unqualified class name.
    /// Whitespace-only overrides/titles are treated as empty so they fall through to a
    /// meaningful name rather than reporting a blank screen.
    @_spi(CatchDevTesting)
    public static func resolve(_ viewController: UIViewController) -> String {
        if let custom = (viewController as? CatchDevScreenNaming)?.catchdevScreenName,
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        if let title = viewController.title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return String(describing: type(of: viewController))
    }
}
#endif
