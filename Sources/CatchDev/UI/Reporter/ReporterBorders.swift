#if canImport(UIKit)
import ObjectiveC.runtime
import UIKit

private var cdvBorderColorKey: UInt8 = 0

extension UIView {
    /// Set a border whose colour survives a light↔dark switch.
    ///
    /// `CALayer.borderColor` is a `CGColor` — a **snapshot** of a dynamic `UIColor`, resolved
    /// against whatever traits were current when it was assigned. CALayer never re-resolves it,
    /// so `layer.borderColor = ReporterTheme.border.cgColor` leaves a stale (light) border
    /// behind if the user flips appearance while the reporter is open. Backgrounds and text
    /// colours don't have this problem — they hold the `UIColor` itself — which is why the
    /// borders were the only thing left behind.
    ///
    /// This keeps the `UIColor` on the view so ``cdvRefreshBorders(with:)`` can re-resolve it.
    func cdvSetBorder(_ color: UIColor, width: CGFloat = 1) {
        objc_setAssociatedObject(self, &cdvBorderColorKey, color, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        layer.borderWidth = width
        layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }

    /// Re-resolve every ``cdvSetBorder(_:width:)`` colour in this view's subtree against `traits`.
    ///
    /// **The traits must be passed in, not read from each view.** UIKit updates a trait
    /// environment's `traitCollection` and calls its `traitCollectionDidChange` before it has
    /// propagated the change down the subtree: at the instant the view controller is told the
    /// appearance changed, `viewController.traitCollection` is already dark while
    /// `viewController.view` — and every view under it — still reports the OLD style. A refresh
    /// that resolved against each view's own `traitCollection` (as this used to) therefore
    /// re-wrote every border with the colour of the appearance the user had just *left*, in both
    /// directions: the fix was a no-op and the stale light border survived on a dark page.
    ///
    /// So the caller hands down the trait collection of the environment that has already been
    /// updated — the view controller's own — and every border resolves against that.
    func cdvRefreshBorders(with traits: UITraitCollection) {
        if let color = objc_getAssociatedObject(self, &cdvBorderColorKey) as? UIColor {
            layer.borderColor = color.resolvedColor(with: traits).cgColor
        }
        subviews.forEach { $0.cdvRefreshBorders(with: traits) }
    }

    /// The colour a border was last resolved to, for tests.
    var cdvBorderColor: CGColor? { layer.borderColor }
}

/// Test seam for the app-hosted unit tests: the package's own `swift test` target is
/// Foundation-only (macOS) and cannot see UIKit, so the border refresh — whose whole bug was
/// *which trait collection it resolves against* — is only reachable from the example app's
/// unit tests.
@_spi(CatchDevTesting)
public enum CatchDevBorderTesting {
    /// Give `view` the reporter's standard border, resolved against its current traits.
    public static func setBorder(on view: UIView) {
        view.cdvSetBorder(ReporterTheme.border)
    }

    /// Refresh the subtree's borders the way ``ReporterViewController`` does on an appearance
    /// change: against the traits of the environment that has already been updated.
    public static func refreshBorders(in view: UIView, style: UIUserInterfaceStyle) {
        view.cdvRefreshBorders(with: UITraitCollection(userInterfaceStyle: style))
    }

    /// The reporter's border colour for a given appearance — what a correctly refreshed border
    /// must equal.
    public static func expectedBorderColor(style: UIUserInterfaceStyle) -> CGColor {
        ReporterTheme.border.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).cgColor
    }

    /// The colour actually on the layer right now.
    public static func borderColor(of view: UIView) -> CGColor? { view.cdvBorderColor }
}
#endif
