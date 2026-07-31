import Foundation

/// Per-kind attachment size caps, mirroring what the backend enforces at the
/// `upload-url` mint (image 8 MB, file 25 MB, recording 50 MB — see the wire
/// contract). Checking client-side is not just politeness: without a cap the
/// reporter reads an arbitrarily large user-picked file straight into memory,
/// which OOM-kills the *host* app long before the server ever sees it.
enum AttachmentLimits {
    static let maxImageBytes = 8 * 1024 * 1024
    static let maxFileBytes = 25 * 1024 * 1024
    static let maxRecordingBytes = 50 * 1024 * 1024

    static func humanReadable(_ bytes: Int) -> String {
        "\(bytes / (1024 * 1024)) MB"
    }

    /// Reads at most `limit` bytes from `url` — a memory-bounded alternative to
    /// `Data(contentsOf:)` for attachments whose declared size is missing or
    /// wrong. Allocates at most `limit` bytes regardless of the real file
    /// length; callers pass `cap + 1` and reject a result that reaches `cap + 1`
    /// as too large. Returns nil if the file cannot be opened.
    ///
    /// Call this off the main thread: the read can block on an iCloud file that
    /// has not been materialised locally.
    static func readCapped(url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var out = Data()
        out.reserveCapacity(min(limit, 1024 * 1024))
        let chunkSize = 64 * 1024
        while out.count < limit {
            let want = min(chunkSize, limit - out.count)
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            out.append(chunk)
        }
        return out
    }

    /// Declared size from the filesystem, when it is available. Lets an
    /// oversized file be rejected without reading a single byte.
    static func declaredSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
