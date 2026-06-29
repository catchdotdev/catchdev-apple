import Foundation

/// A durable, on-disk queue of feedback reports awaiting upload. This is what lets a
/// submission survive being offline or the app being killed: the report is written to
/// disk on submit and the flusher drains it when connectivity returns. Idempotency is
/// provided by the report's stable `reportId` (the server dedupes on it), so replaying a
/// "sent but unacknowledged" report is safe.
///
/// Foundation-only and directory-injectable for testing. Each pending report is a folder
/// `<outbox>/<reportId>/` containing `report.json` and (optionally) `screenshot.jpg`.
final class FeedbackOutbox {
    private let directory: URL
    private let fileManager: FileManager
    private let maxEntries: Int
    private let lock = NSLock()

    init(directory: URL, maxEntries: Int = 50, fileManager: FileManager = .default) {
        self.directory = directory
        self.maxEntries = max(1, maxEntries)
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

    /// Persist a report. Throws if the payload can't be written (e.g. disk full), so the
    /// caller can fall back to an in-memory send.
    func enqueue(_ report: FeedbackReport) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectoryLocked()
        let entry = directory.appendingPathComponent(report.reportId, isDirectory: true)
        try fileManager.createDirectory(at: entry, withIntermediateDirectories: true)

        var persisted = report
        let image = persisted.imageData
        persisted.imageData = nil
        let data = try JSONEncoder().encode(persisted)
        try data.write(to: entry.appendingPathComponent("report.json"), options: .atomic)
        if let image {
            try image.write(to: entry.appendingPathComponent("screenshot.jpg"), options: .atomic)
        }
        enforceCapacityLocked()
    }

    /// All pending reports, oldest first. Ordered by the report's own ISO-8601 `time` so we
    /// never read file timestamps (which are a "required reason" API).
    func pending() -> [FeedbackReport] {
        lock.lock(); defer { lock.unlock() }
        return loadAllLocked().sorted { $0.time < $1.time }
    }

    /// Remove a delivered (or permanently rejected) report.
    func remove(reportId: String) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: directory.appendingPathComponent(reportId, isDirectory: true))
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return loadAllLocked().count
    }

    // MARK: - Private

    private func ensureDirectoryLocked() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func loadAllLocked() -> [FeedbackReport] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        var reports: [FeedbackReport] = []
        for entry in entries {
            let jsonURL = entry.appendingPathComponent("report.json")
            guard
                let data = try? Data(contentsOf: jsonURL),
                var report = try? JSONDecoder().decode(FeedbackReport.self, from: data)
            else { continue } // skip non-entry files and corrupt payloads
            report.imageData = try? Data(contentsOf: entry.appendingPathComponent("screenshot.jpg"))
            reports.append(report)
        }
        return reports
    }

    /// Drop the oldest entries beyond `maxEntries` so the outbox can't grow without bound
    /// (e.g. a device that stays offline for a long time).
    private func enforceCapacityLocked() {
        let all = loadAllLocked().sorted { $0.time < $1.time }
        guard all.count > maxEntries else { return }
        for report in all.prefix(all.count - maxEntries) {
            try? fileManager.removeItem(
                at: directory.appendingPathComponent(report.reportId, isDirectory: true)
            )
        }
    }
}
