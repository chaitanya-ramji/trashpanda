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
}
