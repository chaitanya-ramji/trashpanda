import XCTest
@testable import PandaCore

/// One example for each defect that the property tests found in the bar.
final class BarDefectTests: XCTestCase {
    private func item(_ eco: Ecosystem, _ bytes: Int64) -> Finding {
        Finding(id: UUID().uuidString, ecosystem: eco, title: "x", location: "x", bytes: bytes, tier: .safe,
                rebuild: .minutes, action: .owner(.brewCleanup))
    }

    /// A part that is large could fall below the minimum width after the small parts were raised to it.
    func testNoPartIsThinnerThanTheMinimumWhenSmallPartsAreRaised() {
        // Four parts of 79, 17, 2 and 2 percent. In a narrow bar the 17 percent part is only a little above the minimum,
        // and it fell to 3 points when the two tiny parts were raised.
        let findings = [item(.swift, 79_000), item(.javascript, 17_000), item(.docker, 2_000), item(.python, 2_000)]
        let parts = SplitBar.segments(from: findings, minimumBytes: 1)
        XCTAssertEqual(parts.count, 4)
        for width: CGFloat in [30, 60, 90, 120, 264] {
            let slots = SplitBar.layout(parts, width: width)
            let end = slots.last.map { $0.x + $0.width } ?? 0
            XCTAssertEqual(end, width, accuracy: 0.001)
            for s in slots { XCTAssertGreaterThanOrEqual(s.width, 4 - 0.001, "width \(width): \(slots)") }
        }
    }

    func testPartsAreEqualWhenThereIsNoRoomForTheMinimum() {
        let parts = SplitBar.segments(from: [item(.swift, 5_000_000_000), item(.docker, 200_000_000), item(.python, 200_000_000)])
        let slots = SplitBar.layout(parts, width: 10)
        XCTAssertEqual(slots.last.map { $0.x + $0.width } ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(Set(slots.map { ($0.width * 1000).rounded() }).count, 1)
    }

    /// A group that was bumped to the next free slot must not take the slot of a smaller group that wants it.
    func testABumpedGroupDoesNotTakeTheSlotOfAGroupThatComesLater() {
        let all = Ecosystem.allCases
        let first = all[0], clash = all[8], other = all[1]   // `clash` wants slot 0, like `first`. `other` wants slot 1.
        let slots = SplitBar.colorSlots(for: [(ecosystem: first, bytes: 900), (ecosystem: clash, bytes: 500), (ecosystem: other, bytes: 100)])
        XCTAssertEqual(slots[0], 0)
        XCTAssertEqual(slots[2], 1, "the smallest group keeps the slot it wants")
        XCTAssertEqual(slots[1], 2, "the group that lost its slot takes the next free one")
    }
}
