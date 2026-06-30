#if canImport(UIKit)
import UIKit

extension UIColor {
    /// Build a color from a 6-digit hex string (e.g. `"09090b"`).
    fileprivate convenience init(cdvHex hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: CGFloat((value & 0xFF0000) >> 16) / 255,
            green: CGFloat((value & 0x00FF00) >> 8) / 255,
            blue: CGFloat(value & 0x0000FF) / 255,
            alpha: 1
        )
    }

    /// A dynamic color that resolves to `light` or `dark` per the trait collection, so the
    /// reporter follows the system appearance automatically.
    fileprivate static func cdvDynamic(light: String, dark: String) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(cdvHex: dark)
                : UIColor(cdvHex: light)
        }
    }
}

/// The reporter's zinc/neutral design tokens, mirroring the `Shake Report` design's
/// light + dark palettes. All colors are dynamic, so a single value adapts to the system
/// appearance with no per-view branching.
enum ReporterTheme {
    static let bg = UIColor.cdvDynamic(light: "ffffff", dark: "09090b")
    static let elevated = UIColor.cdvDynamic(light: "fafafa", dark: "131316")
    static let mutedBg = UIColor.cdvDynamic(light: "f4f4f5", dark: "1c1c20")
    static let border = UIColor.cdvDynamic(light: "e4e4e7", dark: "27272a")
    static let borderSoft = UIColor.cdvDynamic(light: "f1f1f3", dark: "1c1c20")
    static let text = UIColor.cdvDynamic(light: "09090b", dark: "fafafa")
    static let textSoft = UIColor.cdvDynamic(light: "3f3f46", dark: "d4d4d8")
    static let textMuted = UIColor.cdvDynamic(light: "71717a", dark: "a1a1aa")
    static let textFaint = UIColor.cdvDynamic(light: "a1a1aa", dark: "71717a")
    static let fieldBg = UIColor.cdvDynamic(light: "fafafa", dark: "131316")
    static let actionBg = UIColor.cdvDynamic(light: "09090b", dark: "fafafa")
    static let actionFg = UIColor.cdvDynamic(light: "fafafa", dark: "09090b")

    static let feedbackAccent = UIColor.cdvDynamic(light: "6366f1", dark: "818cf8")
    static let feedbackAccentBg = UIColor.cdvDynamic(light: "eef2ff", dark: "1e1b4b")
    static let bugAccent = UIColor.cdvDynamic(light: "16a34a", dark: "4ade80")
    static let bugAccentBg = UIColor.cdvDynamic(light: "f0fdf4", dark: "052e16")

    /// Accent color for the active report type.
    static func accent(for type: ReportType) -> UIColor {
        type == .bug ? bugAccent : feedbackAccent
    }

    static func accentBg(for type: ReportType) -> UIColor {
        type == .bug ? bugAccentBg : feedbackAccentBg
    }

    /// Severity tone color (foreground) + tinted background.
    static func severityTone(_ severity: Severity) -> (color: UIColor, bg: UIColor) {
        switch severity {
        case .blocks:
            return (.cdvDynamic(light: "dc2626", dark: "f87171"),
                    .cdvDynamic(light: "fef2f2", dark: "2a1416"))
        case .annoying:
            return (.cdvDynamic(light: "f97316", dark: "fb923c"),
                    .cdvDynamic(light: "fff7ed", dark: "2a1a0f"))
        case .minor:
            return (.cdvDynamic(light: "eab308", dark: "facc15"),
                    .cdvDynamic(light: "fefce8", dark: "2a2410"))
        }
    }
}
#endif
