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

    func testBlockedItemsStayInTheBarAndInformationLinesDoNot() {
        let blocked = item(.swift, 4_000_000_000)
        let findings = [blocked, item(.swift, 1_000_000_000, action: .inform),   // information only
                        item(.javascript, 3_000_000_000), item(.python, 0)]       // nothing to free
        let parts = SplitBar.segments(from: findings, blockers: { $0.id == blocked.id ? ["Xcode"] : [] })
        XCTAssertEqual(parts.map(\.shortName), ["Xcode", "JavaScript"])
        guard parts.count == 2 else { return XCTFail("The blocked group must have its part") }
        XCTAssertEqual(parts[0].bytes, 4_000_000_000, "The information line is not in the part")
        XCTAssertTrue(parts[0].isBlockedOnly)
        XCTAssertEqual(parts[0].safeBytes, 0, "Free up does not take an item of an open app")
        XCTAssertFalse(parts[1].isBlockedOnly)
    }

    func testNothingToCleanGivesNoBar() {
        XCTAssertTrue(SplitBar.segments(from: []).isEmpty)
        XCTAssertTrue(SplitBar.segments(from: [item(.swift, 100, action: .inform)]).isEmpty)
        XCTAssertTrue(SplitBar.totals(from: [item(.swift, 100, action: .inform)]).summary() == "All tidy. Nothing to clean.")
    }

    // MARK: The bar matches the rows of the menu

    /// The menu of the bug report: the bar showed only JavaScript and Homebrew,
    /// but the rows below it also listed Browser caches and AI agents with a size.
    private let mib: Int64 = 1_000_000
    private func reportedMenu() -> (findings: [Finding], blockers: (Finding) -> [String]) {
        var findings = [
            item(.javascript, 1_400 * mib), item(.javascript, 1_400 * mib, tier: .review),
            item(.homebrew, 40 * mib),
            item(.aiAgents, 93 * mib), item(.aiAgents, 100 * mib, tier: .review),
            item(.cacheExplorer, 5_000 * mib, action: .inform),                                   // information only
            item(.docker, 0, action: .inform), item(.docker, 700 * mib, action: .inform),        // only info lines
        ]
        let browser = [item(.browsers, 228 * mib), item(.browsers, 70 * mib, tier: .review)]
        findings += browser
        let browserIDs = Set(browser.map(\.id)), claudeID = findings[4].id
        return (findings, { f in
            if browserIDs.contains(f.id) { return ["Safari"] }
            return f.id == claudeID ? ["Claude"] : []
        })
    }

    func testThePartsAreTheGroupRowsThatShowASize() {
        let (findings, blockers) = reportedMenu()
        let parts = SplitBar.segments(from: findings, blockers: blockers)
        // One part for each row with a size, with the number of the row.
        let rows = Dictionary(grouping: findings, by: \.ecosystem).mapValues(SplitBar.rowBytes).filter { $0.value > 0 }
        XCTAssertEqual(Set(parts.flatMap(\.ecosystems)), Set(rows.keys))
        for p in parts { XCTAssertEqual(p.bytes, rows[p.ecosystems[0]], p.name) }
        XCTAssertEqual(parts.map(\.bytes).reduce(0, +), rows.values.reduce(0, +))
        XCTAssertEqual(parts.map(\.shortName), ["JavaScript", "Browsers", "AI agents", "Homebrew"], "The largest first")
        XCTAssertEqual(parts.map(\.share).reduce(0, +), 1.0, accuracy: 1e-9)
    }

    func testAnInformationOnlyGroupHasNoPart() {
        let (findings, blockers) = reportedMenu()
        let groups = SplitBar.segments(from: findings, blockers: blockers).flatMap(\.ecosystems)
        XCTAssertFalse(groups.contains(.cacheExplorer))
        XCTAssertFalse(groups.contains(.docker))
        XCTAssertEqual(SplitBar.rowBytes(findings.filter { $0.ecosystem == .docker }), 0, "The row says info")
    }

    func testABlockedOnlyGroupHasAMarkedPart() throws {
        let (findings, blockers) = reportedMenu()
        let parts = SplitBar.segments(from: findings, blockers: blockers)
        let browsers = try XCTUnwrap(parts.first { $0.ecosystems == [.browsers] })
        XCTAssertEqual(browsers.bytes, 298 * mib)
        XCTAssertTrue(browsers.isBlockedOnly)
        XCTAssertEqual(browsers.blockingApps, ["Safari"])
        XCTAssertEqual(browsers.safeBytes, 0)
        XCTAssertEqual(browsers.hoverText, "Browser caches · 298 MB · 9% · quit Safari to clean")
        XCTAssertTrue(browsers.accessibilityLabel.hasSuffix(", quit Safari to clean"))

        let agents = try XCTUnwrap(parts.first { $0.ecosystems == [.aiAgents] })
        XCTAssertFalse(agents.isBlockedOnly)
        XCTAssertEqual(agents.blockedBytes, 100 * mib)
        XCTAssertEqual(agents.safeBytes, 93 * mib)
        XCTAssertEqual(agents.hoverText, "AI agents & local models · 193 MB · 6% · 93 MB safe · quit Claude to clean 100 MB")
        XCTAssertEqual(agents.hoverText(shortName: true), "AI agents · 193 MB · 6% · 93 MB safe · quit Claude to clean 100 MB")

        let js = parts[0]
        XCTAssertEqual(js.blockedBytes, 0)
        XCTAssertEqual(js.hoverText, "JavaScript & TypeScript · 2.8 GB · 84% · 1.4 GB safe", "No quit words when no app blocks it")
    }

    func testTheLineUnderTheTitleCountsEveryRowOnce() {
        let (findings, blockers) = reportedMenu()
        let totals = SplitBar.totals(from: findings, blockers: blockers)
        XCTAssertEqual(totals.free, (1_400 + 40 + 93) * mib, "Only safe items that need no quit")
        XCTAssertEqual(totals.review, 1_400 * mib)
        XCTAssertEqual(totals.waiting, (298 + 100) * mib, "Items of open apps do not vanish")
        XCTAssertEqual(totals.all, SplitBar.segments(from: findings, blockers: blockers).map(\.bytes).reduce(0, +),
                       "The three totals are the whole bar")
        XCTAssertEqual(totals.summary(), "You can free 1.5 GB now · 1.4 GB to look through · 398 MB when apps quit")
        XCTAssertEqual(totals.summary(compact: true), "Free 1.5 GB now · 1.4 GB to review · 398 MB in open apps")
        // With no open app, the words are the same as before.
        let none = SplitBar.totals(from: findings)
        XCTAssertEqual(none.waiting, 0)
        XCTAssertEqual(none.summary(), "You can free 1.8 GB now · 1.6 GB to look through")
        XCTAssertEqual(SplitTotals(free: 0, review: 5 * mib, waiting: 0).summary(), "5 MB to look through")
        XCTAssertEqual(SplitTotals(free: 0, review: 0, waiting: 5 * mib).summary(), "5 MB when apps quit")
    }

    func testTheBarFollowsTheOpenApps() throws {
        let (findings, blockers) = reportedMenu()
        // Safari quits: the browser part is a plain part again, and its safe data can be freed now.
        let after = SplitBar.segments(from: findings, blockers: { blockers($0) == ["Safari"] ? [] : blockers($0) })
        let browsers = try XCTUnwrap(after.first { $0.ecosystems == [.browsers] })
        XCTAssertFalse(browsers.isBlockedOnly)
        XCTAssertEqual(browsers.blockedBytes, 0)
        XCTAssertEqual(browsers.safeBytes, 228 * mib)
        XCTAssertEqual(after.map(\.bytes), SplitBar.segments(from: findings, blockers: blockers).map(\.bytes),
                       "The sizes stay the same. Only the marks change.")
    }

    func testTheOrderIsStableWithBlockedItemsAndTies() {
        let (findings, blockers) = reportedMenu()
        let first = SplitBar.segments(from: findings, blockers: blockers)
        for _ in 0..<5 { XCTAssertEqual(SplitBar.segments(from: findings.shuffled(), blockers: blockers), first) }
        // Equal sizes, one of them blocked: the tie is broken by name, not by the open app.
        let tie = [item(.rust, 100), item(.go, 100), item(.python, 100)]
        let names = SplitBar.segments(from: tie, blockers: { $0.ecosystem == .go ? ["GoLand"] : [] }).map(\.shortName)
        XCTAssertEqual(names, ["Go", "Python", "Rust"])
    }

    func testOtherJoinsTheBlockedDataOfItsGroups() throws {
        // Ten groups: the largest eight stay. The last two are one part.
        let sizes: [(Ecosystem, Int64)] = [(.swift, 100), (.javascript, 90), (.python, 80), (.rust, 70), (.go, 60),
                                           (.docker, 50), (.php, 40), (.jvm, 30), (.ruby, 20), (.dart, 10)]
        let findings = sizes.map { item($0.0, $0.1 * 1_000_000) }
        let parts = SplitBar.segments(from: findings, blockers: { $0.ecosystem == .ruby ? ["RubyMine"] : [] }, limit: 8, minimumBytes: 0)
        let other = try XCTUnwrap(parts.last)
        XCTAssertTrue(other.isOther)
        XCTAssertEqual(other.bytes, 30_000_000)
        XCTAssertEqual(other.blockedBytes, 20_000_000)
        XCTAssertEqual(other.blockingApps, ["RubyMine"])
        XCTAssertFalse(other.isBlockedOnly)
    }

    func testTheSmallGroupsAreJoinedAsOther() {
        // Ten groups: eight stay. The other two are one part, the same ones that "Smaller groups" holds.
        let sizes: [(Ecosystem, Int64)] = [(.swift, 100), (.javascript, 90), (.python, 80), (.rust, 70), (.go, 60),
                                           (.docker, 50), (.php, 40), (.jvm, 30), (.ruby, 20), (.dart, 10)]
        let findings = sizes.map { item($0.0, $0.1 * 1_000_000) }
        let parts = SplitBar.segments(from: findings, minimumBytes: 0)
        XCTAssertEqual(parts.count, 9)
        XCTAssertEqual(parts.dropLast().map(\.shortName).count, 8)
        let other = parts.last!
        XCTAssertTrue(other.isOther)
        XCTAssertEqual(other.name, "Other")
        XCTAssertEqual(Set(other.ecosystems), [.ruby, .dart])
        XCTAssertEqual(parts.map(\.bytes).reduce(0, +), 550_000_000)
        let fold = SplitBar.fold(sizes.map { ($0.0, $0.1 * 1_000_000) }, minimumBytes: 0)
        XCTAssertEqual(fold.folded.map(\.0), other.ecosystems)
        XCTAssertEqual(fold.main.map(\.0), parts.dropLast().flatMap(\.ecosystems))
    }

    func testAGroupBelowTheMinimumIsOtherEvenWhenTheListIsShort() throws {
        let parts = SplitBar.segments(from: [item(.swift, 5_000_000_000), item(.go, 30_000_000)])
        XCTAssertEqual(parts.map(\.shortName), ["Xcode", "Other"])
        XCTAssertEqual(try XCTUnwrap(parts.last).ecosystems, [.go])
    }

    // MARK: Fold

    private func rows(_ count: Int, mb: Int64 = 200) -> [(Ecosystem, Int64)] {
        Array(Ecosystem.allCases.prefix(count).enumerated().map { ($1, Int64(count - $0) * mb * 1_000_000) })
    }

    func testFoldOfNoRowsAndOneRow() {
        let none = SplitBar.fold([])
        XCTAssertTrue(none.main.isEmpty && none.folded.isEmpty)
        let one = SplitBar.fold(rows(1))
        XCTAssertEqual(one.main.count, 1)
        XCTAssertTrue(one.folded.isEmpty)
    }

    func testFoldKeepsTheLargestEight() {
        let eight = SplitBar.fold(rows(8))
        XCTAssertEqual(eight.main.count, 8)
        XCTAssertTrue(eight.folded.isEmpty)
        let nine = SplitBar.fold(rows(9))
        XCTAssertEqual(nine.main.count, 8)
        XCTAssertEqual(nine.folded.map(\.0), [rows(9)[8].0], "The smallest one is folded")
        let all = Ecosystem.allCases.count
        let many = SplitBar.fold(rows(all, mb: 150))
        XCTAssertEqual(many.main.count, 8)
        XCTAssertEqual(many.folded.count, all - 8)
        XCTAssertGreaterThanOrEqual(many.main.last!.1, many.folded.first!.1, "Both lists start with the largest")
    }

    func testFoldFoldsARowBelowTheMinimumEvenInAShortList() {
        // 5 MB is less than 100 MB, and less than 1 percent of 5 GB.
        let result = SplitBar.fold([(.swift, 5_000_000_000), (.go, 5_000_000)])
        XCTAssertEqual(result.main.map(\.0), [.swift])
        XCTAssertEqual(result.folded.map(\.0), [.go])
    }

    func testFoldKeepsASmallRowThatIsOnePercentOfTheTotal() {
        let result = SplitBar.fold([(.swift, 50_000_000), (.go, 40_000_000)])
        XCTAssertEqual(result.main.count, 2, "Both are at least 1 percent of the total")
    }

    func testFoldLosesNothing() {
        for count in [0, 1, 8, 9, Ecosystem.allCases.count] {
            let input = rows(count, mb: 3)
            let result = SplitBar.fold(input)
            let sum = { (list: [(Ecosystem, Int64)]) in list.reduce(Int64(0)) { $0 + $1.1 } }
            XCTAssertEqual(sum(result.main) + sum(result.folded), sum(input), "\(count) rows")
            XCTAssertEqual(result.main.count + result.folded.count, count)
        }
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
