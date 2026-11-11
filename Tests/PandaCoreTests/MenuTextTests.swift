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
}
