import XCTest
@testable import PandaCore

/// Each group has one color in the bar, and the same color on its row.
final class GroupColorTests: XCTestCase {
    private func item(_ eco: Ecosystem, _ bytes: Int64) -> Finding {
        Finding(id: UUID().uuidString, ecosystem: eco, title: "x", location: "x", bytes: bytes, tier: .safe,
                rebuild: .minutes, action: .owner(.brewCleanup))
    }

    func testTheSameGroupsInAnotherOrderKeepTheirSlots() {
        let groups: [(ecosystem: Ecosystem, bytes: Int64)] = [(.swift, 900), (.javascript, 800), (.docker, 700), (.browsers, 600),
                                                              (.python, 500), (.homebrew, 400)]
        let slots = SplitBar.colorSlots(for: groups)
        var expected: [Ecosystem: Int] = [:]
        for (g, s) in zip(groups, slots) { expected[g.ecosystem] = s }
        for shuffled in [Array(groups.reversed()), Array(groups.dropFirst(3)) + Array(groups.prefix(3))] {
            for (g, s) in zip(shuffled, SplitBar.colorSlots(for: shuffled)) { XCTAssertEqual(expected[g.ecosystem], s, "\(g.ecosystem)") }
        }
    }

    func testNoTwoGroupsOfOneBarShareASlotWhenThereAreEightOrFewer() {
        // Ecosystem.allCases has many cases, so some of them want the same slot.
        let all = Ecosystem.allCases
        for start in all.indices {
            let picked = (0..<8).map { all[(start + $0 * 3) % all.count] }
            XCTAssertEqual(Set(picked).count, 8)
            let groups = picked.enumerated().map { (ecosystem: $0.element, bytes: Int64(1_000 - $0.offset)) }
            let slots = SplitBar.colorSlots(for: groups)
            XCTAssertEqual(Set(slots).count, groups.count, "\(picked)")
            XCTAssertTrue(slots.allSatisfy { (0..<8).contains($0) })
        }
        // Two groups that want one slot: the group 8 places later wants the same slot as the first.
        let clash = SplitBar.colorSlots(for: [(Ecosystem.allCases[8], 5), (Ecosystem.allCases[0], 9)])
        XCTAssertEqual(clash[1], 0, "The larger group keeps its slot")
        XCTAssertEqual(clash[0], 1, "The smaller group takes the next free slot")
    }

    func testOtherHasNoSlotAndTheNamedPartsDo() {
        let findings = [item(.swift, 4_000_000_000), item(.javascript, 3_000_000_000), item(.docker, 20_000_000)]
        let parts = SplitBar.segments(from: findings)
        let slots = SplitBar.colorSlots(for: parts)
        XCTAssertEqual(parts.count, 3)
        XCTAssertNotNil(slots[0])
        XCTAssertNotNil(slots[1])
        XCTAssertNil(slots[2], "The last part is Other")
        XCTAssertTrue(parts[2].isOther)
    }

    func testTheMainRowsHaveTheSlotOfTheirPartAndFoldedRowsHaveNone() throws {
        let findings = [item(.swift, 4_000_000_000), item(.javascript, 3_000_000_000), item(.docker, 20_000_000)]
        let disk = DiskUsage(total: 500_000_000_000, free: 100_000_000_000)
        let model = MenuModel.make(MenuInput(result: ScanResult(findings: findings, disk: disk), disk: disk, scanning: false,
                                             cleaning: false, running: RunningSnapshot(apps: []), staleDays: 90))
        let slots = SplitBar.colorSlots(for: model.header.segments)
        let rows = model.rows.filter { $0.kind == .columns }
        let main = rows.filter { $0.title != "Smaller groups" }
        XCTAssertEqual(main.map(\.icon), [.groupColor(slot: try XCTUnwrap(slots[0])), .groupColor(slot: try XCTUnwrap(slots[1]))])
        let smaller = try XCTUnwrap(rows.first { $0.title == "Smaller groups" })
        XCTAssertNil(smaller.icon)
        XCTAssertTrue(try XCTUnwrap(smaller.submenu).rows.allSatisfy { $0.icon == nil }, "A folded group has no dot")
    }
}
