import XCTest
@testable import CatchDev

final class BreadcrumbTrailTests: XCTestCase {
    private func crumb(_ name: String) -> Breadcrumb {
        Breadcrumb(screen: name, time: "t-\(name)")
    }

    func testRecordsInChronologicalOrderBelowCapacity() {
        var trail = BreadcrumbTrail(capacity: 5)
        trail.record(crumb("A"))
        trail.record(crumb("B"))
        trail.record(crumb("C"))
        XCTAssertEqual(trail.snapshot().map(\.screen), ["A", "B", "C"])
    }

    func testBoundsToCapacityDroppingOldest() {
        var trail = BreadcrumbTrail(capacity: 3)
        ["A", "B", "C", "D", "E"].forEach { trail.record(crumb($0)) }
        XCTAssertEqual(trail.snapshot().count, 3)
        XCTAssertEqual(trail.snapshot().map(\.screen), ["C", "D", "E"])
    }

    func testCapacityZeroRecordsNothing() {
        var trail = BreadcrumbTrail(capacity: 0)
        trail.record(crumb("A"))
        XCTAssertTrue(trail.snapshot().isEmpty)
    }

    func testNegativeCapacityClampsToZero() {
        var trail = BreadcrumbTrail(capacity: -5)
        XCTAssertEqual(trail.capacity, 0)
        trail.record(crumb("A"))
        XCTAssertTrue(trail.snapshot().isEmpty)
    }

    func testCapacityOfOneKeepsOnlyTheMostRecent() {
        var trail = BreadcrumbTrail(capacity: 1)
        ["A", "B", "C"].forEach { trail.record(crumb($0)) }
        XCTAssertEqual(trail.snapshot().map(\.screen), ["C"])
    }

    func testRepeatedScreenNamesAreAllKeptInOrder() {
        var trail = BreadcrumbTrail(capacity: 5)
        ["Home", "Detail", "Home"].forEach { trail.record(crumb($0)) }
        XCTAssertEqual(trail.snapshot().map(\.screen), ["Home", "Detail", "Home"])
    }

    func testSnapshotIsAnIndependentValueCopy() {
        var trail = BreadcrumbTrail(capacity: 5)
        trail.record(crumb("A"))
        let snapshot = trail.snapshot()
        trail.record(crumb("B"))
        // The earlier snapshot must not see the later mutation.
        XCTAssertEqual(snapshot.map(\.screen), ["A"])
        XCTAssertEqual(trail.snapshot().map(\.screen), ["A", "B"])
    }
}
