import XCTest
@testable import PandaCore

/// U-10: the menu bar item has a label for VoiceOver and a tooltip.
final class MenuTextTests: XCTestCase {
    func testIdle() {
        let l = MenuText.statusLabel(free: 54_000_000_000, total: 245_000_000_000, activity: .idle)
        XCTAssertEqual(l.accessibility, "Trash Panda, 54 GB free")
        XCTAssertEqual(l.tooltip, "Trash Panda · 54 GB free of 245 GB")
    }

    func testCleaning() {
        let l = MenuText.statusLabel(free: 54_000_000_000, total: 245_000_000_000, activity: .cleaning)
        XCTAssertEqual(l.accessibility, "Trash Panda, cleaning")
        XCTAssertEqual(l.tooltip, "Trash Panda · cleaning")
    }

    func testScanning() {
        let l = MenuText.statusLabel(free: 54_000_000_000, total: 245_000_000_000, activity: .scanning)
        XCTAssertEqual(l.accessibility, "Trash Panda, scanning, 54 GB free")
        XCTAssertEqual(l.tooltip, "Trash Panda · scanning · 54 GB free of 245 GB")
    }

    func testAMiddleTruncatedTitleFitsAndKeepsItsEnds() {
        // One point for each character: easy to check by hand.
        let measure: (String) -> Double = { Double($0.count) }
        XCTAssertEqual(MenuText.middleTruncated("short", toFit: 10, measure: measure), "short")
        XCTAssertEqual(MenuText.middleTruncated("abcdefghij", toFit: 10, measure: measure), "abcdefghij")
        XCTAssertEqual(MenuText.middleTruncated("abcdefghijk", toFit: 6, measure: measure), "abc…jk")
        XCTAssertEqual(MenuText.middleTruncated("abcdefghijk", toFit: 1, measure: measure), "…")
        XCTAssertEqual(MenuText.middleTruncated("abcdefghijk", toFit: 0, measure: measure), "…")
        let long = String(repeating: "node_modules · ", count: 20)
        for room in stride(from: 12.0, through: 120.0, by: 7.0) {
            let out = MenuText.middleTruncated(long, toFit: room, measure: measure)
            XCTAssertLessThanOrEqual(measure(out), max(room, 1))
            XCTAssertTrue(out.hasPrefix("node_"))
        }
    }

    // MARK: Rebuild labels

    func testRebuildNotesAllSame() {
        let n = MenuText.rebuildNotes([.download, .download, .download])
        XCTAssertEqual(n.sectionSuffix, "re-download when needed")
        XCTAssertEqual(n.rowLabels, [nil, nil, nil])
    }

    func testRebuildNotesMixedKeepsTheOddRow() {
        let n = MenuText.rebuildNotes([.download, .download, .download, .recreate])
        XCTAssertEqual(n.sectionSuffix, "re-download when needed")
        XCTAssertEqual(n.rowLabels, [nil, nil, nil, "You would need to recreate it"])
    }

    func testRebuildNotesNoMajorityKeepsEveryLabel() {
        let n = MenuText.rebuildNotes([.seconds, .minutes])
        XCTAssertNil(n.sectionSuffix)
        XCTAssertEqual(n.rowLabels, ["Comes back in seconds", "Rebuilds in a few minutes"])
    }

    func testRebuildNotesOneRowAndEmpty() {
        XCTAssertEqual(MenuText.rebuildNotes([.minutes]), MenuText.RebuildNotes(sectionSuffix: nil, rowLabels: ["Rebuilds in a few minutes"]))
        XCTAssertEqual(MenuText.rebuildNotes([]), MenuText.RebuildNotes(sectionSuffix: nil, rowLabels: []))
    }

    func testCannotBeRecoveredIsNeverMovedToTheHeader() {
        let n = MenuText.rebuildNotes([.never, .never, .never])
        XCTAssertNil(n.sectionSuffix)
        XCTAssertEqual(n.rowLabels, ["Cannot be recovered", "Cannot be recovered", "Cannot be recovered"])
        let m = MenuText.rebuildNotes([.minutes, .minutes, .never])
        XCTAssertEqual(m.rowLabels, [nil, nil, "Cannot be recovered"])
    }

    // MARK: Friendly names

    func testFriendlyNameForAppleNames() {
        XCTAssertEqual(MenuText.friendlyName("com.apple.helpd"), "helpd (macOS)")
        XCTAssertEqual(MenuText.friendlyName("com.apple.intelligenceflow.intelligenceflowd"), "intelligenceflowd (macOS)")
        XCTAssertEqual(MenuText.friendlyName("com.apple.e5rt.e5bundlecache"), "e5bundlecache (macOS)")
    }

    func testFriendlyNameForOtherNames() {
        XCTAssertEqual(MenuText.friendlyName("com.example.Tool"), "Tool")
        XCTAssertEqual(MenuText.friendlyName("com.example.Tool.ShipIt"), "Tool")
        XCTAssertEqual(MenuText.friendlyName("org.example.thing.helper"), "thing")
    }

    func testFriendlyNameLeavesOtherNamesAlone() {
        for name in ["bun", "node_modules", "pnpm.store", "Some App", "foo.bar.baz", "com.example", "com..x", "archive.tar.gz"] {
            XCTAssertEqual(MenuText.friendlyName(name), name)
        }
    }

    func testFriendlyNameKeepsTheOriginalWhenTheShortNameMisleads() {
        for name in ["com.spotify.client", "com.example.chat", "com.example.agent", "com.example.2024", "com.example.230313mzl4w4u92",
                     "com.example.z", "com.apple.WebKit.Networking", "com.example.a.b.c.tool", "com.example.helper", "com.example.desktop"] {
            XCTAssertEqual(MenuText.friendlyName(name), name)
        }
    }

    func testFriendlyNameKeepsTheGoodCases() {
        XCTAssertEqual(MenuText.friendlyName("org.mozilla.firefox"), "firefox")
        XCTAssertEqual(MenuText.friendlyName("com.google.Chrome"), "Chrome")
        XCTAssertEqual(MenuText.friendlyName("com.google.Chrome.helper"), "Chrome")
        XCTAssertEqual(MenuText.friendlyName("com.hnc.Discord.ShipIt"), "Discord")
        XCTAssertEqual(MenuText.friendlyName("com.apple.helpd"), "helpd (macOS)")
    }

    func testRowTitle() {
        XCTAssertEqual(MenuText.rowTitle("com.apple.helpd · system cache", ecosystem: .cacheExplorer), "helpd (macOS)")
        XCTAssertEqual(MenuText.rowTitle("bun · cache folder", ecosystem: .cacheExplorer), "bun")
        XCTAssertEqual(MenuText.rowTitle("GeoServices · system cache", ecosystem: .cacheExplorer), "GeoServices (system)")
        XCTAssertEqual(MenuText.rowTitle("com.apple.helpd · system cache", ecosystem: .python), "helpd (macOS) · system cache")
        XCTAssertEqual(MenuText.rowTitle("Unused anonymous volume · 5f0999b7b512…", ecosystem: .docker), "Unused anonymous volume")
    }

    func testSecondLineBeforeMacOS144GoesOnTopOfTheTooltip() {
        XCTAssertEqual(MenuText.tooltip(withSecondLine: "Line", tooltip: "Tip"), "Line\nTip")
        XCTAssertEqual(MenuText.tooltip(withSecondLine: "Line", tooltip: nil), "Line")
        XCTAssertEqual(MenuText.tooltip(withSecondLine: nil, tooltip: "Tip"), "Tip")
        XCTAssertNil(MenuText.tooltip(withSecondLine: nil, tooltip: nil))
    }

    // MARK: Width

    func testCappedKeepsShortTextAndCutsTheMiddle() {
        XCTAssertEqual(MenuText.capped("short"), "short")
        let long = String(repeating: "a", count: 30) + String(repeating: "b", count: 30)
        let cut = MenuText.capped(long)
        XCTAssertEqual(cut.count, MenuText.maxTitle)
        XCTAssertTrue(cut.hasPrefix("aaaa") && cut.hasSuffix("bbbb") && cut.contains("…"))
    }

    // MARK: Docker place

    func testDockerPlaceDropsEngineImageAndVolumeId() {
        let p = MenuText.dockerPlace("Docker engine: Test · image app:1 · Up 22 hours · volumes: abc123abc123… · will be stopped first")
        XCTAssertEqual(p.engine, "Test")
        XCTAssertEqual(p.subtitle, "Stopped first")
        XCTAssertEqual(p.tooltip, "Test · image app:1 · Up 22 hours · will be stopped first")
        XCTAssertNil(MenuText.dockerPlace("Docker engine: Test").subtitle)
        let named = MenuText.dockerPlace("Docker engine: Test · image a:1 · Exited (0) 3 days ago · volumes: pgdata-prod, abc123abc123…")
        XCTAssertEqual(named.subtitle, "Exited (0) 3 days ago")
        XCTAssertEqual(named.tooltip, "Test · image a:1 · Exited (0) 3 days ago · volumes: pgdata-prod")
    }
}
