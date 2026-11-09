import XCTest
@testable import PandaCore

final class SplitBarTests: XCTestCase {
    private func item(_ eco: Ecosystem, _ bytes: Int64, tier: Tier = .safe, action: Action = .owner(.brewCleanup)) -> Finding {
        Finding(id: UUID().uuidString, ecosystem: eco, title: "x", location: "x", bytes: bytes, tier: tier,
                rebuild: .minutes, action: action)
    }

    // MARK: Grouping

    func testThePartsAddUpToWhatCanBeCleaned() {
        let findings = [item(.swift, 4_000_000_000), item(.swift, 2_000_000_000, tier: .review),
                        item(.javascript, 3_000_000_000), item(.docker, 500_000_000, tier: .review)]
        let parts = SplitBar.segments(from: findings)
        XCTAssertEqual(parts.map(\.bytes).reduce(0, +), 9_500_000_000, "Every byte that can be cleaned is in the bar")
        XCTAssertEqual(parts.map(\.share).reduce(0, +), 1.0, accuracy: 1e-9)
        XCTAssertEqual(parts.map(\.shortName), ["Xcode", "JavaScript", "Docker"], "The largest first")
        XCTAssertEqual(parts[0].bytes, 6_000_000_000)
        XCTAssertEqual(parts[0].safeBytes, 4_000_000_000, "The safe part is known, so that the hover can say it")
        XCTAssertEqual(parts[2].safeBytes, 0)
    }

    func testBlockedItemsAndInformationLinesAreNotInTheBar() {
        let blocked = item(.swift, 4_000_000_000)
        let findings = [blocked, item(.swift, 1_000_000_000, action: .inform),   // information only
                        item(.javascript, 3_000_000_000), item(.python, 0)]       // nothing to free
        let parts = SplitBar.segments(from: findings, isBlocked: { $0.id == blocked.id })
        XCTAssertEqual(parts.map(\.shortName), ["JavaScript"])
        XCTAssertEqual(parts[0].bytes, 3_000_000_000)
        XCTAssertEqual(parts[0].share, 1.0)
    }

    func testNothingToCleanGivesNoBar() {
        XCTAssertTrue(SplitBar.segments(from: []).isEmpty)
        XCTAssertTrue(SplitBar.segments(from: [item(.swift, 100, action: .inform)]).isEmpty)
        XCTAssertTrue(SplitBar.segments(from: [item(.swift, 100)], isBlocked: { _ in true }).isEmpty)
    }

    func testTheSmallestGroupsAreJoinedAsOther() {
        // Eight groups: the largest five are named. The other three are one part.
        let sizes: [(Ecosystem, Int64)] = [(.swift, 80), (.javascript, 70), (.python, 60), (.rust, 50), (.go, 40),
                                           (.docker, 30), (.ruby, 20), (.php, 10)]
        let parts = SplitBar.segments(from: sizes.map { item($0.0, $0.1 * 1_000_000) })
        XCTAssertEqual(parts.count, 6)
        XCTAssertEqual(parts.dropLast().map(\.shortName), ["Xcode", "JavaScript", "Python", "Rust", "Go"])
        let other = try! XCTUnwrap(parts.last)
        XCTAssertTrue(other.isOther)
        XCTAssertEqual(other.name, "Other")
        XCTAssertEqual(Set(other.ecosystems), [.docker, .ruby, .php])
        XCTAssertEqual(other.bytes, 60_000_000)
        XCTAssertEqual(parts.map(\.bytes).reduce(0, +), 360_000_000)
    }

    func testOneLeftoverGroupKeepsItsOwnName() {
        // Six groups with room for five: "Other" would hide a single group, so it is named instead.
        let sizes: [(Ecosystem, Int64)] = [(.swift, 60), (.javascript, 50), (.python, 40), (.rust, 30), (.go, 20), (.docker, 10)]
        let parts = SplitBar.segments(from: sizes.map { item($0.0, $0.1 * 1_000_000) })
        XCTAssertEqual(parts.count, 6)
        XCTAssertFalse(parts.contains { $0.isOther })
        XCTAssertEqual(parts.last?.shortName, "Docker")
        // Seven groups: two are left over, so they are joined.
        let seven = SplitBar.segments(from: (sizes + [(.ruby, 5)]).map { item($0.0, $0.1 * 1_000_000) })
        XCTAssertEqual(seven.count, 6)
        XCTAssertTrue(seven.last!.isOther)
        XCTAssertEqual(Set(seven.last!.ecosystems), [.docker, .ruby])
    }

    func testTheOrderDoesNotChangeBetweenScansWhenSizesAreEqual() {
        let findings = [item(.python, 100), item(.go, 100), item(.rust, 100)]
        let first = SplitBar.segments(from: findings).map(\.shortName)
        for _ in 0..<5 { XCTAssertEqual(SplitBar.segments(from: findings.shuffled()).map(\.shortName), first) }
    }

    // MARK: Words

    func testHoverTextAndPercent() {
        let parts = SplitBar.segments(from: [item(.swift, 10_000_000_000, tier: .safe), item(.swift, 4_000_000_000, tier: .review),
                                             item(.javascript, 17_000_000_000, tier: .review)])
        XCTAssertEqual(parts[0].hoverText, "JavaScript & TypeScript · 17 GB · 55%", "The hover uses the full name. The legend uses the short one.")
        XCTAssertEqual(parts[1].hoverText, "Xcode & Swift · 14 GB · 45% · 10 GB safe")
        XCTAssertTrue(parts[1].accessibilityLabel.hasPrefix("Xcode & Swift, 14 GB, 45 percent"))
    }

    func testPercentRoundsAndSaysLessThanOne() {
        func share(_ s: Double) -> SplitSegment {
            SplitSegment(ecosystems: [.go], name: "Go", shortName: "Go", bytes: 1, safeBytes: 1, share: s, isOther: false)
        }
        XCTAssertEqual(share(0.004).percentText, "<1%")
        XCTAssertEqual(share(0.004).accessibilityLabel.contains("less than 1 percent"), true)
        XCTAssertEqual(share(0.01).percentText, "1%")
        XCTAssertEqual(share(0.314).percentText, "31%")
        XCTAssertEqual(share(0.315).percentText, "32%")
        XCTAssertEqual(share(1).percentText, "100%")
    }

    func testEveryGroupHasADistinctShortName() {
        let names = Ecosystem.allCases.map(\.shortName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty && $0.count <= 10 }, "Short enough for the legend")
    }

    // MARK: Layout and hit test

    private func parts(_ shares: [Double]) -> [SplitSegment] {
        shares.enumerated().map { i, s in
            SplitSegment(ecosystems: [Ecosystem.allCases[i]], name: "n\(i)", shortName: "n\(i)", bytes: Int64(s * 1000),
                         safeBytes: 0, share: s, isOther: false)
        }
    }

    func testTheLayoutFillsTheWholeWidthExactly() {
        for shares in [[1.0], [0.5, 0.5], [0.7, 0.2, 0.1], [0.97, 0.02, 0.005, 0.005], [0.2, 0.2, 0.2, 0.2, 0.2]] {
            let slots = SplitBar.layout(parts(shares), width: 268, gap: 1.5, minWidth: 4)
            XCTAssertEqual(slots.count, shares.count)
            let end = slots.last!.x + slots.last!.width
            XCTAssertEqual(end, 268, accuracy: 0.001, "\(shares)")
            for (a, b) in zip(slots, slots.dropFirst()) { XCTAssertEqual(b.x - (a.x + a.width), 1.5, accuracy: 0.001, "The gap") }
            XCTAssertTrue(slots.allSatisfy { $0.width >= 4 - 0.001 }, "Every part can be seen and chosen: \(shares)")
        }
        XCTAssertTrue(SplitBar.layout([], width: 268).isEmpty)
    }

    func testTheWidthsFollowTheShares() {
        let slots = SplitBar.layout(parts([0.6, 0.3, 0.1]), width: 300, gap: 0, minWidth: 4)
        XCTAssertEqual(slots[0].width, 180, accuracy: 0.001)
        XCTAssertEqual(slots[1].width, 90, accuracy: 0.001)
        XCTAssertEqual(slots[2].width, 30, accuracy: 0.001)
    }

    func testATinyPartIsRaisedToTheMinimumAndTheLargeOnesGiveTheSpace() {
        let slots = SplitBar.layout(parts([0.999, 0.001]), width: 200, gap: 0, minWidth: 4)
        XCTAssertEqual(slots[1].width, 4, accuracy: 0.001)
        XCTAssertEqual(slots[0].width, 196, accuracy: 0.001)
    }

    func testHitTest() {
        let slots = SplitBar.layout(parts([0.5, 0.3, 0.2]), width: 100, gap: 2, minWidth: 4)
        XCTAssertEqual(SplitBar.hit(slots, x: 5), 0)
        XCTAssertEqual(SplitBar.hit(slots, x: slots[1].x + 1), 1)
        XCTAssertEqual(SplitBar.hit(slots, x: slots[2].x + slots[2].width - 0.5), 2)
        XCTAssertNil(SplitBar.hit(slots, x: -10), "Far to the left of the bar")
        XCTAssertNil(SplitBar.hit(slots, x: 500))
        // A point inside a part belongs to that part. A point in a gap, close to a thin part, still counts for it.
        let thin = SplitBar.layout(parts([0.99, 0.01]), width: 100, gap: 3, minWidth: 4)
        XCTAssertEqual(SplitBar.hit(thin, x: thin[0].x + 10), 0)
        XCTAssertEqual(SplitBar.hit(thin, x: thin[0].x + thin[0].width - 0.5), 0, "Inside the large part")
        XCTAssertEqual(SplitBar.hit(thin, x: thin[1].x - 0.5), 1, "In the gap, 0.5 from the thin part")
        XCTAssertNil(SplitBar.hit(thin, x: thin[1].x + thin[1].width + 5), "Beyond the end of the bar")
        XCTAssertNil(SplitBar.hit(SplitBar.layout(parts([0.5, 0.5]), width: 100, gap: 20, minWidth: 4), x: 50),
                     "The middle of a wide gap is nothing")
    }

    func testEveryPointOfTheBarHitsSomething() {
        let slots = SplitBar.layout(parts([0.4, 0.3, 0.2, 0.1]), width: 268, gap: 1.5, minWidth: 4)
        for x in stride(from: CGFloat(0), through: 268, by: 0.5) {
            XCTAssertNotNil(SplitBar.hit(slots, x: x), "x = \(x)")
        }
    }

    // MARK: The same size words everywhere

    func testTheSizeWordsAreOneThing() {
        XCTAssertEqual(ByteText.string(0), "0 KB")
        XCTAssertEqual(ByteText.string(999), "0 KB")
        XCTAssertEqual(ByteText.string(1_500), "2 KB")
        XCTAssertEqual(ByteText.string(2_500_000), "2 MB")
        XCTAssertEqual(ByteText.string(1_500_000_000), "1.5 GB")
        XCTAssertEqual(ByteText.string(12_300_000_000), "12 GB")
        XCTAssertEqual(ByteText.string(1_500_000_000_000), "1.5 TB")
        XCTAssertEqual(ByteText.string(-5), "0 KB")
    }
}
