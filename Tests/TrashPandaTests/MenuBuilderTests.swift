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
    func testTheSecondLineIsNeverLost() {
        let row = MenuModel.Row(title: "Item", enabled: false, tooltip: "Tip", subtitle: "Second line")
        let menu = NSMenu()
        MenuBuilder { _ in }.populate(menu, submenu: MenuModel.Submenu(rows: [row]))
        let item = menu.items[0]
        if #available(macOS 14.4, *) {
            XCTAssertEqual(item.subtitle, "Second line")
            XCTAssertEqual(item.toolTip, "Tip")
        } else {
            XCTAssertEqual(item.toolTip, "Second line\nTip")
        }
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
        // Measured before the change: 660 points. The tab is at most 520, and each row adds its margins and icon column.
        let probe = NSMenu()
        let probeItem = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        probeItem.attributedTitle = MenuBuilderTests.probeTitle(tab: 400)
        probe.addItem(probeItem)
        XCTAssertLessThanOrEqual(sub.size.width, 520 + (probe.size.width - 400) + 0.5)
        print("MEASURE submenu width", sub.size.width)
    }

    private func mainMenu(ecosystems: [Ecosystem], mb: Int64 = 679) -> NSMenu {
        let disk = DiskUsage(total: 500_000_000_000, free: 120_000_000_000)
        let findings = ecosystems.enumerated().map { i, eco in
            Finding(id: "m\(i)", ecosystem: eco, title: "t", location: "~/P", bytes: mb * 1_000_000, tier: .safe, rebuild: .minutes,
                    action: .removeArtifact(URL(fileURLWithPath: "/tmp/m\(i)")))
        }
        let model = MenuModel.make(MenuInput(result: ScanResult(findings: findings, disk: disk), disk: disk, scanning: false,
                                             cleaning: false, running: RunningSnapshot(apps: []), staleDays: 90))
        let menu = NSMenu()
        MenuBuilder { _ in }.populate(menu, model: model, header: NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80)))
        return menu
    }

    private func tabOf(_ item: NSMenuItem) -> CGFloat? {
        (item.attributedTitle?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.tabStops.first?.location
    }

    /// Every row with a size, in the menu and in the submenus that follow its tab.
    private func sizeRows(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            var found = item.attributedTitle?.string.contains("\t") == true ? [item] : []
            if let sub = item.submenu, !(sub.items.first?.title.hasPrefix("Free up") ?? false) { found += sizeRows(sub) }
            return found
        }
    }

    /// No row of the main menu has a key equivalent: AppKit adds a shared column for it to every row (16 points,
    /// measured: 371 against 355), and that pushes the chevrons away from the sizes.
    func testNoRowOfTheMainMenuHasAKeyEquivalentAndTheMenuIsAsWideAsItsGroupRows() {
        let menu = mainMenu(ecosystems: [.aiAgents, .browsers, .javascript, .swift, .docker])
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertEqual(item.keyEquivalent, "", "\(item.title) has a key equivalent: it widens the whole menu by about 16 points")
        }
        // A group row is as wide as its tab plus the icon and chevron columns. Measure that overhead on a probe menu.
        let probe = NSMenu()
        let item = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        item.attributedTitle = MenuBuilderTests.probeTitle(tab: 400)
        item.image = NSImage(size: NSSize(width: 16, height: 16))
        let sub = NSMenu(); sub.addItem(withTitle: "x", action: nil, keyEquivalent: ""); item.submenu = sub
        probe.addItem(item)
        let overhead = probe.size.width - 400
        let rows = sizeRows(menu).filter { $0.submenu != nil }
        XCTAssertEqual(rows.count, 5)
        let tab = tabOf(rows[0])!
        XCTAssertEqual(menu.size.width, tab + overhead, accuracy: 0.5, "Something other than the group rows decides the menu width")
        print("MEASURE main width", menu.size.width, "tab", tab, "overhead", overhead)
    }

    private static func probeTitle(tab: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: tab)]
        return NSAttributedString(string: "x\tx", attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style])
    }

    /// Every ecosystem name, with the biggest size the menu can show, keeps its title whole and clear of its size.
    func testEveryGroupTitleFitsBesideTheLargestSize() {
        let menu = mainMenu(ecosystems: Ecosystem.allCases, mb: 999_900)
        let font = NSFont.menuFont(ofSize: 0)
        func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let rows = sizeRows(menu)
        XCTAssertGreaterThanOrEqual(rows.count, Ecosystem.allCases.count)
        var seen = Set<String>()
        for item in rows {
            let parts = item.attributedTitle!.string.components(separatedBy: "\t")
            let tab = tabOf(item)!
            XCTAssertEqual(tab, tabOf(rows[0])!)
            XCTAssertLessThanOrEqual(w(parts[0]) + 12 + w(parts[1]), tab + 0.5, parts[0])
            XCTAssertFalse(parts[0].contains("…"), "\(parts[0]) was cut")
            seen.insert(parts[0])
        }
        XCTAssertTrue(seen.contains("JavaScript & TypeScript"))
        print("MEASURE all ecosystems at 999.9 GB: width", menu.size.width, "tab", tabOf(rows[0])!, "groups", seen.count)
    }

    /// The header grows with the menu. Each rebuild of the closed menu uses a FRESH header at the minimum width,
    /// so one wide moment cannot keep the menu wide for the session.
    func testARebuildAfterAWideMomentGivesTheNarrowMenuAgain() throws {
        let disk = DiskUsage(total: 500_000_000_000, free: 120_000_000_000)
        func model(_ bytes: Int64) -> MenuModel {
            let findings = [Finding(id: "h", ecosystem: .javascript, title: "t", location: "~/P", bytes: bytes, tier: .safe,
                                    rebuild: .minutes, action: .removeArtifact(URL(fileURLWithPath: "/tmp/h")))]
            return MenuModel.make(MenuInput(result: ScanResult(findings: findings, disk: disk), disk: disk, scanning: false,
                                            cleaning: false, running: RunningSnapshot(apps: []), staleDays: 90))
        }
        let builder = MenuBuilder { _ in }
        let menu = NSMenu()
        let first = try XCTUnwrap(builder.rebuild(menu, model: model(300_000_000), onSelect: { _ in }))
        let narrow = menu.size.width
        first.setFrameSize(NSSize(width: 371, height: first.frame.height))   // a wide moment
        XCTAssertEqual(first.frame.width, 371)
        let second = try XCTUnwrap(builder.rebuild(menu, model: model(310_000_000), onSelect: { _ in }), "a changed model builds again")
        XCTAssertFalse(second === first, "a fresh header for each build")
        XCTAssertEqual(second.frame.width, StorageHeaderView.minimumWidth)
        XCTAssertEqual(menu.size.width, narrow, "The menu stayed wide after the wide moment")
    }
}
