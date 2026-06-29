import Foundation

/// One visited screen in the breadcrumb trail. Foundation-only and value-typed so the
/// trail can be built and unit-tested without UIKit.
struct Breadcrumb: Equatable, Codable {
    /// Human-readable screen name (see `ScreenName.resolve` on iOS).
    let screen: String
    /// ISO 8601 timestamp, same format as ``FeedbackReport/time``.
    let time: String
}

/// A bounded, chronological ring buffer of recently visited screens. When more than
/// `capacity` crumbs are recorded the oldest are dropped, so memory stays constant no
/// matter how long the app runs. Value type — `snapshot()` returns an independent copy.
struct BreadcrumbTrail {
    let capacity: Int
    private(set) var crumbs: [Breadcrumb] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    /// Append a crumb, evicting the oldest if the trail is over capacity.
    mutating func record(_ crumb: Breadcrumb) {
        guard capacity > 0 else { return }
        crumbs.append(crumb)
        if crumbs.count > capacity {
            crumbs.removeFirst(crumbs.count - capacity)
        }
    }

    /// The current trail, oldest first. A value copy — safe to hand across threads.
    func snapshot() -> [Breadcrumb] { crumbs }
}

/// Single source of truth for the ISO 8601 timestamps used across the SDK, so report
/// times and breadcrumb times share one formatter and tests stay deterministic. The
/// formatter is cached (constructed once) since `now()` runs on every screen transition;
/// `ISO8601DateFormatter` is safe to reuse for formatting across threads.
enum Timestamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func now() -> String {
        formatter.string(from: Date())
    }
}
