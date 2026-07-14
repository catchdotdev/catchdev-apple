#if canImport(UIKit)
import Foundation

/// Stable accessibility identifiers for the reporter's controls. Shared with the example
/// app's XCUITests, which find every element by these strings. The legacy ids
/// (`message`, `send`, `cancel`, `undo`, `clear`, `screenshot`) are preserved.
public enum CatchDevReporterAccessibility {
    // Top bar
    public static let close = "catchdev.reporter.cancel" // legacy id retained
    public static let cancel = "catchdev.reporter.cancel"

    // Tabs
    public static let tabFeedback = "catchdev.reporter.tab.feedback"
    public static let tabBug = "catchdev.reporter.tab.bug"

    // Description
    public static let message = "catchdev.reporter.message"

    // Severity (bug only)
    public static func severity(_ value: Severity) -> String {
        "catchdev.reporter.severity.\(value.rawValue)"
    }

    // Area picker. The options live on a UIPickerView wheel, which has no per-row elements —
    // UI tests drive it with `pickerWheels.adjust(toPickerWheelValue:)` and commit with Done.
    public static let area = "catchdev.reporter.area"
    public static let areaWheel = "catchdev.reporter.area.wheel"
    public static let areaDone = "catchdev.reporter.area.done"
    public static let areaCancel = "catchdev.reporter.area.cancel"

    // Tools
    public static let toolScreenshot = "catchdev.reporter.tool.screenshot"
    public static let toolRecord = "catchdev.reporter.tool.record"
    public static let toolAttach = "catchdev.reporter.tool.attach"
    public static let recordStop = "catchdev.reporter.record.stop"

    // Attachments
    public static func attachment(_ index: Int) -> String {
        "catchdev.reporter.attachment.\(index)"
    }
    public static func attachmentRemove(_ index: Int) -> String {
        "catchdev.reporter.attachment.remove.\(index)"
    }
    /// Opens the annotate screen for an existing screenshot attachment.
    public static func attachmentEdit(_ index: Int) -> String {
        "catchdev.reporter.attachment.edit.\(index)"
    }

    // Diagnostics disclosure
    public static let diagnosticsHeader = "catchdev.reporter.diagnostics"
    public static func diagnosticsToggle(_ id: DiagnosticID) -> String {
        "catchdev.reporter.diagnostics.toggle.\(id.rawValue)"
    }

    // Contact
    public static let contact = "catchdev.reporter.contact"

    // Footer
    public static let send = "catchdev.reporter.send"

    // Annotate screen
    public static let screenshot = "catchdev.reporter.screenshot"
    public static let undo = "catchdev.reporter.undo"
    public static let clear = "catchdev.reporter.clear"
    public static let annotateDone = "catchdev.reporter.annotate.done"
    public static let annotateCancel = "catchdev.reporter.annotate.cancel"
    public static func annotateTool(_ name: String) -> String {
        "catchdev.reporter.annotate.\(name)"
    }

    // Sending / success overlays
    public static let sending = "catchdev.reporter.sending"
    public static let success = "catchdev.reporter.success"
    /// The success overlay in its offline "saved, we'll send it later" form.
    public static let queued = "catchdev.reporter.queued"
    public static let successDone = "catchdev.reporter.success.done"
}
#endif
