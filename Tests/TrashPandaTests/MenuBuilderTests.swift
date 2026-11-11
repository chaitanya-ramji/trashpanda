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
        XCTAssertEqual(menu.items[4].submenu?.items.map(text), ["Free up 1.3 GB…", "---", "Safe to clean", "node_modules · app-a\t1.3 GB"])
        XCTAssertEqual(menu.items[7].submenu?.items.map(text), [
            "Check for updates…", "Check for updates every day", "Open at login", "---", "Open the keep list",
            "Open the project folders list", "---", "Show log in Finder", "Help", "Report a problem", "About Trash Panda",
        ])
        XCTAssertFalse(menu.items.contains { $0.isAlternate })
    }
}
