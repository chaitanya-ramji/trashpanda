import XCTest
@testable import PandaCore

/// Property tests for everything that decides what the bar, the legend and the line under the title show.
/// The inputs come from a generator with a fixed seed, so a failure can be run again.
final class BarPropertyTests: XCTestCase {
    /// A small generator with a seed (SplitMix64). The same seed gives the same numbers.
    struct Generator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func chance(_ p: Double) -> Bool { unit() < p }
        mutating func shuffled<T>(_ items: [T]) -> [T] {
            var a = items
            for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, int(0..<(i + 1))) }
            return a
        }
    }

    private static let owners = [AppOwner(name: "App A", bundleIDs: ["test.a"]), AppOwner(name: "App B", bundleIDs: ["test.b"]),
                                 AppOwner(name: "App C", bundleIDs: ["test.c"])]

    struct Case {
        var findings: [Finding]
        var running: RunningSnapshot
        var blockers: (Finding) -> [String] { { f in f.owner.map { running.running($0) } ?? [] } }
    }

    /// Findings of random groups, sizes (1 KB to 30 GB), tiers, owners, info lines and upper limits.
    static func makeCase(seed: UInt64, maxItems: Int = 60) -> Case {
        var g = Generator(seed: seed)
        let groups = Ecosystem.allCases
        // Some cases use only a few groups, so the same group has many items. Some use many groups.
        let pool = Array(g.shuffled(groups).prefix(g.int(1..<groups.count + 1)))
        var findings: [Finding] = []
        for i in 0..<g.int(0..<maxItems) {
            let eco = pool[g.int(0..<pool.count)]
            let bytes = Int64(pow(10, 3 + g.unit() * 7.5))
            let action: Action = g.chance(0.08) ? .inform : .removeContents(URL(fileURLWithPath: "/x/\(i)"))
            let owner = g.chance(0.5) ? owners[g.int(0..<owners.count)] : nil
            findings.append(Finding(id: "f\(i)", ecosystem: eco, title: "t\(i)", location: "/x/\(i)", bytes: g.chance(0.05) ? 0 : bytes,
                                    tier: g.chance(0.5) ? .safe : .review, rebuild: .download, action: action, owner: owner,
                                    sizeIsUpperLimit: g.chance(0.1)))
        }
        let apps = zip(["test.a", "test.b", "test.c"], ["App A", "App B", "App C"]).filter { _ in g.chance(0.4) }
            .map { RunningApp(bundleID: $0.0, name: $0.1) }
        return Case(findings: findings, running: RunningSnapshot(apps: apps))
    }

    private let seeds: [UInt64] = Array(1...400)

    private func counted(_ c: Case) -> Int64 { c.findings.filter { $0.isActionable }.reduce(0) { $0 + $1.countedBytes } }

    // MARK: The parts

    func testThePartsAddUpToTheTotalAndNoGroupIsLost() {
        for seed in seeds {
            let c = Self.makeCase(seed: seed)
            let parts = SplitBar.segments(from: c.findings, blockers: c.blockers)
            let total = counted(c)
            XCTAssertEqual(parts.reduce(0) { $0 + $1.bytes }, total, "seed \(seed)")
            XCTAssertEqual(parts.isEmpty, total == 0, "seed \(seed)")
            XCTAssertEqual(parts.reduce(0.0) { $0 + $1.share }, total > 0 ? 1 : 0, accuracy: 1e-9, "seed \(seed)")
            // Every group with data is in exactly one part. A group without counted data is in none.
            var seen: [Ecosystem: Int] = [:]
            for p in parts { for e in p.ecosystems { seen[e, default: 0] += 1 } }
            var expected = Set<Ecosystem>()
            for f in c.findings where f.isActionable && f.countedBytes > 0 { expected.insert(f.ecosystem) }
            XCTAssertEqual(Set(seen.keys), expected, "seed \(seed)")
            XCTAssertTrue(seen.values.allSatisfy { $0 == 1 }, "seed \(seed): a group is in two parts")
            for p in parts {
                XCTAssertGreaterThan(p.bytes, 0, "seed \(seed): a part without bytes")
                XCTAssertEqual(p.safeBytes + p.blockedBytes + p.reviewBytes, p.bytes, "seed \(seed) \(p.name)")
                XCTAssertGreaterThanOrEqual(p.safeBytes, 0)
                XCTAssertGreaterThanOrEqual(p.reviewBytes, 0)
                XCTAssertEqual(p.blockedBytes > 0, !p.blockingApps.isEmpty, "seed \(seed): blocked bytes and app names agree")
                XCTAssertEqual(p.isOther, p.name == "Other")
            }
        }
    }

    func testTheResultDoesNotDependOnTheOrderOfTheFindings() {
        for seed in seeds {
            let c = Self.makeCase(seed: seed)
            var g = Generator(seed: seed &+ 1000)
            let a = SplitBar.segments(from: c.findings, blockers: c.blockers)
            let b = SplitBar.segments(from: g.shuffled(c.findings), blockers: c.blockers)
            let again = SplitBar.segments(from: c.findings, blockers: c.blockers)
            XCTAssertEqual(a, b, "seed \(seed): the order of the findings changes the bar")
            XCTAssertEqual(a, again, "seed \(seed)")
            XCTAssertEqual(SplitBar.totals(from: c.findings, blockers: c.blockers), SplitBar.totals(from: g.shuffled(c.findings), blockers: c.blockers))
            XCTAssertEqual(SplitBar.colorSlots(for: a), SplitBar.colorSlots(for: b), "seed \(seed)")
        }
    }

    func testTheOrderIsSizeDescendingThenNameAndOtherIsLast() {
        for seed in seeds {
            let c = Self.makeCase(seed: seed)
            let parts = SplitBar.segments(from: c.findings, blockers: c.blockers)
            let named = parts.filter { !$0.isOther }
            for (a, b) in zip(named, named.dropFirst()) {
                XCTAssertTrue(a.bytes > b.bytes || (a.bytes == b.bytes && a.name < b.name), "seed \(seed): \(a.name) before \(b.name)")
            }
            if let other = parts.firstIndex(where: \.isOther) { XCTAssertEqual(other, parts.count - 1, "seed \(seed)") }
            XCTAssertLessThanOrEqual(named.count, 8, "seed \(seed)")
            // A named part is never smaller than 100 MB and 1 percent at once.
            let total = counted(c)
            for p in named { XCTAssertTrue(p.bytes >= 100_000_000 || Double(p.bytes) / Double(total) >= 0.01, "seed \(seed) \(p.name)") }
            // The folded groups are the ones that did not make the main list: none of them is larger than the smallest named one,
            // unless the limit of 8 or the size rule cut it.
            if let other = parts.last, other.isOther, other.ecosystems.count > 1 {
                XCTAssertEqual(other.bytes, other.ecosystems.reduce(Int64(0)) { sum, e in
                    sum + c.findings.filter { $0.ecosystem == e && $0.isActionable }.reduce(0) { $0 + $1.countedBytes }
                }, "seed \(seed)")
            }
        }
    }

    func testBlockedBytesAreTheItemsOfOpenAppsAndInfoRowsAndUpperLimitsNeverCount() {
        for seed in seeds {
            let c = Self.makeCase(seed: seed)
            let parts = SplitBar.segments(from: c.findings, blockers: c.blockers)
            let expectedBlocked = c.findings.filter { $0.isActionable && !c.blockers($0).isEmpty }.reduce(0) { $0 + $1.countedBytes }
            XCTAssertEqual(parts.reduce(0) { $0 + $1.blockedBytes }, expectedBlocked, "seed \(seed)")
            let expectedSafe = c.findings.filter { $0.isActionable && $0.tier == .safe && c.blockers($0).isEmpty }.reduce(0) { $0 + $1.countedBytes }
            XCTAssertEqual(parts.reduce(0) { $0 + $1.safeBytes }, expectedSafe, "seed \(seed)")
            // Only the open apps that block data of a part are named in it.
            for p in parts {
                var names = Set<String>()
                for f in c.findings where p.ecosystems.contains(f.ecosystem) && f.isActionable && f.countedBytes > 0 { names.formUnion(c.blockers(f)) }
                XCTAssertEqual(p.blockingApps, names.sorted(), "seed \(seed) \(p.name)")
            }
        }
    }

    // MARK: The line under the title

    func testTheLineUnderTheTitleHasTheNumbersOfTheBar() {
        for seed in seeds {
            let c = Self.makeCase(seed: seed)
            let parts = SplitBar.segments(from: c.findings, blockers: c.blockers)
            let totals = SplitBar.totals(from: c.findings, blockers: c.blockers)
            XCTAssertEqual(totals.all, parts.reduce(0) { $0 + $1.bytes }, "seed \(seed): the totals are the bar")
            XCTAssertEqual(totals.waiting, parts.reduce(0) { $0 + $1.blockedBytes }, "seed \(seed): open apps are the blocked parts")
            XCTAssertEqual(totals.free, parts.reduce(0) { $0 + $1.safeBytes }, "seed \(seed)")
            XCTAssertEqual(totals.review, parts.reduce(0) { $0 + $1.reviewBytes }, "seed \(seed)")
            for compact in [false, true] {
                let text = totals.summary(compact: compact)
                if totals.all == 0 {
                    XCTAssertEqual(text, "All tidy. Nothing to clean.")
                    continue
                }
                for (value, word) in [(totals.free, "free"), (totals.review, "review"), (totals.waiting, "open")] {
                    let number = ByteText.string(value)
                    if value > 0 { XCTAssertTrue(text.contains(number), "seed \(seed): \(text) has no \(number) for \(word)") }
                }
                XCTAssertEqual(text.components(separatedBy: " · ").count, [totals.free, totals.review, totals.waiting].filter { $0 > 0 }.count,
                               "seed \(seed): one phrase for each total that is not zero")
            }
        }
    }

    func testTheCompactSummaryIsNeverLongerThanTheLongOne() {
        for seed in seeds {
            var g = Generator(seed: seed)
            let t = SplitTotals(free: Int64(g.int(0..<3)) * 123_000_000, review: Int64(g.int(0..<3)) * 456_000_000,
                                waiting: Int64(g.int(0..<3)) * 1_100_000_000)
            XCTAssertLessThanOrEqual(t.summary(compact: true).count, t.summary().count, "\(t)")
        }
    }

    // MARK: The words of a part

    func testTheHoverTextAndTheVoiceOverTextSayWhatTheBarShows() {
        for seed in seeds {
            let c = Self.makeCase(seed: seed)
            for p in SplitBar.segments(from: c.findings, blockers: c.blockers) {
                let hover = p.hoverText
                XCTAssertTrue(hover.hasPrefix(p.name), "seed \(seed)")
                XCTAssertTrue(hover.contains(ByteText.string(p.bytes)), "seed \(seed)")
                XCTAssertTrue(hover.contains(p.percentText), "seed \(seed)")
                XCTAssertTrue(p.hoverText(shortName: true).hasPrefix(p.shortName))
                XCTAssertTrue(p.accessibilityLabel.contains(ByteText.string(p.bytes)), "seed \(seed)")
                if p.reviewBytes > 0 {
                    XCTAssertTrue(hover.contains("look through"), "seed \(seed): the pale share is named: \(hover)")
                    XCTAssertTrue(p.accessibilityLabel.contains("look through"), "seed \(seed)")
                } else {
                    XCTAssertFalse(hover.contains("look through"), "seed \(seed): \(hover)")
                }
                if p.blockedBytes > 0 { XCTAssertTrue(hover.contains("quit"), "seed \(seed): \(hover)") } else { XCTAssertFalse(hover.contains("quit")) }
                if p.safeBytes > 0 && p.safeBytes < p.bytes { XCTAssertTrue(hover.contains("\(ByteText.string(p.safeBytes)) safe"), "seed \(seed)") }
            }
        }
    }

    // MARK: Layout, hit test, legend

    func testTheLayoutFillsTheWidthExactlyAndEveryPartCanBeSeen() {
        for seed in seeds {
            let c = Self.makeCase(seed: seed)
            let parts = SplitBar.segments(from: c.findings, blockers: c.blockers)
            guard !parts.isEmpty else { continue }
            for width: CGFloat in [300 - 36, 307 - 36, 372 - 36, 520] {
                let slots = SplitBar.layout(parts, width: width)
                XCTAssertEqual(slots.count, parts.count)
                let end = slots.last.map { $0.x + $0.width } ?? 0
                XCTAssertEqual(end, width, accuracy: 0.001, "seed \(seed) width \(width): the parts and gaps fill the bar")
                for (a, b) in zip(slots, slots.dropFirst()) {
                    XCTAssertEqual(b.x - (a.x + a.width), 1.5, accuracy: 0.001, "seed \(seed): the gap")
                }
                XCTAssertEqual(slots.first?.x, 0)
                for (i, s) in slots.enumerated() {
                    XCTAssertGreaterThanOrEqual(s.width, 4 - 0.001, "seed \(seed) width \(width): part \(i) is too thin to see or choose")
                    // The middle of a part chooses that part.
                    XCTAssertEqual(SplitBar.hit(slots, x: s.x + s.width / 2), i, "seed \(seed)")
                }
                // Wider shares give wider parts, or an equal width.
                for (a, b) in zip(parts.indices, parts.indices.dropFirst()) where parts[a].share > parts[b].share {
                    XCTAssertGreaterThanOrEqual(slots[a].width, slots[b].width - 0.001, "seed \(seed): a larger part is not thinner")
                }
            }
        }
    }

    func testThePartWidthsAddUpToThePartWidth() {
        for seed in seeds {
            let c = Self.makeCase(seed: seed)
            for p in SplitBar.segments(from: c.findings, blockers: c.blockers) {
                for width: CGFloat in [4, 17.3, 90, 211.5] {
                    let w = SplitBar.partWidths(p, width: width)
                    XCTAssertEqual(w.safe + w.review + w.blocked, width, accuracy: 0.0001, "seed \(seed)")
                    XCTAssertGreaterThanOrEqual(w.safe, 0)
                    XCTAssertGreaterThanOrEqual(w.review, 0)
                    XCTAssertGreaterThanOrEqual(w.blocked, 0)
                }
            }
        }
    }

    func testTheLegendNamesTheLargestPartsFirstAndAllOfThemAreInTheBar() {
        for seed in seeds {
            var g = Generator(seed: seed)
            let c = Self.makeCase(seed: seed)
            let parts = SplitBar.segments(from: c.findings, blockers: c.blockers)
            let widths = parts.map { _ in CGFloat(g.int(60..<120)) }
            let room = CGFloat(g.int(120..<400))
            let more: (Int) -> CGFloat = { n in CGFloat("+\(n) more".count) * 5 }
            let shown = SplitBar.legendCount(entryWidths: widths, separator: 8, moreWidth: more, room: room)
            XCTAssertLessThanOrEqual(shown, parts.count)
            // What is shown fits, with the "+N more" text when parts are left out.
            let used = widths.prefix(shown).reduce(0, +)
            let left = parts.count - shown
            XCTAssertLessThanOrEqual(left > 0 ? used + more(left) : used - 8, room + 0.001, "seed \(seed)")
            // One more entry would not fit.
            if shown < parts.count {
                let next = widths.prefix(shown + 1).reduce(0, +)
                let leftAfter = parts.count - shown - 1
                XCTAssertGreaterThan(leftAfter > 0 ? next + more(leftAfter) : next - 8, room, "seed \(seed): the legend could name one more part")
            }
            // The named entries are the first ones, so they are the largest ones (Other is last).
            let named = parts.prefix(shown)
            for p in named where !p.isOther {
                XCTAssertTrue(parts.contains(p))
            }
            for (a, b) in zip(named, named.dropFirst()) where !b.isOther { XCTAssertGreaterThanOrEqual(a.bytes, b.bytes) }
        }
    }

    func testTheShortNamesAndNamesOfTheGroupsAreUnique() {
        XCTAssertEqual(Set(Ecosystem.allCases.map(\.name)).count, Ecosystem.allCases.count)
        XCTAssertEqual(Set(Ecosystem.allCases.map(\.shortName)).count, Ecosystem.allCases.count, "two groups with one short name look the same in the legend")
    }

    // MARK: Colors

    func testAGroupKeepsItsColorWhenOnlyItsSizeChangesAndNoTwoNamedPartsShareOne() {
        for seed in seeds {
            let c = Self.makeCase(seed: seed)
            let parts = SplitBar.segments(from: c.findings, blockers: c.blockers)
            let slots = SplitBar.colorSlots(for: parts)
            let named = zip(parts, slots).filter { !$0.0.isOther }
            XCTAssertEqual(Set(named.compactMap { $0.1 }).count, named.count, "seed \(seed): two parts have one color")
            XCTAssertTrue(zip(parts, slots).allSatisfy { $0.0.isOther == ($0.1 == nil) }, "seed \(seed): only Other has no slot")
            // A group has the slot of its place in the list of groups, unless a larger group of the same bar wants that slot too.
            // (Another group that was moved must not take its slot.)
            for p in named {
                let wanted = Self.wants(p.0.ecosystems[0])
                let beaten = named.contains { other in
                    other.0.ecosystems[0] != p.0.ecosystems[0] && Self.wants(other.0.ecosystems[0]) == wanted
                        && (other.0.bytes > p.0.bytes || (other.0.bytes == p.0.bytes && other.0.name < p.0.name))
                }
                if !beaten { XCTAssertEqual(p.1, wanted, "seed \(seed): \(p.0.name) was moved, and no larger group wants its slot") }
            }
        }
    }

    private static func wants(_ e: Ecosystem) -> Int { (Ecosystem.allCases.firstIndex(of: e) ?? 0) % 8 }

    // MARK: The bar and the rows of the menu

    func testTheRowsOfTheMenuAreThePartsOfTheBar() throws {
        for seed in seeds {
            let c = Self.makeCase(seed: seed)
            let disk = DiskUsage(total: 500_000_000_000, free: 100_000_000_000)
            let model = MenuModel.make(MenuInput(result: ScanResult(findings: c.findings, disk: disk), disk: disk, scanning: false,
                                                 cleaning: false, running: c.running, staleDays: 90))
            let parts = model.header.segments
            let rows = model.rows.filter { $0.kind == .columns }
            XCTAssertEqual(rows.count, parts.count, "seed \(seed): one row for each part")
            let slots = SplitBar.colorSlots(for: parts)
            for (i, (row, part)) in zip(rows, parts).enumerated() {
                XCTAssertEqual(row.title, part.isOther ? "Smaller groups" : part.name, "seed \(seed) row \(i)")
                XCTAssertEqual(row.size, ByteText.string(part.bytes), "seed \(seed): the row and the part have one number")
                if part.isOther {
                    XCTAssertNil(row.icon)
                    // The folded rows add up to the part.
                    let inner = try XCTUnwrap(row.submenu).rows.filter { $0.kind == .columns }
                    XCTAssertEqual(inner.count, part.ecosystems.count, "seed \(seed)")
                } else {
                    XCTAssertEqual(row.icon, .groupColor(slot: try XCTUnwrap(slots[i])), "seed \(seed): the row has the color of its part")
                }
            }
            // The main row of the menu frees what the line under the title calls "free now".
            XCTAssertEqual(model.header.totals, SplitBar.totals(from: c.findings.filter(\.isActionable), blockers: model.blockersForTests(c)), "seed \(seed)")
        }
    }
}

private extension MenuModel {
    /// The blockers that the model used, for the test.
    func blockersForTests(_ c: BarPropertyTests.Case) -> (Finding) -> [String] { c.blockers }
}
