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

/// On-disk descriptor for one attachment (`blobs/<index>.json`); while the bytes are still
/// pending they sit next to it in `blobs/<index>.bin`. `size` is recorded at write time so
/// the outbox can enforce its byte budget without reading the bytes back.
struct OutboxBlob: Codable, Equatable {
    let index: Int
    let kind: AttachmentKind
    let contentType: String
    let filename: String?
    let annotated: Bool
    let size: Int

    /// The R2 reference this blob earned when its bytes landed — its **receipt**. `nil` while
    /// the bytes are still pending.
    ///
    /// Writing the receipt is the *single* act that records an upload: it is one atomic write,
    /// and an entry's `report.attachments` is DERIVED from the receipts at load time
    /// (``FeedbackOutbox/entry(reportId:)``). So the reference and the bytes can never
    /// disagree. The previous design recorded an upload in two places — append the reference
    /// to `report.json`, then delete the bytes — and a failed write to `report.json` (disk
    /// full) lost the reference *and* the bytes.
    var attachment: Attachment?
}

/// Failures the outbox itself raises into a delivery.
enum OutboxError: Error {
    /// A blob the entry listed as pending has neither readable bytes nor a receipt. It counts as
    /// a failed attachment: the entry stays incomplete, so it is never ack-deleted with its
    /// evidence silently dropped.
    case blobMissing
}

/// One queued submission: the report plus every attachment that still needs uploading.
/// Attachments already uploaded are folded into `report.attachments` (their bytes are gone
/// from disk), so a replay only uploads what is still pending.
struct OutboxEntry {
    var report: FeedbackReport
    /// Blobs still awaiting upload — a descriptor whose receipt is on disk is NOT listed here
    /// (it is already in `report.attachments`).
    var blobs: [OutboxBlob]
}

/// A durable, on-disk queue of feedback submissions awaiting delivery. This is what lets a
/// submission survive being offline or the app being killed: the report **and the raw bytes
/// of every not-yet-uploaded attachment** are written to disk before any network call, and
/// the flusher drains them when connectivity returns.
///
/// Idempotency comes from the report's stable `reportId` (the server dedupes on it), so
/// replaying a "sent but unacknowledged" report is safe. Each attachment's reference is
/// persisted as soon as its upload lands, so a replay never re-uploads bytes that already
/// reached R2.
///
/// **Exactly one live delivery per entry, enforced HERE.** A deliverer claims an entry with
/// ``hold(_:)`` and gives it back with ``release(_:)``; ``pending()`` hides held entries and
/// the caps never evict one. That claim lives in the outbox — not in the caller — because the
/// outbox is what deletes folders: an eviction that fires while a delivery is uploading an
/// entry's blobs would strand those bytes, and the deliverer would then POST the report with
/// an empty `attachments` list and the 2xx ack would make the loss permanent.
///
/// Layout, one folder per entry:
/// ```
/// <outbox>/<reportId>/report.json      # the report AS SUBMITTED (uploads land in the receipts)
/// <outbox>/<reportId>/blobs/<n>.bin    # pending attachment bytes (gone once uploaded)
/// <outbox>/<reportId>/blobs/<n>.json   # that blob's descriptor + its receipt, once uploaded
/// <outbox>/<reportId>/screenshot.jpg   # legacy inline screenshot (`imageData`), if any
/// <outbox>/<reportId>/attachment-attempts.json  # attempts that left attachments missing
/// ```
///
/// Foundation-only and directory-injectable for testing. Every method is thread-safe.
///
/// **The lock guards bookkeeping, never unbounded IO.** `lock` is taken by whichever thread the
/// caller is on — including the reporter's main thread (``enqueue(_:blobs:)`` persists
/// synchronously, before Send returns) — so holding it across a 25–40 MB attachment write or read
/// would stall an unrelated thread for as long as the disk takes. The two unbounded operations
/// therefore run OUTSIDE it: `enqueue` writes the blob bytes lock-free (the `writing` set keeps
/// the folder invisible and un-reapable meanwhile), and ``blobData(reportId:index:)`` reads them
/// lock-free (a blob's bytes are only ever mutated by the delivery that holds the entry, and the
/// caps never evict a held one). What stays under the lock is metadata: a directory listing, the
/// `report.json` decode, small descriptor writes, deletes.
final class FeedbackOutbox {
    /// Default ceiling on queued entries.
    static let defaultMaxEntries = 50
    /// Default ceiling on total queued bytes. Screen recordings run to tens of MB, so a
    /// count cap alone is not enough to bound the outbox.
    static let defaultMaxBytes = 50 * 1024 * 1024

    /// How the outbox puts bytes on disk — always an atomic `Data.write` in production.
    ///
    /// Injectable because the disk-full paths are otherwise **untestable**: every POSIX trick
    /// that makes a write fail (a read-only directory) makes the matching *delete* fail too —
    /// both need write access to the containing directory — so it cannot reproduce the failure
    /// that actually matters, where the write fails and the delete would have happily
    /// succeeded, dropping the bytes AND their reference. See
    /// ``markUploaded(reportId:blobIndex:attachment:)`` and ``enqueue(_:blobs:)``.
    typealias FileWriter = (Data, URL) throws -> Void

    static let atomicWriter: FileWriter = { data, url in try data.write(to: url, options: .atomic) }

    private let directory: URL
    private let fileManager: FileManager
    private let writeFile: FileWriter
    private let maxEntries: Int
    private let maxBytes: Int
    private let lock = NSLock()

    /// Entries a delivery currently owns. In-memory by design: after a process death nothing
    /// is in flight, so every entry is up for grabs again on the next launch.
    private var held: Set<String> = []

    /// Entries whose folder is being written RIGHT NOW by ``enqueue(_:blobs:)`` — which does its
    /// file IO outside the lock (see the type doc). Such a folder has no `report.json` yet, so
    /// without this the reaper in ``sortedHeadersLocked()`` would take it for the residue of a
    /// crashed enqueue and delete it out from under the write in progress.
    private var writing: Set<String> = []

    init(
        directory: URL,
        maxEntries: Int = FeedbackOutbox.defaultMaxEntries,
        maxBytes: Int = FeedbackOutbox.defaultMaxBytes,
        fileManager: FileManager = .default,
        writeFile: @escaping FileWriter = FeedbackOutbox.atomicWriter
    ) {
        self.directory = directory
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1, maxBytes)
        self.fileManager = fileManager
        self.writeFile = writeFile
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

    // MARK: - The delivery claim

    /// Claim exclusive delivery of one entry. `false` means another path already owns it and
    /// the caller must NOT deliver it — that path will, and will report the outcome.
    ///
    /// Take the claim BEFORE ``enqueue(_:blobs:)`` publishes a brand-new report: the entry
    /// becomes visible the instant `report.json` lands, and a flush firing in that window
    /// (reconnect, foreground) would otherwise deliver it in parallel — re-uploading the
    /// bytes, POSTing the report twice, and letting the loser ack-delete the entry that holds
    /// the winner's attachment references.
    func hold(_ reportId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held.insert(reportId).inserted
    }

    /// Give the claim back. Always call it, including when the delivery failed.
    func release(_ reportId: String) {
        lock.lock(); defer { lock.unlock() }
        held.remove(reportId)
    }

    // MARK: - Enqueue

    /// Persist a report plus the raw bytes of its not-yet-uploaded attachments. Throws if
    /// the payload can't be written (e.g. disk full), so the caller can fall back to an
    /// in-memory send.
    ///
    /// Blocking, and deliberately so — it is called synchronously from ``CatchDev/submit`` so that
    /// the submission is durable by the time Send returns. The bytes are written **without the
    /// lock held** (they can be tens of megabytes): the id sits in `writing` for the duration,
    /// which makes the half-built folder invisible to every reader and immune to the reaper, and
    /// the entry becomes real only when `report.json` lands.
    func enqueue(_ report: FeedbackReport, blobs: [PendingBlob] = []) throws {
        let reportId = report.reportId
        let entry = directory.appendingPathComponent(reportId, isDirectory: true)

        lock.lock()
        do {
            try ensureDirectoryLocked()
        } catch {
            lock.unlock()
            throw error
        }
        writing.insert(reportId)
        lock.unlock()

        do {
            try fileManager.createDirectory(at: entry, withIntermediateDirectories: true)

            // Blobs first, `report.json` last: a decodable report.json is what makes an entry
            // visible, so a crash mid-write can never publish an entry whose evidence is missing.
            if !blobs.isEmpty {
                let blobsDirectory = entry.appendingPathComponent("blobs", isDirectory: true)
                try fileManager.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
                for (index, blob) in blobs.enumerated() {
                    try writeFile(blob.data, blobsDirectory.appendingPathComponent("\(index).bin"))
                    let descriptor = OutboxBlob(
                        index: index, kind: blob.kind, contentType: blob.contentType,
                        filename: blob.filename, annotated: blob.annotated, size: blob.data.count
                    )
                    try writeFile(
                        JSONEncoder().encode(descriptor),
                        blobsDirectory.appendingPathComponent("\(index).json")
                    )
                }
            }

            var persisted = report
            let image = persisted.imageData
            persisted.imageData = nil
            if let image {
                try writeFile(image, entry.appendingPathComponent("screenshot.jpg"))
            }
            try writeFile(JSONEncoder().encode(persisted), entry.appendingPathComponent("report.json"))
        } catch {
            // A half-written entry has no decodable `report.json`, so it is invisible to
            // `pending()` — and the blob bytes already written would sit on disk forever,
            // counted by no cap and reaped by nothing. Take the folder with us and let the
            // caller fall back to an in-memory send.
            try? fileManager.removeItem(at: entry)
            lock.lock()
            writing.remove(reportId)
            lock.unlock()
            throw error
        }

        lock.lock()
        writing.remove(reportId) // published: the entry is now a first-class citizen of the queue
        enforceCapacityLocked(keep: reportId)
        lock.unlock()
    }

    // MARK: - Reading

    /// All queued entries not claimed by a delivery, oldest first. Ordered by the report's own
    /// ISO-8601 `time` so we never read file timestamps (a "required reason" API). Blob *bytes*
    /// are not loaded — fetch them one at a time with ``blobData(reportId:index:)``.
    ///
    /// Treat the result as a *listing*, not as delivery input: an entry advances on disk while
    /// it is being delivered (a receipt is written, a blob's bytes are dropped), so a deliverer
    /// must re-read its entry with ``entry(reportId:)`` immediately before sending.
    ///
    /// This still reads every entry's legacy screenshot into memory. A flusher wanting only
    /// the work list must use ``pendingReportIds()``.
    func pending() -> [OutboxEntry] {
        lock.lock(); defer { lock.unlock() }
        return sortedHeadersLocked()
            .filter { !held.contains($0.reportId) }
            .compactMap { loadEntryLocked(at: directory.appendingPathComponent($0.reportId, isDirectory: true)) }
    }

    /// The ids of every entry awaiting delivery, oldest first, WITHOUT reading a single
    /// attachment or screenshot byte off disk. This — not ``pending()`` — is what a flush
    /// iterates: `pending()` would pull every queued screenshot through memory just to
    /// produce a work list, and each entry is re-read from disk right before it is delivered
    /// anyway.
    func pendingReportIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return sortedHeadersLocked()
            .filter { !held.contains($0.reportId) }
            .map(\.reportId)
    }

    /// One entry, read fresh from disk. This — not a ``pending()`` snapshot — is what a
    /// delivery must be built from: the receipts are the authority on which attachments have
    /// already reached R2 (they are folded into `report.attachments`), and `blobs` lists only
    /// the ones whose bytes are still there to upload.
    func entry(reportId: String) -> OutboxEntry? {
        lock.lock(); defer { lock.unlock() }
        return loadEntryLocked(at: directory.appendingPathComponent(reportId, isDirectory: true))
    }

    /// The bytes of one pending blob, or `nil` if they are gone (uploaded, dropped, or the
    /// entry no longer exists). `nil` alone does NOT mean "already uploaded" — only a receipt
    /// proves that; see ``uploadedAttachment(reportId:index:)``.
    ///
    /// Deliberately **not** under the lock: a screen recording is 25–40 MB, and blocking every
    /// other outbox caller (including the main thread, which is inside `enqueue` when the user
    /// taps Send) for the length of that read is exactly the kind of stall an embedded SDK may
    /// not impose. It is safe because a blob's bytes are only ever mutated by the one delivery
    /// that holds the entry (`markUploaded` / `remove`), and the caps never evict a held entry
    /// — and a `nil` from a racing delete is already the caller's "no bytes, no receipt ⇒ retry
    /// later" path, never a silent drop.
    func blobData(reportId: String, index: Int) -> Data? {
        try? Data(contentsOf: blobsDirectory(for: reportId).appendingPathComponent("\(index).bin"))
    }

    /// The receipt for one blob: the R2 reference it earned, or `nil` if it never uploaded.
    /// This is the *proof* a deliverer needs before it may treat missing bytes as "already
    /// uploaded" and ship the report without them.
    func uploadedAttachment(reportId: String, index: Int) -> Attachment? {
        lock.lock(); defer { lock.unlock() }
        return descriptorLocked(reportId: reportId, index: index)?.attachment
    }

    // MARK: - Writing

    /// Record that a blob's bytes reached R2: write its receipt into the blob's descriptor
    /// (one atomic write), then delete the bytes. Doing this *per attachment* is what makes a
    /// replay skip uploads that already succeeded. A crash between the R2 PUT and the receipt
    /// orphans at most one object in R2 — never a duplicate report, never a lost reference.
    ///
    /// If the receipt cannot be written (disk full, unwritable volume) NOTHING is dropped: the
    /// bytes stay pending and the retry re-uploads them. Deleting them anyway — as the old
    /// `try?`-and-delete did — lost the evidence *and* its reference in one go.
    ///
    /// Idempotent per blob index: a descriptor that already carries a receipt records nothing.
    /// (The obvious `report.attachments.contains(attachment)` check cannot do this job — a
    /// second upload of the same bytes gets a *different* R2 key, so the two `Attachment`
    /// values are never equal and the same evidence would be listed twice.)
    func markUploaded(reportId: String, blobIndex: Int, attachment: Attachment) {
        lock.lock(); defer { lock.unlock() }
        let blobs = blobsDirectory(for: reportId)
        let descriptorURL = blobs.appendingPathComponent("\(blobIndex).json")
        guard
            var descriptor = descriptorLocked(reportId: reportId, index: blobIndex),
            descriptor.attachment == nil // already recorded (or the entry is gone)
        else { return }

        descriptor.attachment = attachment
        do {
            try writeFile(JSONEncoder().encode(descriptor), descriptorURL)
        } catch {
            // The receipt did NOT land. Do NOT touch the bytes: they are the only copy of the
            // user's evidence, and the retry re-uploads them (at worst one orphan in R2).
            return
        }
        try? fileManager.removeItem(at: blobs.appendingPathComponent("\(blobIndex).bin"))
    }

    // MARK: - Attachment attempts

    /// How many delivery attempts of this entry reached the server — the report POST got a
    /// 2xx — but still left attachments missing. `0` for an entry with none, or no entry.
    ///
    /// This is what bounds the attachment retry: the deliverer gives up on an entry's missing
    /// attachments only after enough of these (see ``CatchDev/AttachmentRetryLimits``). It is
    /// on disk, next to the entry, so relaunching the app cannot reset it.
    func attachmentAttempts(reportId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return attachmentAttemptsLocked(reportId: reportId)
    }

    /// Count one more attempt that left attachments missing, and return the new total.
    ///
    /// A failed write (disk full) is deliberately not an error: the count simply does not
    /// advance on disk, which can only make the SDK retry longer, never give up early. An
    /// entry that is no longer on disk gets no file — writing one would leave a folder with no
    /// `report.json` behind, for the reaper to find.
    @discardableResult
    func recordAttachmentAttempt(reportId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let entry = directory.appendingPathComponent(reportId, isDirectory: true)
        let attempts = attachmentAttemptsLocked(reportId: reportId) + 1
        guard fileManager.fileExists(atPath: entry.appendingPathComponent("report.json").path) else {
            return attempts
        }
        if let data = try? JSONEncoder().encode(AttachmentAttempts(count: attempts)) {
            try? writeFile(data, entry.appendingPathComponent(Self.attachmentAttemptsFile))
        }
        return attempts
    }

    /// On-disk shape of `attachment-attempts.json`.
    private struct AttachmentAttempts: Codable {
        let count: Int
    }

    private static let attachmentAttemptsFile = "attachment-attempts.json"

    private func attachmentAttemptsLocked(reportId: String) -> Int {
        let url = directory
            .appendingPathComponent(reportId, isDirectory: true)
            .appendingPathComponent(Self.attachmentAttemptsFile)
        guard
            let data = try? Data(contentsOf: url),
            let attempts = try? JSONDecoder().decode(AttachmentAttempts.self, from: data)
        else { return 0 }
        return max(0, attempts.count)
    }

    /// Remove an entry and everything under it: delivered, permanently rejected, or given up on
    /// once its attachments ran out of retries.
    func remove(reportId: String) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: directory.appendingPathComponent(reportId, isDirectory: true))
    }

    /// Every entry on disk, held ones included.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return sortedHeadersLocked().count
    }

    /// What the queue actually costs the user: the bytes every queued entry occupies on disk —
    /// its `report.json`, its blob descriptors, its not-yet-uploaded attachment bytes and its
    /// legacy screenshot. Bytes that have reached R2 no longer count (they are deleted as soon as
    /// their receipt lands), so this shrinks as a delivery progresses.
    ///
    /// This is measured the same way as the Android SDK's `bytesOf()` — the whole entry folder —
    /// because the byte budget is the same budget on both platforms and must be crossed at the
    /// same point.
    var totalBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return sortedHeadersLocked().reduce(0) { $0 + $1.byteCost }
    }

    // MARK: - Private

    /// Just enough of an entry to ORDER and BOUND it — no attachment bytes, no screenshot
    /// bytes. The caps run on every enqueue and the work list on every flush; neither may pull
    /// tens of megabytes through memory just to count them (`byteCost` comes from the file
    /// sizes, never from reading the files).
    private struct EntryHeader {
        let reportId: String
        let time: String
        let byteCost: Int
    }

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

    /// Every entry's header, oldest first. Reaps corrupt/half-written folders on the way past.
    /// Ordered by the report's own ISO-8601 time (lexicographic == chronological) with the id
    /// as a tie-break, so eviction and flushing are deterministic.
    private func sortedHeadersLocked() -> [EntryHeader] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        var headers: [EntryHeader] = []
        for entry in directories {
            // An `enqueue` is writing this folder right now (it does its IO outside the lock).
            // It has no `report.json` yet, so it is neither on the queue nor reapable residue.
            if writing.contains(entry.lastPathComponent) { continue }
            guard let identity = identityLocked(at: entry) else {
                // No decodable `report.json`: the residue of a crash between writing the blobs
                // and writing the report, or a corrupt payload. Invisible to `pending()`, and
                // no cap accounts for its bytes — reap it.
                try? fileManager.removeItem(at: entry)
                continue
            }
            // Drop any uploaded blob's leftover bytes BEFORE sizing the folder, so the budget
            // never charges the user for bytes that are already in R2.
            reapUploadedBytesLocked(at: entry)
            headers.append(EntryHeader(
                reportId: identity.reportId,
                time: identity.time,
                byteCost: directorySizeLocked(at: entry)
            ))
        }
        return headers.sorted { ($0.time, $0.reportId) < ($1.time, $1.reportId) }
    }

    /// The report's id + time, decoded from `report.json` — the only two fields ordering and
    /// eviction need. `nil` means the entry is not (yet, or no longer) a valid one.
    private func identityLocked(at entry: URL) -> (reportId: String, time: String)? {
        guard
            let data = try? Data(contentsOf: entry.appendingPathComponent("report.json")),
            let report = try? JSONDecoder().decode(FeedbackReport.self, from: data)
        else { return nil }
        return (report.reportId, report.time)
    }

    private func loadEntryLocked(at entry: URL) -> OutboxEntry? {
        guard
            let data = try? Data(contentsOf: entry.appendingPathComponent("report.json")),
            var report = try? JSONDecoder().decode(FeedbackReport.self, from: data)
        else { return nil }
        report.imageData = try? Data(contentsOf: entry.appendingPathComponent("screenshot.jpg"))

        let descriptors = descriptorsLocked(at: entry)
        // Uploads are recorded ONLY as receipts; the delivered report's `attachments` is those
        // receipts (in blob order) appended to whatever the caller submitted.
        report.attachments += descriptors.compactMap(\.attachment)
        // A descriptor with neither a receipt nor its bytes is not deliverable — treat it as
        // gone rather than shipping a reference to nothing.
        let pending = descriptors.filter {
            $0.attachment == nil
                && fileManager.fileExists(
                    atPath: entry
                        .appendingPathComponent("blobs", isDirectory: true)
                        .appendingPathComponent("\($0.index).bin").path
                )
        }
        return OutboxEntry(report: report, blobs: pending)
    }

    /// Every blob descriptor of one entry (pending AND uploaded), ordered by index.
    private func descriptorsLocked(at entry: URL) -> [OutboxBlob] {
        let blobsDirectory = entry.appendingPathComponent("blobs", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: blobsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(OutboxBlob.self, from: data)
            }
            .sorted { $0.index < $1.index }
    }

    private func descriptorLocked(reportId: String, index: Int) -> OutboxBlob? {
        let url = blobsDirectory(for: reportId).appendingPathComponent("\(index).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OutboxBlob.self, from: data)
    }

    /// Delete the bytes of any blob whose receipt is already on disk — the residue of a crash
    /// between writing the receipt and dropping the bytes. They are no longer deliverable (the
    /// receipt IS the reference), so keeping them is pure disk cost.
    private func reapUploadedBytesLocked(at entry: URL) {
        let blobs = entry.appendingPathComponent("blobs", isDirectory: true)
        for descriptor in descriptorsLocked(at: entry) where descriptor.attachment != nil {
            let bytes = blobs.appendingPathComponent("\(descriptor.index).bin")
            guard fileManager.fileExists(atPath: bytes.path) else { continue }
            try? fileManager.removeItem(at: bytes)
        }
    }

    /// What one entry occupies on disk, all files under its folder. `.fileSizeKey` is a size, not
    /// a timestamp — no "required reason" API is involved (which is why the outbox may not sort by
    /// file dates, but may do this). Metadata only: the files are never read.
    private func directorySizeLocked(at entry: URL) -> Int {
        guard let files = fileManager.enumerator(
            at: entry, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    /// Bound the outbox by BOTH a max entry count and a total byte budget (a single screen
    /// recording can be ~25 MB), evicting oldest-first.
    ///
    /// **This is the unified caps rule, shared verbatim with the Android SDK** (`enforceCapacity`
    /// in its `FeedbackOutbox.kt`). The two SDKs must evict the same entries for the same input —
    /// a divergence here means identical user actions silently destroy a report on one platform
    /// and keep it on the other — so the loop is written to be read side by side with it:
    ///
    ///     1. count cap, always:  evict oldest-first while count > maxEntries
    ///     2. byte cap, ONLY when evicting can get us under it:
    ///        floor = bytes that survive regardless (pinned; or the newest, if nothing is pinned)
    ///        if floor > maxBytes: stop — the byte cap steps aside
    ///        else: evict oldest-first while totalBytes > maxBytes AND more than one entry remains
    ///
    /// Step 2's `floor` gate is the oversized-entry policy, and it is not optional. Without it,
    /// "evict oldest while over budget" happily deletes every *other* queued report to make room
    /// for one 60 MB recording that will never fit anyway — trading N good reports for nothing.
    /// So an entry bigger than the whole budget is KEPT, and it does not get to cannibalise its
    /// neighbours. Unbounded growth around it is still prevented by the count cap in step 1.
    ///
    /// Two entries are never the victim: the one just enqueued (`keep`) and any entry a
    /// delivery currently holds. Deleting a held entry's folder out from under its deliverer is
    /// the worst bug this queue can have — the deliverer finds the blob gone, POSTs the report
    /// with an empty `attachments` array, and the 2xx ack makes the loss permanent. A pinned
    /// entry is skipped, not stopped on: the sweep moves to the next-oldest and keeps going.
    private func enforceCapacityLocked(keep: String?) {
        var headers = sortedHeadersLocked() // oldest first; also reaps half-written entries

        func isPinned(_ header: EntryHeader) -> Bool {
            header.reportId == keep || held.contains(header.reportId)
        }
        func evict(at index: Int) {
            let victim = headers.remove(at: index)
            // Never silent. An entry with recorded attachment attempts already had its report
            // acked, so only its unsent attachments are lost; any other entry loses the report.
            let delivered = attachmentAttemptsLocked(reportId: victim.reportId) > 0
            try? fileManager.removeItem(
                at: directory.appendingPathComponent(victim.reportId, isDirectory: true)
            )
            CatchDev.warn(
                delivered
                    ? "outbox full: gave up on the attachments of report \(victim.reportId) (the report itself was delivered)"
                    : "outbox full: dropped report \(victim.reportId) before it could be delivered"
            )
        }

        // 1. Count cap — always.
        var index = 0
        while headers.count > maxEntries, index < headers.count {
            if isPinned(headers[index]) {
                index += 1 // pinned — try the next-oldest instead
                continue
            }
            evict(at: index)
        }

        // 2. Byte cap — but only when evicting can actually get us under it. The bytes that must
        //    survive no matter what (the pinned entries; or, with none pinned, the newest — the
        //    outbox never evicts its last one) may already exceed the budget. Evicting the rest
        //    could then never bring the outbox under it, so the byte cap steps aside and only the
        //    count cap applies: a lone oversized recording is KEPT, and it does not get to
        //    cannibalise the perfectly good reports queued beside it.
        //
        //    MUST STAY IDENTICAL to the Android outbox's `enforceCapacity` — the two SDKs have
        //    now drifted apart on this rule twice, each with a test pinning the other as wrong.
        let pinned = headers.filter(isPinned)
        let floor = pinned.isEmpty
            ? (headers.last?.byteCost ?? 0)
            : pinned.reduce(0) { $0 + $1.byteCost }
        guard floor <= maxBytes else { return }

        var total = headers.reduce(0) { $0 + $1.byteCost }
        index = 0
        while total > maxBytes, headers.count > 1, index < headers.count {
            if isPinned(headers[index]) {
                index += 1
                continue
            }
            total -= headers[index].byteCost
            evict(at: index)
        }
    }
}
