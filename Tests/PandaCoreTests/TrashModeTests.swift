import XCTest
@testable import PandaCore

/// The delete mode (#33): `delete_mode = trash` moves files to the Trash. No test touches the real Trash.
/// The tests give the cleaner a trasher that moves an item into a folder of the sandbox.
final class TrashModeTests: XCTestCase {
    private func finding(_ action: Action = .inform, bytes: Int64 = 1) -> Finding {
        Finding(id: "t", ecosystem: .browsers, title: "Test", location: "x", bytes: bytes, tier: .safe, rebuild: .download, action: action)
    }

    final class Calls {
        var trashed: [String] = []
        var deleted: [String] = []
    }

    struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

    /// A cleaner in trash mode. The trasher moves the item to `trash` (a folder in the sandbox). Deleting for good is recorded.
    private func trashCleaner(_ box: Sandbox, trash: URL, calls: Calls, mode: DeleteMode = .trash,
                              whileMeasuring: (() -> Void)? = nil) -> Cleaner {
        let cleaner = Cleaner(guardian: PathGuard(home: box.home), deleteMode: mode)
        cleaner.sizeOf = { _ in whileMeasuring?(); return 100 }
        cleaner.deleteItem = { url in calls.deleted.append(url.path); try FileManager.default.removeItem(at: url) }
        cleaner.trashItem = { url in
            calls.trashed.append(url.path)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
        return cleaner
    }

    private func trashFolder(_ box: Sandbox) -> URL { box.home.deletingLastPathComponent().appendingPathComponent("fake-trash") }

    private func isPlain(_ url: URL) -> Bool { UpdateDownloads.isPlainPath(url) }

    // MARK: The move

    func testTrashModeMovesARealFolderToTheTrashFolder() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let trash = trashFolder(box)
        let calls = Calls()
        var report = CleanReport()
        let done = trashCleaner(box, trash: trash, calls: calls)
            .removeEach([folder], of: finding(), into: &report, notTarget: "no", isTarget: isPlain)
        XCTAssertEqual(done, .init(removed: 1, failures: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
        XCTAssertEqual(calls.trashed, [folder.path])
        XCTAssertEqual(calls.deleted, [], "nothing is deleted for good")
        XCTAssertEqual(report.movedToTrash, 100)
        XCTAssertEqual(report.freed, 0, "moved bytes are not freed bytes")
    }

    func testTheDefaultModeIsPermanentAndDoesNotUseTheTrash() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let calls = Calls()
        var report = CleanReport()
        let cleaner = trashCleaner(box, trash: trashFolder(box), calls: calls, mode: .permanent)
        XCTAssertEqual(Cleaner(guardian: PathGuard(home: box.home)).deleteMode, .permanent, "permanent is the default")
        cleaner.removeEach([folder], of: finding(), into: &report, notTarget: "no", isTarget: isPlain)
        XCTAssertEqual(calls.trashed, [])
        XCTAssertEqual(calls.deleted, [folder.path])
        XCTAssertEqual(report.freed, 100)
        XCTAssertEqual(report.movedToTrash, 0)
        XCTAssertEqual(report.deleteMode, .permanent)
    }

    func testAFailedMoveIsAFailureAndNeverFallsBackToAPermanentDelete() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let calls = Calls()
        let cleaner = trashCleaner(box, trash: trashFolder(box), calls: calls)
        cleaner.trashItem = { url in calls.trashed.append(url.path); throw Boom() }
        var report = CleanReport()
        let done = cleaner.removeEach([folder], of: finding(), into: &report, notTarget: "no", isTarget: isPlain)
        XCTAssertEqual(done, .init(removed: 0, failures: 1))
        XCTAssertEqual(calls.deleted, [], "no fallback to a delete for good")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the folder stays")
        XCTAssertEqual(report.movedToTrash, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue((report.failed.first ?? "").contains("Could not move it to the Trash"), report.failed.first ?? "")
    }

    func testAFailureDoesNotStopTheNextTarget() throws {
        let box = try Sandbox()
        let a = try box.file("Library/Caches/Demo/A/x", bytes: 10).deletingLastPathComponent()
        let b = try box.file("Library/Caches/Demo/B/x", bytes: 10).deletingLastPathComponent()
        let calls = Calls()
        let trash = trashFolder(box)
        let cleaner = trashCleaner(box, trash: trash, calls: calls)
        let real = cleaner.trashItem
        cleaner.trashItem = { url in
            if url == a { throw Boom() }
            try real(url)
        }
        var report = CleanReport()
        let done = cleaner.removeEach([a, b], of: finding(), into: &report, notTarget: "no", isTarget: isPlain)
        XCTAssertEqual(done, .init(removed: 1, failures: 1))
        XCTAssertEqual(report.movedToTrash, 100)
    }

    // MARK: Safety order stays

    /// A target that became a link after the preview is not moved. The guard and the shape check run before the move.
    func testATargetThatBecameALinkAfterThePreviewIsNotTrashed() throws {
        let box = try Sandbox()
        let target = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let other = try box.file("Library/Caches/Demo/Other/b", bytes: 10).deletingLastPathComponent()
        let calls = Calls()
        let cleaner = trashCleaner(box, trash: trashFolder(box), calls: calls) {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        }
        var report = CleanReport()
        // The shape check of the caller says yes. The guard must stop it.
        cleaner.removeEach([target], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true })
        XCTAssertEqual(calls.trashed, [], "a link is not moved")
        XCTAssertEqual(calls.deleted, [])
        XCTAssertEqual(report.movedToTrash, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("b").path))
    }

    func testAFolderThatTheGuardProtectsIsNotTrashed() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Demo/a", bytes: 10)
        let caches = box.home.appendingPathComponent("Library/Caches")
        let calls = Calls()
        var report = CleanReport()
        trashCleaner(box, trash: trashFolder(box), calls: calls)
            .removeEach([caches], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true })
        XCTAssertEqual(calls.trashed, [])
        XCTAssertEqual(report.skipped.count, 1)
    }

    func testAnItemThatIsGoneIsSkippedAndNotTrashed() throws {
        let box = try Sandbox()
        let gone = box.home.appendingPathComponent("Library/Caches/Demo/Nothing")
        let calls = Calls()
        var report = CleanReport()
        trashCleaner(box, trash: trashFolder(box), calls: calls)
            .removeEach([gone], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true })
        XCTAssertEqual(calls.trashed, [])
        XCTAssertEqual(report.skipped.count, 1)
    }

    // MARK: Already in the Trash, and no Trash

    func testAnItemInTheTrashIsNotMovedAgain() throws {
        let box = try Sandbox()
        XCTAssertTrue(DeleteMode.isInTrash(box.home.appendingPathComponent(".Trash/Cache/a"), home: box.home.path))
        XCTAssertTrue(DeleteMode.isInTrash(URL(fileURLWithPath: "/Volumes/Disk/.Trashes/501/a"), home: box.home.path))
        XCTAssertFalse(DeleteMode.isInTrash(box.home.appendingPathComponent("Library/Caches/Trash/a"), home: box.home.path))
        XCTAssertFalse(DeleteMode.isInTrash(box.home.appendingPathComponent(".TrashOld/a"), home: box.home.path))
        let inTrash = try box.file(".Trash/Cache/a", bytes: 10).deletingLastPathComponent()
        let calls = Calls()
        var report = CleanReport()
        // The guard may refuse this path first. Either way the trasher is not called.
        trashCleaner(box, trash: trashFolder(box), calls: calls)
            .removeEach([inTrash], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true })
        XCTAssertEqual(calls.trashed, [])
        XCTAssertEqual(calls.deleted, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: inTrash.path))
        XCTAssertEqual(report.movedToTrash, 0)
        XCTAssertEqual(report.skipped.count + report.failed.count, 1)
    }

    func testAVolumeWithNoTrashFailsTheItemWithAClearReason() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let calls = Calls()
        let cleaner = trashCleaner(box, trash: trashFolder(box), calls: calls)
        cleaner.trashItem = { _ in throw CocoaError(.featureUnsupported) }
        var report = CleanReport()
        cleaner.removeEach([folder], of: finding(), into: &report, notTarget: "no", isTarget: isPlain)
        XCTAssertEqual(calls.deleted, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue((report.failed.first ?? "").contains("This disk has no Trash"), report.failed.first ?? "")
        XCTAssertEqual(TrashMover.classify(CocoaError(.featureUnsupported)), .noTrashOnVolume)
        XCTAssertEqual(TrashMover.classify(Boom()), .failed("boom"))
    }

    // MARK: Through clean()

    func testCleanMovesTheContentsOfAFolderAndCountsMovedBytes() throws {
        let box = try Sandbox()
        let dir = box.home.appendingPathComponent(".npm/_cacache")
        try box.file(".npm/_cacache/a", bytes: 2000)
        try box.file(".npm/_cacache/b", bytes: 3000)
        let calls = Calls()
        let cleaner = trashCleaner(box, trash: trashFolder(box), calls: calls)
        let report = cleaner.clean([finding(.removeContents(dir), bytes: 5000)])
        XCTAssertEqual(calls.trashed.count, 2)
        XCTAssertEqual(calls.deleted, [])
        XCTAssertEqual(report.deleteMode, .trash)
        XCTAssertEqual(report.movedToTrash, 5000)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: dir.path)).count, 0, "the folder stays, empty")
    }

    func testCleanInPermanentModeStillDeletesForGood() throws {
        let box = try Sandbox()
        let dir = box.home.appendingPathComponent(".npm/_cacache")
        try box.file(".npm/_cacache/a", bytes: 2000)
        let calls = Calls()
        let report = trashCleaner(box, trash: trashFolder(box), calls: calls, mode: .permanent).clean([finding(.removeContents(dir), bytes: 2000)])
        XCTAssertEqual(calls.trashed, [])
        XCTAssertEqual(calls.deleted.count, 1)
        XCTAssertEqual(report.freed, 2000)
        XCTAssertEqual(report.movedToTrash, 0)
    }

    func testAnItemThatRunsAToolIsNotAFileDelete() {
        XCTAssertFalse(DeleteMode.movesFiles(.docker(.removeVolume(name: "data"))))
        XCTAssertFalse(DeleteMode.movesFiles(.simulator(.deleteDevice(udid: "A"))))
        XCTAssertFalse(DeleteMode.movesFiles(.owner(.uvCacheClean)))
        XCTAssertFalse(DeleteMode.movesFiles(.brew(.uninstall(name: "x"))))
        XCTAssertFalse(DeleteMode.movesFiles(.emptyTrash))
        XCTAssertFalse(DeleteMode.movesFiles(.agent(.removeOllamaModel(name: "m"))))
        XCTAssertTrue(DeleteMode.movesFiles(.removeContents(URL(fileURLWithPath: "/x"))))
        XCTAssertTrue(DeleteMode.movesFiles(.removeArtifact(URL(fileURLWithPath: "/x"))))
        XCTAssertTrue(DeleteMode.movesFiles(.removeInstaller(URL(fileURLWithPath: "/x"))))
        XCTAssertTrue(DeleteMode.movesFiles(.agent(.removeAgentCaches(appID: "x"))))
    }

    // MARK: Settings

    func testSettingsDefaultToPermanent() {
        XCTAssertEqual(Config.parseSettings("").deleteMode, .permanent)
        XCTAssertEqual(Config().deleteMode, .permanent)
        XCTAssertEqual(Config.parseSettings("stale_days = 7").deleteMode, .permanent)
    }

    func testSettingsReadTrashAndPermanent() {
        XCTAssertEqual(Config.parseSettings("delete_mode = trash").deleteMode, .trash)
        XCTAssertEqual(Config.parseSettings("delete_mode=trash\n").deleteMode, .trash)
        XCTAssertEqual(Config.parseSettings("# c\n  delete_mode =  Trash  \n").deleteMode, .trash)
        XCTAssertEqual(Config.parseSettings("delete_mode = permanent").deleteMode, .permanent)
        let both = Config.parseSettings("stale_days = 7\ndelete_mode = trash")
        XCTAssertEqual(both.staleDays, 7)
        XCTAssertEqual(both.deleteMode, .trash)
        XCTAssertTrue(both.warnings.isEmpty)
    }

    func testAnInvalidValueGivesPermanentAndAWarning() {
        for bad in ["", "yes", "recycle", "trash please", "1"] {
            let parsed = Config.parseSettings("delete_mode = \(bad)")
            XCTAssertEqual(parsed.deleteMode, .permanent, "value \"\(bad)\"")
            XCTAssertEqual(parsed.warnings.count, 1, "value \"\(bad)\"")
        }
        // A later valid line wins over an earlier bad one.
        XCTAssertEqual(Config.parseSettings("delete_mode = x\ndelete_mode = trash").deleteMode, .trash)
    }

    func testTheModeIsWrittenAndReadBackAndOtherLinesStay() throws {
        let box = try Sandbox()
        XCTAssertEqual(Config.readDeleteMode(home: box.home), .permanent, "no file")
        XCTAssertTrue(Config.setDeleteMode(.trash, home: box.home))
        XCTAssertEqual(Config.readDeleteMode(home: box.home), .trash)
        let file = box.home.appendingPathComponent(".config/trashpanda/settings")
        try "# my note\nstale_days = 14\ndelete_mode = permanent\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(Config.setDeleteMode(.trash, home: box.home))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, "# my note\nstale_days = 14\ndelete_mode = trash\n")
        XCTAssertTrue(Config.setDeleteMode(.permanent, home: box.home))
        XCTAssertEqual(Config.readDeleteMode(home: box.home), .permanent)
        XCTAssertEqual(Config.parseSettings(try String(contentsOf: file, encoding: .utf8)).staleDays, 14)
    }

    // MARK: Words

    private func docker() -> Finding { finding(.docker(.removeVolume(name: "data"))) }
    private func files() -> Finding { finding(.removeContents(URL(fileURLWithPath: "/x"))) }

    func testTheDialogNamesTheModeAndSaysTheSpaceIsNotFreeInTrashMode() {
        XCTAssertEqual(DeleteModeText.note(mode: .permanent, findings: [files()]), "", "permanent dialogs keep their old text")
        let trash = DeleteModeText.note(mode: .trash, findings: [files()])
        XCTAssertTrue(trash.contains("move to the Trash"))
        XCTAssertTrue(trash.contains("You can put them back"))
        XCTAssertTrue(trash.contains("The space is not free yet"))
        XCTAssertTrue(trash.contains("empty the Trash"))
    }

    func testTheDialogSaysThatAToolItemDoesNotGoToTheTrash() {
        let tool = DeleteModeText.note(mode: .trash, findings: [docker()])
        XCTAssertTrue(tool.contains("not a file"))
        XCTAssertTrue(tool.contains("for good"))
        XCTAssertFalse(tool.contains("not free yet"), "nothing moves to the Trash")
        let mixed = DeleteModeText.note(mode: .trash, findings: [files(), docker()])
        XCTAssertTrue(mixed.contains("not free yet"))
        XCTAssertTrue(mixed.contains("Docker or Homebrew"))
    }

    func testTheTitleAndTheButtonDoNotPromiseFreeSpaceInTrashMode() {
        XCTAssertEqual(DeleteModeText.title("Free up 6.3 GB?", mode: .trash, findings: [files()]), "Move 6.3 GB to the Trash?")
        XCTAssertEqual(DeleteModeText.title("Free up 6.3 GB of Xcode & Swift files?", mode: .trash, findings: [files()]),
                       "Move 6.3 GB of Xcode & Swift files to the Trash?")
        XCTAssertEqual(DeleteModeText.title("Free up 6.3 GB?", mode: .permanent, findings: [files()]), "Free up 6.3 GB?")
        XCTAssertEqual(DeleteModeText.title("Free up 6.3 GB?", mode: .trash, findings: [files(), docker()]), "Clean 6.3 GB?",
                       "a mixed list never says free for bytes that only move")
        XCTAssertEqual(DeleteModeText.title("Free up 6.3 GB?", mode: .trash, findings: [docker()]), "Free up 6.3 GB?",
                       "a tool frees the space for real")
        XCTAssertEqual(DeleteModeText.confirmTitle(mode: .trash, bytes: 1_000_000, findings: [files(), docker()]),
                       "Clean \(ByteText.string(1_000_000))")
        XCTAssertEqual(DeleteModeText.bulkRow("3 GB", mode: .trash), "Clean 3 GB…")
        XCTAssertEqual(DeleteModeText.bulkRow("3 GB", mode: .permanent), "Free up 3 GB…")
        XCTAssertEqual(MenuText.primary(safeCount: 2, safeBytes: 3_000_000_000, reviewBytes: 0, deleteMode: .trash).title,
                       "Clean \(ByteText.string(3_000_000_000))…")
        XCTAssertEqual(MenuText.primary(safeCount: 2, safeBytes: 3_000_000_000, reviewBytes: 0).title,
                       "Free up \(ByteText.string(3_000_000_000))…")
        XCTAssertEqual(DeleteModeText.confirmTitle(mode: .permanent, bytes: 2_000_000_000, findings: [files()]),
                       "Free up \(ByteText.string(2_000_000_000))")
        XCTAssertEqual(DeleteModeText.confirmTitle(mode: .trash, bytes: 2_000_000_000, findings: [files()]),
                       "Move \(ByteText.string(2_000_000_000)) to the Trash")
    }

    func testTheFooterKeepsNoUndoClaimForFilesInTrashMode() {
        let footer = DeleteModeText.footer(Confirmation.defaultFooter, mode: .trash, findings: [files()])
        XCTAssertFalse(footer.contains("can't be undone"))
        XCTAssertEqual(DeleteModeText.footer(Confirmation.defaultFooter, mode: .permanent, findings: [files()]), Confirmation.defaultFooter)
        XCTAssertEqual(DeleteModeText.footer(Confirmation.defaultFooter, mode: .trash, findings: [docker()]), Confirmation.defaultFooter)
    }

    func testTheReportInTrashModeNeverSaysFreed() {
        var report = CleanReport()
        report.deleteMode = .trash
        report.movedToTrash = 5_000_000
        report.removed = 2
        let summary = CleanSummary.make(report, dockerDiskNote: false)
        XCTAssertEqual(summary.title, "Moved \(ByteText.string(5_000_000)) to the Trash")
        XCTAssertFalse(summary.title.contains("Freed"))
        XCTAssertTrue(summary.lines.contains(DeleteModeText.notFreeYet))
        XCTAssertFalse(summary.lines.joined().contains("free space on your Mac"), "no claim about the free space of the Mac")
        XCTAssertTrue(CleanSummary.needsDialog(report, dockerDiskNote: false), "the user must read that the space is not free yet")
        XCTAssertEqual(DeleteModeText.flash(report), "Moved \(ByteText.string(5_000_000)) to Trash")
    }

    func testTheReportInTrashModeSeparatesWhatAToolFreed() {
        var report = CleanReport()
        report.deleteMode = .trash
        report.movedToTrash = 5_000_000
        report.freed = 3_000_000
        let summary = CleanSummary.make(report, dockerDiskNote: false)
        XCTAssertTrue(summary.lines.joined(separator: "\n").contains("\(ByteText.string(3_000_000)) was removed for good by a tool"))
        XCTAssertFalse(summary.title.contains("Freed"))
    }

    func testTheReportInPermanentModeIsUnchanged() {
        var report = CleanReport()
        report.freed = 5_000_000
        report.removed = 2
        let summary = CleanSummary.make(report, dockerDiskNote: false)
        XCTAssertEqual(summary.title, "Freed \(ByteText.string(5_000_000))")
        XCTAssertEqual(summary.lines.first, "2 items removed.")
        XCTAssertFalse(CleanSummary.needsDialog(report, dockerDiskNote: false))
        XCTAssertEqual(DeleteModeText.flash(report), "Freed \(ByteText.string(5_000_000))")
        XCTAssertEqual(DeleteModeText.flash(CleanReport()), "Nothing to free")
    }

    func testTheSettingsMenuHasTheRowAndItsCheck() throws {
        func rows(_ mode: DeleteMode) throws -> [MenuModel.Row] {
            var input = MenuInput(result: nil, disk: DiskUsage(total: 1_000_000_000, free: 500_000_000), scanning: false, cleaning: false,
                                  running: RunningSnapshot(apps: []), staleDays: 30)
            input.deleteMode = mode
            return try XCTUnwrap(MenuModel.make(input).rows.first { $0.title == "Settings" }?.submenu?.rows)
        }
        XCTAssertEqual(try rows(.permanent).first { $0.action == .toggleTrashMode }?.checked, false)
        XCTAssertEqual(try rows(.trash).first { $0.action == .toggleTrashMode }?.checked, true)
        XCTAssertEqual(try rows(.trash).first { $0.action == .toggleTrashMode }?.title, MenuText.trashModeTitle)
    }

    // MARK: Every kind of dialog

    private func sample(_ action: Action, tier: Tier = .safe, title: String = "Thing") -> Finding {
        Finding(id: "k", ecosystem: .aiAgents, title: title, location: "~/x", bytes: 5_000_000, tier: tier, rebuild: .download, action: action)
    }

    /// No dialog text in trash mode says "for good", "does not go to the Trash", or "can't be undone" for a file item.
    func testNoTrashModeDialogOfAFileItemContradictsTheTrash() {
        let url = URL(fileURLWithPath: "/tmp/x")
        let items: [Finding] = [
            sample(.removeContents(url)), sample(.removeArtifact(url)), sample(.removeArtifact(url), tier: .review),
            sample(.removeArchive(url)), sample(.removeDeviceSupport(url)), sample(.removeServiceWorkerStorage(browserID: "b")),
            sample(.removeServiceWorkerSite(browserID: "b", profile: "p", folder: "f")),
            sample(.removeCacheFolderContents(name: "Thing")), sample(.removeCacheFolderContents(name: "CloudKit")),
            sample(.removeRuntime(storeID: "s", tool: "t", name: "n")), sample(.removeOldLogs(.crashReports)),
            sample(.removeInstaller(url)), sample(.agent(.removeCodexRuntime(url)), tier: .review),
            sample(.agent(.removeOldClaudeDesktopRuntimes(names: []))), sample(.agent(.removeClaudeVMBundle)),
            sample(.agent(.removeOldSessions(kind: .codex, olderThan: Date(), minimumAgeDays: 30))),
            sample(.agent(.removeLocalModel(storeID: "s", name: "n"))),
            sample(.removeBrowserCaches(browserID: "b")), sample(.removeUpdateDownloads(url)),
        ]
        var kinds = Set<Confirmation.Kind>()
        let banned = ["for good", "does not go to the Trash", "can't be undone", "cannot be undone", "Free up", "freed"]
        for f in items {
            let c = Confirmation.forOne(f, staleDays: 30)
            kinds.insert(Confirmation.kind(of: f))
            let all = [f]
            let title = DeleteModeText.title(c.title, mode: .trash, findings: all)
            let footer = DeleteModeText.footer(c.footer ?? Confirmation.defaultFooter, mode: .trash, findings: all)
            let note = DeleteModeText.note(mode: .trash, findings: all)
            let button = c.confirmTitle ?? DeleteModeText.confirmTitle(mode: .trash, bytes: f.bytes, findings: all)
            for text in [title, footer, note, button] {
                for word in banned { XCTAssertFalse(text.contains(word), "\(Confirmation.kind(of: f)): \"\(word)\" in \"\(text)\"") }
            }
            XCTAssertTrue(note.contains("not free yet"), "\(Confirmation.kind(of: f))")
        }
        // Every kind of dialog that holds a file delete is in the list.
        let toolKinds: Set<Confirmation.Kind> = [.container, .volume, .simulatorRuntime, .simulatorDevice, .trash, .brewPackage,
                                                 .globalPackage, .containerWithVolumes, .runningContainer]
        XCTAssertEqual(kinds.union(toolKinds), Set(Confirmation.Kind.allCases))
    }

    func testTheInstallerDialogHasItsOwnTrashModeFooter() {
        let f = sample(.removeInstaller(URL(fileURLWithPath: "/tmp/x.dmg")))
        let footer = DeleteModeText.footer(Confirmation.forOne(f, staleDays: 30).footer ?? "", mode: .trash, findings: [f])
        XCTAssertEqual(footer, "The file goes to the Trash. If you need it again, put it back from the Trash or download it again.")
        let permanent = DeleteModeText.footer(Confirmation.forOne(f, staleDays: 30).footer ?? "", mode: .permanent, findings: [f])
        XCTAssertTrue(permanent.contains("deleted for good"), "permanent mode keeps its text")
    }

    func testTheTrashItemAndToolDialogsGetNoFileNote() {
        let empty = sample(.emptyTrash)
        XCTAssertEqual(DeleteModeText.note(mode: .trash, findings: [empty]), "")
        XCTAssertEqual(DeleteModeText.footer("Finder deletes everything for good. This can't be undone.", mode: .trash, findings: [empty]),
                       "Finder deletes everything for good. This can't be undone.")
    }

    func testAHuggingFaceRepoFollowsTheHfTool() {
        let hf = sample(.agent(.removeHuggingFaceRepo(id: "model/a/b")))
        XCTAssertTrue(DeleteModeText.note(mode: .trash, findings: [hf], hfInstalled: true).contains("A tool removes it for good"))
        let without = DeleteModeText.note(mode: .trash, findings: [hf], hfInstalled: false)
        XCTAssertTrue(without.contains("moves the files to the Trash"))
        XCTAssertFalse(without.contains("for good"))
    }

    func testTheQuitButtonDoesNotSayFreeForAMovedFile() {
        let f = sample(.removeBrowserCaches(browserID: "b"))
        XCTAssertEqual(DeleteModeText.quitAndClean(apps: "Chrome", bytes: 1_000_000, finding: f, mode: .trash),
                       "Quit Chrome and move \(ByteText.string(1_000_000)) to the Trash")
        XCTAssertEqual(DeleteModeText.quitAndClean(apps: "Chrome", bytes: 1_000_000, finding: f, mode: .permanent),
                       "Quit Chrome and free \(ByteText.string(1_000_000))")
    }

    // MARK: More delete sites in trash mode

    private func cleaner(_ box: Sandbox, calls: Calls) -> Cleaner {
        trashCleaner(box, trash: trashFolder(box), calls: calls)
    }

    func testAnInstallerGoesToTheTrashAndALinkDoesNot() throws {
        let box = try Sandbox()
        let real = try box.file("Downloads/a.dmg", bytes: 3000, age: 60)
        let calls = Calls()
        let report = cleaner(box, calls: calls).clean([finding(.removeInstaller(real), bytes: 3000)])
        XCTAssertEqual(calls.trashed, [real.path])
        XCTAssertEqual(calls.deleted, [])
        XCTAssertEqual(report.movedToTrash, 3000)
        XCTAssertEqual(report.freed, 0)

        // A link that took its place after the preview is not moved.
        let target = try box.file("Documents/keep.dmg", bytes: 10, age: 60)
        let link = box.home.appendingPathComponent("Downloads/b.dmg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let calls2 = Calls()
        let report2 = cleaner(box, calls: calls2).clean([finding(.removeInstaller(link), bytes: 10)])
        XCTAssertEqual(calls2.trashed, [])
        XCTAssertEqual(report2.movedToTrash, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testACacheFolderGoesToTheTrashAndAFailedMoveStays() throws {
        let box = try Sandbox()
        let a = try box.file("Library/Caches/Foo/a", bytes: 2000)
        try box.file("Library/Caches/Foo/b", bytes: 2000)
        let calls = Calls()
        let report = cleaner(box, calls: calls).clean([finding(.removeCacheFolderContents(name: "Foo"), bytes: 4000)])
        XCTAssertEqual(calls.trashed.count, 2)
        XCTAssertEqual(calls.deleted, [])
        XCTAssertGreaterThan(report.movedToTrash, 0, "measured on disk, so not the estimate")
        XCTAssertEqual(report.freed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))

        // A move that fails leaves the files, and nothing is deleted for good.
        let c = try box.file("Library/Caches/Bar/c", bytes: 2000)
        let calls2 = Calls()
        let failing = cleaner(box, calls: calls2)
        failing.trashItem = { _ in throw Boom() }
        let report2 = failing.clean([finding(.removeCacheFolderContents(name: "Bar"), bytes: 2000)])
        XCTAssertEqual(calls2.deleted, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path))
        XCTAssertEqual(report2.movedToTrash, 0)
        XCTAssertFalse(report2.failed.isEmpty)
    }

    func testACacheChildThatIsALinkIsNotMoved() throws {
        let box = try Sandbox()
        let outside = try box.file("Documents/secret", bytes: 10)
        try box.file("Library/Caches/Foo/a", bytes: 2000)
        let link = box.home.appendingPathComponent("Library/Caches/Foo/l")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let calls = Calls()
        _ = cleaner(box, calls: calls).clean([finding(.removeCacheFolderContents(name: "Foo"), bytes: 2000)])
        XCTAssertFalse(calls.trashed.contains(link.path), "a link is not moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
