import AppKit
import XCTest
import PandaCore
@testable import TrashPanda

final class MenuBuilderTests: XCTestCase {
    func testAFixedModelMakesTheExpectedMenu() {
        let disk = DiskUsage(total: 500_000_000_000, free: 120_000_000_000)
        let finding = Finding(id: "1", ecosystem: .javascript, title: "node_modules · app-a", location: "~/Projects",
                              bytes: 1_300_000_000, tier: .safe, rebuild: .minutes,
                              action: .removeArtifact(URL(fileURLWithPath: "/tmp/none")))
        let input = MenuInput(result: ScanResult(findings: [finding], disk: disk), disk: disk, scanning: false,
                              cleaning: false, running: RunningSnapshot(apps: []), staleDays: 90)
        let model = MenuModel.make(input)
        let builder = MenuBuilder { _ in }
        let menu = NSMenu()
        builder.populate(menu, model: model, header: NSView())

        func text(_ item: NSMenuItem) -> String {
            item.isSeparatorItem ? "---" : (item.view != nil ? "<header>" : (item.attributedTitle?.string ?? item.title))
        }
        XCTAssertEqual(menu.items.map(text), [
            "<header>", "---", "Free up 1.3 GB…", "---", "JavaScript & TypeScript\t1.3 GB", "---", "Scan again", "Settings",
            "Quit Trash Panda",
        ])
        XCTAssertEqual(menu.items[4].submenu?.items.map(text), ["Free up 1.3 GB…", "---", "Safe to clean", "node_modules · app-a\t1.3 GB", "Show in Finder"])
        XCTAssertEqual(menu.items[7].submenu?.items.map(text), [
            "Check for updates…", "Check for updates every day", "Open at login", "---", "Open the keep list",
            "Open the project folders list", "---", "Show log in Finder", "Help", "Report a problem", "About Trash Panda",
        ])
        XCTAssertTrue(menu.items[4].submenu?.items.last?.isAlternate ?? false)
        XCTAssertFalse(menu.items.contains { $0.isAlternate })
        XCTAssertEqual(menu.items[4].image?.size, NSSize(width: 16, height: 16), "The group row has its color dot")
    }
    func testALiveUpdateChangesTwoRowsAndKeepsTheRowList() {
        let disk = DiskUsage(total: 500_000_000_000, free: 120_000_000_000)
        func finding(_ id: String, _ bytes: Int64) -> Finding {
            Finding(id: id, ecosystem: .javascript, title: "node_modules · \(id)", location: "~/Projects", bytes: bytes,
                    tier: .safe, rebuild: .minutes, action: .removeArtifact(URL(fileURLWithPath: "/tmp/none-\(id)")))
        }
        func model(_ findings: [Finding], scanning: Bool) -> MenuModel {
            MenuModel.make(MenuInput(result: ScanResult(findings: findings, disk: disk), disk: disk, scanning: scanning,
                                     cleaning: false, running: RunningSnapshot(apps: []), staleDays: 90))
        }
        let builder = MenuBuilder { _ in }
        let menu = NSMenu()
        builder.populate(menu, model: model([finding("a", 1_300_000_000)], scanning: false), header: NSView())
        let before = menu.items.map { $0.isSeparatorItem ? "---" : ($0.attributedTitle?.string ?? $0.title) }
        let group = menu.items[4]
        let submenu = group.submenu

        // A scan ends while the menu is open: a new item shows up, and a new scan starts.
        builder.updateLiveRows(model: model([finding("a", 1_300_000_000), finding("b", 2_000_000_000)], scanning: true))
        let after = menu.items.map { $0.isSeparatorItem ? "---" : ($0.attributedTitle?.string ?? $0.title) }
        XCTAssertEqual(menu.items.count, before.count)
        XCTAssertTrue(menu.items[4] === group)
        XCTAssertTrue(group.submenu === submenu)
        XCTAssertEqual(menu.items[2].title, "Free up 3.3 GB…")
        XCTAssertEqual(menu.items[6].title, "Scanning…")
        XCTAssertFalse(menu.items[6].isEnabled)
        for i in before.indices where ![2, 6].contains(i) { XCTAssertEqual(after[i], before[i]) }
    }

    /// A long title must never reach the size column. Before this, a title of 627 points had a tab of 520.
    func testLongTitlesNeverReachTheSizeColumnAndTheSubmenuIsNotWider() throws {
        let disk = DiskUsage(total: 500_000_000_000, free: 120_000_000_000)
        let findings = (0..<8).map { j in
            Finding(id: "a\(j)", ecosystem: .javascript, title: "node_modules · " + String(repeating: "long-title-", count: 1 + j),
                    location: "~/P", bytes: 85_000_000, tier: .safe, rebuild: .minutes,
                    action: .removeArtifact(URL(fileURLWithPath: "/tmp/a\(j)")))
        }
        let model = MenuModel.make(MenuInput(result: ScanResult(findings: findings, disk: disk), disk: disk, scanning: false,
                                             cleaning: false, running: RunningSnapshot(apps: []), staleDays: 90))
        let menu = NSMenu()
        MenuBuilder { _ in }.populate(menu, model: model, header: NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80)))
        let sub = try XCTUnwrap(menu.items[4].submenu)
        let font = NSFont.menuFont(ofSize: 0)
        func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let rows = sub.items.filter { $0.attributedTitle?.string.contains("\t") == true }
        XCTAssertEqual(rows.count, 8)
        for item in rows {
            let parts = item.attributedTitle!.string.components(separatedBy: "\t")
            let tab = (item.attributedTitle!.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle).tabStops[0].location
            XCTAssertLessThanOrEqual(w(parts[0]) + 12 + w(parts[1]), tab + 0.5, parts[0])
            XCTAssertLessThanOrEqual(item.attributedTitle!.size().width, 520.5)
        }
        // Measured before the change: 660 points. A tab of 520 and the margins of the rows make 552.
        XCTAssertLessThanOrEqual(sub.size.width, 552.5)
        print("MEASURE submenu width", sub.size.width)
    }
}
