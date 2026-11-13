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

    private func model(_ findings: [Finding], mode: DeleteMode, running: RunningSnapshot = RunningSnapshot(apps: [])) -> MenuModel {
        var input = MenuInput(result: ScanResult(findings: findings, disk: disk, date: now), disk: disk, scanning: false, cleaning: false,
                              running: running, staleDays: 90, now: now)
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
    private let banned = ["Cannot be recovered", "You can free", "Free up", "Freed", "for good", "can't be undone",
                          "deleted", "Delete ", "can no longer resume"]
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

    /// Every prompt of the menu, in the rows and in their submenus.
    private func allPrompts(_ rows: [MenuModel.Row]) -> [MenuModel.Prompt] {
        rows.flatMap { row -> [MenuModel.Prompt] in
            (prompt(row.action).map { [$0] } ?? []) + (row.submenu.map { allPrompts($0.rows) } ?? [])
        }
    }

    /// The text and the clean of a prompt share one delete mode (#226). The mode is the one the menu was built with.
    func testEveryPromptKeepsTheDeleteModeOfItsWords() {
        let editor = AppOwner(name: "Example Editor", bundleIDs: ["com.example.editor"])
        let open = Finding(id: "open", ecosystem: .javascript, title: "Thing open", location: "/Users/example/open", bytes: 900_000_000,
                           tier: .safe, rebuild: .minutes, action: .removeArtifact(url), owner: editor)
        let running = RunningSnapshot(apps: [RunningApp(bundleID: "com.example.editor", name: "Example Editor")])
        let findings = fileItems + [toolItem(), open]

        let trash = allPrompts(model(findings, mode: .trash, running: running).rows)
        XCTAssertGreaterThan(trash.count, 3)
        XCTAssertTrue(trash.contains { $0.body.contains("is open. Trash Panda will ask it to quit first") }, "the open app prompt is checked too")
        for p in trash { XCTAssertEqual(p.deleteMode, .trash, "a trash-mode prompt: \(p.title)") }

        let permanent = allPrompts(model(findings, mode: .permanent, running: running).rows)
        XCTAssertGreaterThan(permanent.count, 3)
        for p in permanent { XCTAssertEqual(p.deleteMode, .permanent, "a permanent-mode prompt: \(p.title)") }
    }

    /// One-item dialogs of a file. In trash mode they say "Move ... to the Trash", never "deleted" or "Delete ".
    private var oneFileDialogs: [(name: String, finding: Finding)] {
        [("archive", item("ar", .swift, .removeArchive(url), .review, .never)),
         ("installer", item("in", .installers, .removeInstaller(url), .review, .never)),
         ("sessions", item("se", .aiAgents, .agent(.removeOldSessions(kind: .codex, olderThan: now, minimumAgeDays: 30)), .review, .never)),
         ("old logs", item("ol", .logs, .removeOldLogs(.crashReports), .review, .never)),
         ("cache folder", item("cf", .cacheExplorer, .removeCacheFolderContents(name: "example-cache"), .review, .never))]
    }

    /// The permanent words of the five dialogs above. They must not change, so each text is a copy of the old one.
    func testThePermanentOneFileDialogsKeepTheirOldWords() {
        let expected: [String: (title: String, footer: String, confirm: String)] = [
            "archive": ("Delete this archive?",
                        "An archive holds the symbol files (dSYMs) that you need to read crash reports of a build that you shipped. This can't be undone.",
                        "Delete archive"),
            "installer": ("Delete this installer?",
                          "The file is deleted for good. It does not go to the Trash. If you need it again, download it again. This can't be undone.",
                          "Delete installer"),
            "sessions": ("Delete old sessions?",
                         "You can no longer resume these conversations, and the tool may still list them. Only sessions older than the limit are deleted. This can't be undone.",
                         "Delete sessions"),
            "old logs": ("Delete these old log files?",
                         "Only files older than 30 days are deleted. Newer files stay, and so does the log of Trash Panda. Keep crash reports if you are looking for a crash. This can't be undone.",
                         "Delete files"),
            "cache folder": ("Empty this cache folder?",
                             "Apps can download the files in a cache folder again. Trash Panda does not know what this one holds: an app may sign you out, lose offline files, or be slow the first time. Quit the app first. The folder stays, and its contents are deleted. This can't be undone.",
                             "Empty folder"),
        ]
        for (name, f) in oneFileDialogs {
            let c = Confirmation.forOne(f, staleDays: 90, now: now, mode: .permanent)
            let old = expected[name]!
            XCTAssertEqual(c.title, old.title, name)
            XCTAssertEqual(c.footer, old.footer, name)
            XCTAssertEqual(c.confirmTitle, old.confirm, name)
            XCTAssertEqual(c, Confirmation.forOne(f, staleDays: 90, now: now), "the default mode is permanent: \(name)")
        }
    }

    func testTheTrashOneFileDialogsSayMoveNotDelete() {
        for (name, f) in oneFileDialogs {
            let c = Confirmation.forOne(f, staleDays: 90, now: now, mode: .trash)
            let texts = [c.title, c.body, c.footer ?? "", c.confirmTitle ?? ""]
            for text in texts { XCTAssertFalse(isFreeClaim(text), "\(name) in trash mode says: \(text)") }
            XCTAssertTrue(c.title.hasPrefix("Move ") && c.title.hasSuffix("to the Trash?") || name == "cache folder", "\(name): \(c.title)")
            XCTAssertTrue(c.footer?.contains("Trash") ?? false, "\(name) says where the file goes")
            XCTAssertTrue(c.cancelIsDefault, "\(name) keeps the default button")
        }
        XCTAssertEqual(Confirmation.forOne(oneFileDialogs[0].finding, staleDays: 90, now: now, mode: .trash).title, "Move this archive to the Trash?")
        XCTAssertEqual(Confirmation.forOne(oneFileDialogs[1].finding, staleDays: 90, now: now, mode: .trash).confirmTitle, "Move to the Trash")
    }

    /// A tool item keeps its permanent words in trash mode, so the file wording does not reach it.
    func testAToolDialogKeepsItsPermanentWordsInTrashMode() {
        let c = Confirmation.forOne(toolItem(), staleDays: 90, now: now, mode: .trash)
        XCTAssertEqual(c, Confirmation.forOne(toolItem(), staleDays: 90, now: now, mode: .permanent))
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
