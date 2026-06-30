#if canImport(UIKit)
import UIKit

/// An attachment held locally in the reporter until send time, when its bytes are
/// uploaded to R2 via a presigned URL and turned into an ``Attachment`` reference. Kept
/// local (rather than uploaded on add) so the design's "Uploading…" send step is honest
/// and so nothing is uploaded for a report the user abandons.
struct PendingAttachment {
    let id: String
    let kind: AttachmentKind
    var data: Data
    var contentType: String
    var filename: String?
    var annotated: Bool
    /// Preview image for the thumbnail (the screenshot itself, or a poster frame).
    var thumbnail: UIImage?

    init(
        id: String = UUID().uuidString,
        kind: AttachmentKind,
        data: Data,
        contentType: String,
        filename: String? = nil,
        annotated: Bool = false,
        thumbnail: UIImage? = nil
    ) {
        self.id = id
        self.kind = kind
        self.data = data
        self.contentType = contentType
        self.filename = filename
        self.annotated = annotated
        self.thumbnail = thumbnail
    }
}

/// One row in the reporter's "Included automatically" disclosure.
struct DiagnosticItem {
    let id: DiagnosticID
    /// SF Symbol name.
    let icon: String
    let title: String
    let value: String
    /// Locked rows (session id) cannot be excluded.
    let locked: Bool
}

/// A snapshot of the reporter's form state, preserved across the Record flow's
/// dismiss → record → re-present round-trip so the user doesn't lose their draft.
struct ReporterRestoreState {
    var drafts: [String: String] // ReportType.rawValue → text
    var tab: ReportType
    var severity: Severity?
    var area: String?
    var contact: String
    var excluded: Set<DiagnosticID>
    var attachments: [PendingAttachment]
    var screenName: String?
    var reportId: String
}
#endif
