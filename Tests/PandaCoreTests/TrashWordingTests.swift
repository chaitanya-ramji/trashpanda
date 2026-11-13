import XCTest
@testable import PandaCore

/// The words of the menu follow the delete mode (#226). In trash mode, a file item goes to the Trash, so no text of it says
/// "Cannot be recovered", "You can free X now" or "Free up". An item that a tool removes keeps its permanent words.
/// The permanent texts below are a copy of what the menu said before this change.
final class TrashWordingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let disk = DiskUsage(total: 500_000_000_000, free: 120_000_000_000)
    private let url = URL(fileURLWithPath: "/Users/example/x")

    private func item(_ id: String, _ eco: Ecosystem, _ action: Action, _ tier: Tier, _ rebuild: Rebuild, bytes: Int64 = 900_000_000) -> Finding {
        Finding(id: id, ecosystem: eco, title: "Thing \(id)", location: "/Users/example/\(id)", bytes: bytes, tier: tier, rebuild: rebuild, action: action)
    }

    /// File items only: every one of them goes to the Trash in trash mode.
    private var fileItems: [Finding] {
        [item("a", .javascript, .removeArtifact(url), .safe, .minutes),
         item("b", .javascript, .removeArtifact(url), .safe, .download),
         item("c", .logs, .removeOldLogs(.crashReports), .review, .never),
         item("d", .aiAgents, .agent(.removeOldSessions(kind: .codex, olderThan: now, minimumAgeDays: 30)), .review, .never),
         item("e", .browsers, .removeBrowserCaches(browserID: "b"), .review, .never)]
    }

    private func toolItem() -> Finding {
        item("v", .docker, .docker(.removeVolume(name: "data")), .review, .never, bytes: 40_000_000)
    }

    private func model(_ findings: [Finding], mode: DeleteMode) -> MenuModel {
        var input = MenuInput(result: ScanResult(findings: findings, disk: disk, date: now), disk: disk, scanning: false, cleaning: false,
                              running: RunningSnapshot(apps: []), staleDays: 90, now: now)
        input.deleteMode = mode
        return MenuModel.make(input)
    }

    private func prompt(_ action: MenuModel.Action?) -> MenuModel.Prompt? {
        switch action {
        case .clean(let p)?, .quitAndClean(let p)?: return p
        default: return nil
        }
    }

    /// Every string that a row shows or that its dialog gets.
    private func strings(_ rows: [MenuModel.Row]) -> [String] {
        rows.flatMap { row -> [String] in
            // The Settings row describes both modes, so it names the permanent one on purpose.
            if row.action == .toggleTrashMode { return [] }
            var out = [row.title, row.subtitle, row.tooltip].compactMap { $0 }
            if let p = prompt(row.action) { out += [p.title, p.body] + [p.footer, p.confirmTitle].compactMap { $0 } }
            return out + (row.submenu.map { strings($0.rows) } ?? [])
        }
    }

    private func headerTexts(_ m: MenuModel) -> [String] {
        SplitTotals.Wording.allCases.map { m.header.totals.summary($0, mode: m.header.deleteMode) }
    }

    /// Words that claim the space is free, or that the file is gone for good.
    private let banned = ["Cannot be recovered", "You can free", "Free up", "Freed", "for good", "can't be undone"]
    private func isFreeClaim(_ text: String) -> Bool {
        banned.contains { text.contains($0) } || text.range(of: #"(?i)\bfree \d"#, options: .regularExpression) != nil
    }

    func testNoTextOfAFileItemMakesAPermanentClaimInTrashMode() {
        let m = model(fileItems, mode: .trash)
        let all = strings(m.rows) + headerTexts(m)
        XCTAssertGreaterThan(all.count, 30)
        for text in all { XCTAssertFalse(isFreeClaim(text), "trash mode says: \(text)") }
        XCTAssertTrue(all.contains { $0.contains("Goes to the Trash") }, "a file item without a way back says where it goes")
        XCTAssertTrue(all.contains { $0.hasPrefix("Clean ") && $0.hasSuffix("…") }, "the bulk row says Clean")
        XCTAssertTrue(all.contains { $0.contains("to the Trash?") }, "a prompt title says Move ... to the Trash")
    }

    /// The same findings in both modes: permanent mode keeps the old words, trash mode does not.
    func testPermanentModeKeepsTheOldWordsAndTrashModeDoesNot() {
        let perm = model(fileItems, mode: .permanent)
        let trash = model(fileItems, mode: .trash)
        let permAll = strings(perm.rows) + headerTexts(perm)
        XCTAssertTrue(permAll.contains("Cannot be recovered"))
        XCTAssertTrue(permAll.contains { $0.hasPrefix("Free up ") })
        XCTAssertTrue(headerTexts(perm).allSatisfy { $0.lowercased().contains("free") })
        XCTAssertNotEqual(permAll, strings(trash.rows) + headerTexts(trash))
        XCTAssertEqual(perm.header.deleteMode, .permanent)
        XCTAssertEqual(trash.header.deleteMode, .trash)
    }

    func testToolItemsKeepTheirPermanentWordsInTrashMode() {
        let all = strings(model([toolItem()], mode: .trash).rows)
        XCTAssertTrue(all.contains { $0.contains("Cannot be recovered") }, "a Docker volume is removed by Docker, for good")
        XCTAssertFalse(all.contains { $0.contains("Goes to the Trash") })
        // A mixed list: the tool item keeps its label, the file items get the Trash label.
        let mixed = strings(model(fileItems + [toolItem()], mode: .trash).rows)
        XCTAssertTrue(mixed.contains { $0.contains("Cannot be recovered") })
        XCTAssertTrue(mixed.contains { $0.contains("Goes to the Trash") })
    }

    func testTheRowLabelsOfAFileItemFollowTheMode() {
        XCTAssertEqual(DeleteModeText.rebuildLabel(fileItems[2], mode: .permanent), "Cannot be recovered")
        XCTAssertEqual(DeleteModeText.rebuildLabel(fileItems[2], mode: .trash), "Goes to the Trash, so you can put it back")
        XCTAssertEqual(DeleteModeText.rebuildLabel(fileItems[0], mode: .trash), "Rebuilds in a few minutes", "a rebuild label stays true")
        XCTAssertEqual(DeleteModeText.rebuildLabel(toolItem(), mode: .trash), "Cannot be recovered")
        XCTAssertEqual(MenuText.rebuildNotes([.never, .minutes], movesFiles: [true, true], mode: .trash).rowLabels,
                       ["Goes to the Trash, so you can put it back", "Rebuilds in a few minutes"])
        // Without the list that tells which items move, or in permanent mode, nothing changes.
        XCTAssertEqual(MenuText.rebuildNotes([.never, .minutes]).rowLabels, ["Cannot be recovered", "Rebuilds in a few minutes"])
        XCTAssertEqual(MenuText.rebuildNotes([.never], movesFiles: [true], mode: .permanent).rowLabels, ["Cannot be recovered"])
    }

    func testTheHeaderLineFollowsTheMode() {
        let totals = SplitTotals(free: 1_500_000_000, review: 1_400_000_000, waiting: 491_000_000)
        // Permanent mode: a copy of the old texts.
        XCTAssertEqual(totals.summary(.long), "You can free 1.5 GB now · 1.4 GB to look through · 491 MB when apps quit")
        XCTAssertEqual(totals.summary(.compact), "Free 1.5 GB now · 1.4 GB to review · 491 MB in open apps")
        XCTAssertEqual(totals.summary(.short), "Free 1.5 GB · 1.4 GB review · 491 MB in apps")
        for wording in SplitTotals.Wording.allCases {
            XCTAssertEqual(totals.summary(wording, mode: .permanent), totals.summary(wording))
        }
        XCTAssertEqual(totals.summary(.long, mode: .trash), "You can clean 1.5 GB now · 1.4 GB to look through · 491 MB when apps quit")
        XCTAssertEqual(totals.summary(.compact, mode: .trash), "Clean 1.5 GB now · 1.4 GB to review · 491 MB in open apps")
        XCTAssertEqual(totals.summary(.short, mode: .trash), "Clean 1.5 GB · 1.4 GB review · 491 MB in apps")
        XCTAssertEqual(SplitTotals(free: 0, review: 0, waiting: 0).summary(.long, mode: .trash), "All tidy.")
    }

    func testTheDialogTextOfOneItemFollowsTheMode() {
        let f = item("o", .python, .removeContents(url), .review, .never)
        let old = Confirmation.forOne(f, staleDays: 90, now: now)
        XCTAssertEqual(old.title, "Free up 900 MB?")
        XCTAssertEqual(old.body, "Thing o\nCannot be recovered.")
        XCTAssertEqual(old, Confirmation.forOne(f, staleDays: 90, now: now, mode: .permanent))
        let trash = Confirmation.forOne(f, staleDays: 90, now: now, mode: .trash)
        XCTAssertEqual(trash.title, "Move 900 MB to the Trash?")
        XCTAssertEqual(trash.body, "Thing o\nGoes to the Trash, so you can put it back.")
    }

    func testThePermanentMenuHasTheOldBulkAndPromptTexts() {
        let all = strings(model(fileItems, mode: .permanent).rows)
        XCTAssertTrue(all.contains { $0.hasPrefix("Free up ") && $0.hasSuffix("…") })
        XCTAssertTrue(all.contains { $0.hasPrefix("Free up ") && $0.hasSuffix("?") })
        XCTAssertFalse(all.contains { $0.contains("Goes to the Trash") })
    }

    /// The claim check itself: a permanent-mode text in a trash-mode list must be caught.
    func testTheClaimCheckCatchesAPermanentTextInTrashMode() {
        XCTAssertTrue(isFreeClaim("Cannot be recovered"))
        XCTAssertTrue(isFreeClaim("You can free 1.5 GB now"))
        XCTAssertTrue(isFreeClaim("Free 1.5 GB now"))
        XCTAssertTrue(isFreeClaim("Free up 3 GB…"))
        XCTAssertFalse(isFreeClaim("Clean 1.5 GB now"))
    }
}
