import Foundation

/// The raw bytes of an attachment that has **not been uploaded yet**, handed to the outbox
/// at submit time — before any network call — so a report queued while offline keeps its
/// evidence. Foundation-only (no `UIImage`) so the core still compiles for macOS; the
/// reporter maps its `PendingAttachment` onto this.
struct PendingBlob {
    let kind: AttachmentKind
    let data: Data
    let contentType: String
    let filename: String?
    let annotated: Bool
}

/// On-disk descriptor for one pending blob (`blobs/<index>.json`); the bytes sit next to it
/// in `blobs/<index>.bin`. `size` is recorded at write time so the outbox can enforce its
/// byte budget without reading the bytes back.
struct OutboxBlob: Codable, Equatable {
    let index: Int
    let kind: AttachmentKind
    let contentType: String
    let filename: String?
    let annotated: Bool
    let size: Int
}

/// One queued submission: the report plus every attachment that still needs uploading.
/// Attachments already uploaded live in `report.attachments` (their bytes are gone from
/// disk), so a replay only uploads what is still pending.
struct OutboxEntry {
    var report: FeedbackReport
    var blobs: [OutboxBlob]

    /// Bytes this entry occupies on disk (pending blobs + the legacy inline screenshot).
    var byteCost: Int {
        blobs.reduce(0) { $0 + $1.size } + (report.imageData?.count ?? 0)
    }
}

/// A durable, on-disk queue of feedback submissions awaiting delivery. This is what lets a
/// submission survive being offline or the app being killed: the report **and the raw bytes
/// of every not-yet-uploaded attachment** are written to disk before any network call, and
/// the flusher drains them when connectivity returns.
///
/// Idempotency comes from the report's stable `reportId` (the server dedupes on it), so
/// replaying a "sent but unacknowledged" report is safe. Each attachment reference is
/// persisted into `report.json` as soon as its upload lands, so a replay never re-uploads
/// bytes that already reached R2.
///
/// Layout, one folder per entry:
/// ```
/// <outbox>/<reportId>/report.json      # the report; `attachments` = already-uploaded refs
/// <outbox>/<reportId>/blobs/<n>.bin    # pending attachment bytes
/// <outbox>/<reportId>/blobs/<n>.json   # that blob's metadata
/// <outbox>/<reportId>/screenshot.jpg   # legacy inline screenshot (`imageData`), if any
/// ```
///
/// Foundation-only and directory-injectable for testing.
final class FeedbackOutbox {
    /// Default ceiling on queued entries.
    static let defaultMaxEntries = 50
    /// Default ceiling on total queued bytes. Screen recordings run to tens of MB, so a
    /// count cap alone is not enough to bound the outbox.
    static let defaultMaxBytes = 50 * 1024 * 1024

    private let directory: URL
    private let fileManager: FileManager
    private let maxEntries: Int
    private let maxBytes: Int
    private let lock = NSLock()

    init(
        directory: URL,
        maxEntries: Int = FeedbackOutbox.defaultMaxEntries,
        maxBytes: Int = FeedbackOutbox.defaultMaxBytes,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1, maxBytes)
        self.fileManager = fileManager
    }

    /// Default location: `Application Support/CatchDev/outbox`. Deliberately NOT in Caches,
    /// which the system can evict under disk pressure — feedback must not silently vanish.
    /// Returns `nil` if Application Support is unavailable (the SDK then sends in-memory only).
    static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let base = try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base.appendingPathComponent("CatchDev/outbox", isDirectory: true)
    }

    /// Persist a report plus the raw bytes of its not-yet-uploaded attachments. Throws if
    /// the payload can't be written (e.g. disk full), so the caller can fall back to an
    /// in-memory send.
    func enqueue(_ report: FeedbackReport, blobs: [PendingBlob] = []) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectoryLocked()
        let entry = directory.appendingPathComponent(report.reportId, isDirectory: true)
        try fileManager.createDirectory(at: entry, withIntermediateDirectories: true)

        // Blobs first, `report.json` last: a decodable report.json is what makes an entry
        // visible, so a crash mid-write can never publish an entry whose evidence is missing.
        if !blobs.isEmpty {
            let blobsDirectory = entry.appendingPathComponent("blobs", isDirectory: true)
            try fileManager.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
            for (index, blob) in blobs.enumerated() {
                try blob.data.write(
                    to: blobsDirectory.appendingPathComponent("\(index).bin"), options: .atomic
                )
                let descriptor = OutboxBlob(
                    index: index, kind: blob.kind, contentType: blob.contentType,
                    filename: blob.filename, annotated: blob.annotated, size: blob.data.count
                )
                try JSONEncoder().encode(descriptor).write(
                    to: blobsDirectory.appendingPathComponent("\(index).json"), options: .atomic
                )
            }
        }

        var persisted = report
        let image = persisted.imageData
        persisted.imageData = nil
        if let image {
            try image.write(to: entry.appendingPathComponent("screenshot.jpg"), options: .atomic)
        }
        try JSONEncoder().encode(persisted).write(
            to: entry.appendingPathComponent("report.json"), options: .atomic
        )
        enforceCapacityLocked()
    }

    /// All queued entries, oldest first. Ordered by the report's own ISO-8601 `time` so we
    /// never read file timestamps (which are a "required reason" API). Blob *bytes* are not
    /// loaded — fetch them one at a time with ``blobData(reportId:index:)``.
    ///
    /// Treat the result as a *listing*, not as delivery input: an entry advances on disk while
    /// it is being delivered (a reference is appended, a blob's bytes are dropped), so a
    /// deliverer must re-read its entry with ``entry(reportId:)`` immediately before sending.
    func pending() -> [OutboxEntry] {
        lock.lock(); defer { lock.unlock() }
        return loadAllLocked().sorted { $0.report.time < $1.report.time }
    }

    /// One entry, read fresh from disk. This — not a `pending()` snapshot — is what a
    /// delivery must be built from: `report.json` is the authority on which attachments have
    /// already reached R2, and the blob list only contains the ones whose bytes are still
    /// there to upload.
    func entry(reportId: String) -> OutboxEntry? {
        lock.lock(); defer { lock.unlock() }
        return loadEntryLocked(at: directory.appendingPathComponent(reportId, isDirectory: true))
    }

    /// The bytes of one pending blob, or `nil` if it has already been uploaded (and dropped).
    func blobData(reportId: String, index: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: blobsDirectory(for: reportId).appendingPathComponent("\(index).bin"))
    }

    /// Record that a blob's bytes reached R2: append its reference to the entry's report and
    /// rewrite `report.json` atomically, then delete the blob's bytes. Doing this *per
    /// attachment* is what makes a replay skip uploads that already succeeded. A crash
    /// between the R2 PUT and this rewrite orphans at most one object in R2 — never a
    /// duplicate report.
    ///
    /// Idempotent **per blob index**: the blob's `.bin` file is the flag. Once it is gone this
    /// blob's reference is already in `report.json`, so a second call records nothing. (The
    /// obvious `report.attachments.contains(attachment)` check cannot do this job — a second
    /// upload of the same bytes gets a *different* R2 key, so the two `Attachment` values are
    /// never equal and the same evidence would be listed twice.)
    func markUploaded(reportId: String, blobIndex: Int, attachment: Attachment) {
        lock.lock(); defer { lock.unlock() }
        let entry = directory.appendingPathComponent(reportId, isDirectory: true)
        let blobs = entry.appendingPathComponent("blobs", isDirectory: true)
        let bytes = blobs.appendingPathComponent("\(blobIndex).bin")
        guard fileManager.fileExists(atPath: bytes.path) else { return } // already recorded

        let reportURL = entry.appendingPathComponent("report.json")
        guard
            let data = try? Data(contentsOf: reportURL),
            var report = try? JSONDecoder().decode(FeedbackReport.self, from: data)
        else { return } // the entry is gone (delivered or evicted) — nothing to record
        report.attachments.append(attachment)
        // Persist the reference BEFORE dropping the bytes: a crash in between re-uploads the
        // blob (one orphan in R2), whereas the reverse order would lose the evidence.
        guard let encoded = try? JSONEncoder().encode(report) else { return }
        try? encoded.write(to: reportURL, options: .atomic)

        try? fileManager.removeItem(at: bytes)
        try? fileManager.removeItem(at: blobs.appendingPathComponent("\(blobIndex).json"))
    }

    /// Discard one blob the server refused for good (413 too large, unsupported type) while
    /// KEEPING the entry. The design's permanent-rejection rule is about the report POST;
    /// applying it to an attachment hop would destroy the user's typed message — and every
    /// attachment that already uploaded — over one oversized file. Dropping just the bytes
    /// stops the pointless retry and lets the rest of the report be delivered.
    func dropBlob(reportId: String, index: Int) {
        lock.lock(); defer { lock.unlock() }
        let blobs = blobsDirectory(for: reportId)
        try? fileManager.removeItem(at: blobs.appendingPathComponent("\(index).bin"))
        try? fileManager.removeItem(at: blobs.appendingPathComponent("\(index).json"))
    }

    /// Remove a delivered (or permanently rejected) entry and everything under it.
    func remove(reportId: String) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: directory.appendingPathComponent(reportId, isDirectory: true))
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return loadAllLocked().count
    }

    /// Total bytes currently queued (pending blobs + legacy screenshots).
    var totalBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return loadAllLocked().reduce(0) { $0 + $1.byteCost }
    }

    // MARK: - Private

    private func blobsDirectory(for reportId: String) -> URL {
        directory
            .appendingPathComponent(reportId, isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
    }

    private func ensureDirectoryLocked() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func loadAllLocked() -> [OutboxEntry] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        // Skips non-entry files and corrupt/half-written payloads.
        return directories.compactMap { loadEntryLocked(at: $0) }
    }

    private func loadEntryLocked(at entry: URL) -> OutboxEntry? {
        guard
            let data = try? Data(contentsOf: entry.appendingPathComponent("report.json")),
            var report = try? JSONDecoder().decode(FeedbackReport.self, from: data)
        else { return nil }
        report.imageData = try? Data(contentsOf: entry.appendingPathComponent("screenshot.jpg"))
        return OutboxEntry(report: report, blobs: loadBlobsLocked(at: entry))
    }

    private func loadBlobsLocked(at entry: URL) -> [OutboxBlob] {
        let blobsDirectory = entry.appendingPathComponent("blobs", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: blobsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        var blobs: [OutboxBlob] = []
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let blob = try? JSONDecoder().decode(OutboxBlob.self, from: data),
                // A descriptor without its bytes is not deliverable — treat it as gone.
                fileManager.fileExists(
                    atPath: blobsDirectory.appendingPathComponent("\(blob.index).bin").path
                )
            else { continue }
            blobs.append(blob)
        }
        return blobs.sorted { $0.index < $1.index }
    }

    /// Bound the outbox by BOTH a max entry count and a total byte budget (a single screen
    /// recording can be ~25 MB), evicting oldest-first. The entry just enqueued is never the
    /// victim of the byte budget — an oversized lone report is kept rather than silently lost.
    private func enforceCapacityLocked() {
        pruneIncompleteLocked()
        let all = loadAllLocked().sorted { $0.report.time < $1.report.time }
        var total = all.reduce(0) { $0 + $1.byteCost }
        var remaining = all.count
        for entry in all {
            let overCount = remaining > maxEntries
            let overBytes = total > maxBytes && remaining > 1
            guard overCount || overBytes else { break }
            try? fileManager.removeItem(
                at: directory.appendingPathComponent(entry.report.reportId, isDirectory: true)
            )
            total -= entry.byteCost
            remaining -= 1
        }
    }

    /// Delete entry folders with no decodable `report.json` — the residue of a crash between
    /// writing the blobs and writing the report. They are invisible to `pending()` and would
    /// otherwise hold disk space that no cap accounts for.
    private func pruneIncompleteLocked() {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for entry in directories where loadEntryLocked(at: entry) == nil {
            try? fileManager.removeItem(at: entry)
        }
    }
}
