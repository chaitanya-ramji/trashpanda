import XCTest
@testable import PandaCore

/// Git worktrees (#118). Every test that touches git uses a REAL temporary repository in a made-up home folder.
/// Names are made up. A fake `git` that logs its calls (and can fail the removal) proves which git commands ran.
final class WorktreeTests: XCTestCase {
    let realGit = "/usr/bin/git"
    var box: Sandbox!
    var spyPath = ""
    var spyLog = ""

    override func setUpWithError() throws {
        box = try Sandbox()
        // A spy in front of the real git. It logs each call. A file `fail-remove` next to the log makes `worktree remove` exit 1.
        let dir = box.home.deletingLastPathComponent()
        spyLog = dir.appendingPathComponent("git-calls.log").path
        spyPath = dir.appendingPathComponent("git-spy").path
        let script = """
        #!/bin/sh
        echo "$*" >> '\(spyLog)'
        case " $* " in
          *" worktree remove "*) if [ -e '\(dir.path)/fail-remove' ]; then echo "fatal: simulated failure" >&2; exit 1; fi ;;
        esac
        exec \(realGit) "$@"
        """
        try script.write(toFile: spyPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spyPath)
    }

    // MARK: Helpers

    @discardableResult
    func git(_ args: [String], in dir: URL, file: StaticString = #filePath, line: UInt = #line) -> ShellResult {
        let r = Shell.run(realGit, ["-c", "user.name=tester", "-c", "user.email=tester@example.com", "-c", "commit.gpgsign=false",
                                    "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always", "-C", dir.path] + args,
                          timeout: 60, unsetEnv: Git.unsetVariables, quiet: true)
        XCTAssertEqual(r.status, 0, "git \(args.joined(separator: " ")): \(r.stderr)", file: file, line: line)
        return r
    }

    func write(_ rel: String, in dir: URL, bytes: Int = 20, text: String? = nil) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) } else { try Data(repeating: 7, count: bytes).write(to: url) }
    }

    /// A repository with one commit on `main`. `node_modules` is ignored, so a big folder in a worktree does not make it dirty.
    func makeRepo(_ rel: String) throws -> URL {
        let dir = box.home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        git(["init", "-q"], in: dir)
        try write(".gitignore", in: dir, text: "node_modules/\n")
        try write("readme.txt", in: dir, text: "hello\n")
        git(["add", "-A"], in: dir)
        git(["commit", "-q", "-m", "first"], in: dir)
        return dir
    }

    /// A linked worktree on a new branch, with 1.5 MB in an ignored folder, so that it has a size.
    @discardableResult
    func addWorktree(_ repo: URL, at path: URL, branch: String) throws -> URL {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        git(["worktree", "add", "-q", "-b", branch, path.path], in: repo)
        try write("node_modules/blob.bin", in: path, bytes: 1_500_000)
        return path
    }

    func home(_ rel: String) -> URL { box.home.appendingPathComponent(rel) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func calls(_ word: String) -> Int {
        ((try? String(contentsOfFile: spyLog, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains(word) }.count
    }
    func branches(_ repo: URL) -> [String] {
        git(["branch", "--format=%(refname:short)"], in: repo).stdout.split(separator: "\n").map(String.init).sorted()
    }

    func scanner(active: [String] = [], useSpy: Bool = false) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false, gitPath: useSpy ? spyPath : realGit, activeDirectories: { active })
    }
    func scan(active: [String] = []) -> [Finding] { scanner(active: active).scan().findings.filter { $0.ecosystem == .worktrees } }

    func cleaner(spy: Bool = true, active: @escaping () -> [String] = { [] }, mode: DeleteMode = .permanent) -> Cleaner {
        let c = Cleaner(guardian: PathGuard(home: box.home), runningApps: FakeRunning(apps: []).provider, programPaths: { [] },
                        openClaudeBinaries: { _ in [] }, deleteMode: mode, git: { Git(path: spy ? self.spyPath : self.realGit) })
        c.activeDirectories = active
        return c
    }

    func forged(_ repo: URL, _ path: URL) -> Finding {
        Finding(id: "worktree:\(path.path)", ecosystem: .worktrees, title: "forged", location: "forged", bytes: 5_000_000, tier: .review,
                rebuild: .recreate, action: .worktree(.remove(repo: repo, path: path)))
    }

    func finding(for path: URL, in list: [Finding]) -> Finding? { list.first { $0.id == "worktree:\(path.path)" } }

    // MARK: Find

    func testACleanMergedWorktreeIsFoundAndRemovable() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: repo.appendingPathComponent(".claude/worktrees/feature-one"), branch: "feature-one")
        let list = scan()
        XCTAssertEqual(list.count, 1)
        let f = try XCTUnwrap(finding(for: wt, in: list))
        XCTAssertNil(f.blockedReason)
        XCTAssertEqual(f.tier, .review)
        XCTAssertGreaterThan(f.bytes, 1_000_000)
        XCTAssertTrue(f.location.contains("branch feature-one"), f.location)
        XCTAssertTrue(f.location.contains("made by Claude Code"), f.location)
        XCTAssertTrue(f.location.contains("last commit"), f.location)
        XCTAssertTrue((f.note ?? "").contains("merged into main"), f.note ?? "")
        XCTAssertEqual(f.countedBytes, f.bytes)
        guard case .worktree(.remove(let r, let p)) = f.action else { return XCTFail("wrong action") }
        XCTAssertEqual(r.standardizedFileURL.path, repo.path)
        XCTAssertEqual(p.standardizedFileURL.path, wt.path)
    }

    func testTheMainCheckoutIsNeverListed() throws {
        let repo = try makeRepo("Developer/alpha")
        try addWorktree(repo, at: home("Developer/alpha-two"), branch: "two")
        try write("node_modules/big.bin", in: repo, bytes: 1_500_000)
        for f in scan() {
            guard case .worktree(.remove(_, let path)) = f.action else { continue }
            XCTAssertNotEqual(path.standardizedFileURL.path, repo.path)
        }
    }

    func testTheCreatorComesFromTheFolder() throws {
        let repo = try makeRepo("Developer/alpha")
        let codex = try addWorktree(repo, at: home(".codex/worktrees/a1b2/alpha"), branch: "codex-task")
        let mine = try addWorktree(repo, at: home("Developer/alpha-mine"), branch: "mine")
        let list = scan()
        XCTAssertTrue(try XCTUnwrap(finding(for: codex, in: list)).location.contains("made by Codex"))
        XCTAssertTrue(try XCTUnwrap(finding(for: mine, in: list)).location.contains("made by you"))
    }

    func testACodexWorktreeOfARepoOutsideTheScannedFoldersIsFoundThroughItsFolder() throws {
        let repo = try makeRepo("Elsewhere/outside-repo")      // not in a scanned folder
        let codex = try addWorktree(repo, at: home(".codex/worktrees/c3d4/outside-repo"), branch: "task")
        let list = scan()
        XCTAssertNotNil(finding(for: codex, in: list))
    }

    func testAWorktreeOutsideTheRepositoryFolderIsFoundAndRemovable() throws {
        let repo = try makeRepo("Developer/alpha")
        let sibling = try addWorktree(repo, at: home("Developer/alpha-sibling"), branch: "sibling")
        let f = try XCTUnwrap(finding(for: sibling, in: scan()))
        XCTAssertNil(f.blockedReason)
        let report = cleaner().clean([f])
        XCTAssertEqual(report.removed, 1, "\(report.skipped) \(report.failed)")
        XCTAssertFalse(exists(sibling))
        XCTAssertTrue(exists(repo.appendingPathComponent("readme.txt")))
    }

    func testAWorktreeOutsideTheHomeFolderIsShownButNotRemoved() throws {
        let repo = try makeRepo("Developer/alpha")
        let outside = box.home.deletingLastPathComponent().appendingPathComponent("outside-wt")
        try addWorktree(repo, at: outside, branch: "far")
        let f = try XCTUnwrap(finding(for: outside, in: scan()))
        XCTAssertNotNil(f.blockedReason)
        let report = cleaner().clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(outside))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    // MARK: State

    func testUncommittedChangesBlockTheItem() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-dirty"), branch: "dirty")
        try write("notes.txt", in: wt, text: "work in progress\n")           // an untracked file
        let f = try XCTUnwrap(finding(for: wt, in: scan()))
        XCTAssertTrue((f.blockedReason ?? "").contains("changes that are not committed"), f.blockedReason ?? "")
        XCTAssertEqual(f.countedBytes, 0)
        let report = cleaner().clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertTrue(exists(wt.appendingPathComponent("notes.txt")))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    func testAChangedTrackedFileBlocksToo() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-edit"), branch: "edit")
        try write("readme.txt", in: wt, text: "changed\n")
        XCTAssertNotNil(try XCTUnwrap(finding(for: wt, in: scan())).blockedReason)
    }

    func testCommitsThatExistNowhereElseBlockTheItem() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-ahead"), branch: "ahead")
        try write("new.txt", in: wt, text: "new\n")
        git(["add", "new.txt"], in: wt)
        git(["commit", "-q", "-m", "only here"], in: wt)
        let f = try XCTUnwrap(finding(for: wt, in: scan()))
        XCTAssertTrue((f.blockedReason ?? "").contains("1 commit that exists nowhere else"), f.blockedReason ?? "")
        let report = cleaner().clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(wt))
        XCTAssertEqual(calls("worktree remove"), 0)
        XCTAssertTrue(branches(repo).contains("ahead"))
    }

    func testADetachedHeadWithACommitThatExistsNowhereElseBlocks() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = home("Developer/alpha-detached")
        git(["worktree", "add", "-q", "--detach", wt.path], in: repo)
        try write("node_modules/blob.bin", in: wt, bytes: 1_500_000)
        try write("x.txt", in: wt, text: "x\n")
        git(["add", "x.txt"], in: wt)
        git(["commit", "-q", "-m", "loose"], in: wt)
        XCTAssertNotNil(try XCTUnwrap(finding(for: wt, in: scan())).blockedReason)
    }

    func testCommitsThatWerePushedOrMergedAreNotUnique() throws {
        let repo = try makeRepo("Developer/alpha")
        let remote = box.home.deletingLastPathComponent().appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        git(["init", "-q", "--bare"], in: remote)
        git(["remote", "add", "origin", remote.path], in: repo)
        let pushed = try addWorktree(repo, at: home("Developer/alpha-pushed"), branch: "pushed")
        try write("p.txt", in: pushed, text: "p\n")
        git(["add", "p.txt"], in: pushed); git(["commit", "-q", "-m", "p"], in: pushed)
        XCTAssertNotNil(try XCTUnwrap(finding(for: pushed, in: scan())).blockedReason, "not pushed yet")
        git(["push", "-q", "origin", "pushed"], in: pushed)
        let afterPush = try XCTUnwrap(finding(for: pushed, in: scan()))
        XCTAssertNil(afterPush.blockedReason)
        XCTAssertTrue((afterPush.note ?? "").contains("pushed"), afterPush.note ?? "")

        let merged = try addWorktree(repo, at: home("Developer/alpha-merged"), branch: "merged")
        try write("m.txt", in: merged, text: "m\n")
        git(["add", "m.txt"], in: merged); git(["commit", "-q", "-m", "m"], in: merged)
        XCTAssertNotNil(try XCTUnwrap(finding(for: merged, in: scan())).blockedReason)
        git(["merge", "-q", "merged"], in: repo)
        XCTAssertNil(try XCTUnwrap(finding(for: merged, in: scan())).blockedReason)
    }

    func testALockedWorktreeIsShownWithTheReasonAndNotRemoved() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-locked"), branch: "locked")
        git(["worktree", "lock", "--reason", "on a usb disk", wt.path], in: repo)
        let f = try XCTUnwrap(finding(for: wt, in: scan()))
        XCTAssertTrue((f.blockedReason ?? "").contains("It is locked (on a usb disk)"), f.blockedReason ?? "")
        let report = cleaner().clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(wt))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    func testARunningProgramInTheFolderBlocksTheItem() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-busy"), branch: "busy")
        let f = try XCTUnwrap(finding(for: wt, in: scan(active: [wt.path + "/src"])))
        XCTAssertTrue((f.blockedReason ?? "").contains("A running program uses this folder"), f.blockedReason ?? "")
        let report = cleaner(active: { [wt.path] }).clean([forged(repo, wt)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(wt))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    func testAProgramThatStartsWhileTheFolderIsMeasuredBlocksTheItem() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-late"), branch: "late")
        var started = false
        let c = cleaner(active: { started ? [wt.path] : [] })
        c.sizeOf = { url in started = true; return Sizer.size(of: url) }
        let report = c.clean([forged(repo, wt)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertTrue(exists(wt))
        XCTAssertEqual(calls("worktree remove"), 0, "the second check, right before the delete, must stop it")
    }

    // MARK: Remove

    func testARemovalRunsGitWorktreeRemoveForThatPathOnlyAndKeepsEverythingElse() throws {
        let repo = try makeRepo("Developer/alpha")
        let one = try addWorktree(repo, at: repo.appendingPathComponent(".claude/worktrees/one"), branch: "one")
        let two = try addWorktree(repo, at: repo.appendingPathComponent(".claude/worktrees/two"), branch: "two")
        let f = try XCTUnwrap(finding(for: one, in: scan()))
        let report = cleaner().clean([f])
        XCTAssertEqual(report.removed, 1, "\(report.skipped) \(report.failed)")
        XCTAssertGreaterThan(report.freed, 1_000_000)
        XCTAssertEqual(report.movedToTrash, 0)
        XCTAssertFalse(exists(one))
        XCTAssertTrue(exists(two.appendingPathComponent("node_modules/blob.bin")), "the other worktree is not touched")
        XCTAssertTrue(exists(repo.appendingPathComponent("readme.txt")), "the main checkout is not touched")
        XCTAssertEqual(calls("worktree remove"), 1)
        let logged = try String(contentsOfFile: spyLog, encoding: .utf8).split(separator: "\n").first { $0.contains("worktree remove") }.map(String.init) ?? ""
        XCTAssertTrue(logged.hasSuffix("worktree remove \(one.path)"), logged)
        XCTAssertEqual(branches(repo), ["main", "one", "two"], "no branch is deleted")
    }

    func testAFailedGitCommandIsAFailureAndNeverFallsBackToDeletingFiles() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-fail"), branch: "fail")
        FileManager.default.createFile(atPath: box.home.deletingLastPathComponent().appendingPathComponent("fail-remove").path, contents: Data())
        let c = cleaner()
        var fileDeletes = 0
        c.deleteItem = { _ in fileDeletes += 1 }
        c.trashItem = { _ in fileDeletes += 1 }
        let report = c.clean([try XCTUnwrap(finding(for: wt, in: scan()))])
        XCTAssertEqual(report.failed.count, 1, "\(report.failed)")
        XCTAssertTrue(report.failed[0].contains("simulated failure"), report.failed[0])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(fileDeletes, 0)
        XCTAssertTrue(exists(wt.appendingPathComponent("node_modules/blob.bin")))
    }

    func testThereIsNoForcedRemoval() throws {
        // Git refuses to remove a worktree that changed after the check. We never pass a force option, so it stays.
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-race"), branch: "race")
        let c = cleaner()
        c.sizeOf = { url in
            // A change that appears while the folder is measured, after our first check. Our second check sees it too.
            try? "late\n".write(to: wt.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
            return Sizer.size(of: url)
        }
        let report = c.clean([forged(repo, wt)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(wt.appendingPathComponent("late.txt")))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    func testGitItselfRefusesWhenTheFolderChangesAfterTheLastCheck() throws {
        // The window between our last check and git: a file appears. Git (not forced) refuses, and we report a failure.
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-window"), branch: "window")
        let slowSpy = box.home.deletingLastPathComponent().appendingPathComponent("git-late").path
        let script = """
        #!/bin/sh
        case " $* " in *" worktree remove "*) echo late > '\(wt.path)/late.txt' ;; esac
        exec \(realGit) "$@"
        """
        try script.write(toFile: slowSpy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowSpy)
        let c = Cleaner(guardian: PathGuard(home: box.home), runningApps: FakeRunning(apps: []).provider, programPaths: { [] },
                        openClaudeBinaries: { _ in [] }, git: { Git(path: slowSpy) })
        c.activeDirectories = { [] }
        let report = c.clean([forged(repo, wt)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.failed.count, 1, "\(report.failed)")
        XCTAssertTrue(exists(wt.appendingPathComponent("late.txt")), "git did not force")
    }

    func testTrashModeStillUsesGitAndNeverTheTrash() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-trash"), branch: "trash")
        let c = cleaner(mode: .trash)
        var trashed = 0
        c.trashItem = { _ in trashed += 1 }
        let report = c.clean([try XCTUnwrap(finding(for: wt, in: scan()))])
        XCTAssertEqual(report.removed, 1, "\(report.skipped) \(report.failed)")
        XCTAssertEqual(trashed, 0)
        XCTAssertEqual(report.movedToTrash, 0)
        XCTAssertGreaterThan(report.freed, 0, "a tool removed it for good, so the space is free")
        XCTAssertFalse(exists(wt))
    }

    // MARK: Forged findings

    func testAForgedFindingForADirtyWorktreeIsRefused() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-forged"), branch: "forged")
        try write("mine.txt", in: wt, text: "mine\n")
        let report = cleaner().clean([forged(repo, wt)])      // blockedReason is nil: the finding lies
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(exists(wt.appendingPathComponent("mine.txt")))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    func testAForgedFindingForTheMainCheckoutIsRefused() throws {
        let repo = try makeRepo("Developer/alpha")
        try addWorktree(repo, at: home("Developer/alpha-x"), branch: "x")
        let report = cleaner().clean([forged(repo, repo)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.skipped.first?.contains("main checkout") ?? false, "\(report.skipped)")
        XCTAssertTrue(exists(repo.appendingPathComponent("readme.txt")))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    func testAForgedFindingForAFolderThatIsNotAWorktreeIsRefused() throws {
        let repo = try makeRepo("Developer/alpha")
        try addWorktree(repo, at: home("Developer/alpha-x"), branch: "x")
        let plain = home("Developer/plain-folder")
        try write("keep.txt", in: plain, text: "keep\n")
        let report = cleaner().clean([forged(repo, plain)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(plain.appendingPathComponent("keep.txt")))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    func testAForgedFindingThatNamesAWorktreeOfAnotherRepositoryIsRefused() throws {
        let repoA = try makeRepo("Developer/alpha")
        let repoB = try makeRepo("Developer/beta")
        let wtB = try addWorktree(repoB, at: home("Developer/beta-feature"), branch: "feature")
        let report = cleaner().clean([forged(repoA, wtB)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(wtB.appendingPathComponent("node_modules/blob.bin")))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    func testAForgedFindingInAProtectedFolderIsRefused() throws {
        let repo = try makeRepo("Documents/alpha")
        let wt = try addWorktree(repo, at: home("Documents/alpha-wt"), branch: "docs")
        let report = cleaner().clean([forged(repo, wt)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(wt))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    func testAWorktreeOfAKeptProjectIsRefused() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: repo.appendingPathComponent(".claude/worktrees/kept"), branch: "kept")
        let c = Cleaner(guardian: PathGuard(home: box.home, keep: [repo.path]), runningApps: FakeRunning(apps: []).provider,
                        programPaths: { [] }, openClaudeBinaries: { _ in [] }, git: { Git(path: self.spyPath) })
        c.activeDirectories = { [] }
        XCTAssertEqual(c.clean([forged(repo, wt)]).removed, 0)
        XCTAssertTrue(exists(wt))
    }

    // MARK: Links

    func testALinkInPlaceOfTheWorktreeIsRefused() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-real"), branch: "real")
        let link = home("Developer/alpha-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wt)
        let report = cleaner().clean([forged(repo, link)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(wt.appendingPathComponent("node_modules/blob.bin")))
        XCTAssertEqual(calls("worktree remove"), 0)
        XCTAssertTrue(scan().allSatisfy { f in
            if case .worktree(.remove(_, let p)) = f.action { return p.standardizedFileURL.path != link.path }
            return true
        }, "a link is never listed")
    }

    func testAWorktreeThatBecameALinkAfterThePreviewIsRefused() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-swap"), branch: "swap")
        let moved = home("Developer/alpha-swap-moved")
        let f = try XCTUnwrap(finding(for: wt, in: scan()))
        let c = cleaner()
        var swapped = false
        c.sizeOf = { url in
            if !swapped {
                swapped = true
                try? FileManager.default.moveItem(at: wt, to: moved)
                try? FileManager.default.createSymbolicLink(at: wt, withDestinationURL: moved)
            }
            return Sizer.size(of: url)
        }
        let report = c.clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.skipped.count, 1, "\(report.skipped)")
        XCTAssertTrue(exists(moved.appendingPathComponent("node_modules/blob.bin")))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    func testAFolderAboveTheWorktreeThatBecameALinkIsRefused() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/group/alpha-deep"), branch: "deep")
        let f = try XCTUnwrap(finding(for: wt, in: scan()))
        let c = cleaner()
        let moved = home("Developer/group-moved")
        var swapped = false
        c.sizeOf = { url in
            if !swapped {
                swapped = true
                try? FileManager.default.moveItem(at: self.home("Developer/group"), to: moved)
                try? FileManager.default.createSymbolicLink(at: self.home("Developer/group"), withDestinationURL: moved)
            }
            return Sizer.size(of: url)
        }
        XCTAssertEqual(c.clean([f]).removed, 0)
        XCTAssertTrue(exists(moved.appendingPathComponent("alpha-deep/node_modules/blob.bin")))
        XCTAssertEqual(calls("worktree remove"), 0)
    }

    // MARK: Stale records

    func testAStaleRecordIsPrunedAndNothingElse() throws {
        let repo = try makeRepo("Developer/alpha")
        let gone = try addWorktree(repo, at: home("Developer/alpha-gone"), branch: "gone")
        let keep = try addWorktree(repo, at: home("Developer/alpha-keep"), branch: "keep")
        try FileManager.default.removeItem(at: gone)
        let list = scan()
        let prune = try XCTUnwrap(list.first { if case .worktree(.prune) = $0.action { return true }; return false })
        XCTAssertEqual(prune.bytes, 0)
        XCTAssertTrue(prune.location.contains("alpha-gone"))
        XCTAssertNotNil(finding(for: keep, in: list), "the live worktree has its own item")
        XCTAssertNil(finding(for: gone, in: list), "a missing folder has no remove item")
        let report = cleaner().clean([prune])
        XCTAssertEqual(report.removed, 1, "\(report.skipped) \(report.failed)")
        XCTAssertEqual(calls("worktree prune"), 1)
        let after = try XCTUnwrap(Worktrees.list(Git(path: realGit), in: repo))
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(exists(keep.appendingPathComponent("node_modules/blob.bin")))
        XCTAssertEqual(branches(repo), ["gone", "keep", "main"], "no branch is deleted")
    }

    func testAPruneDoesNotRunWhenAnotherRecordIsStaleNow() throws {
        let repo = try makeRepo("Developer/alpha")
        let first = try addWorktree(repo, at: home("Developer/alpha-first"), branch: "first")
        let second = try addWorktree(repo, at: home("Developer/alpha-second"), branch: "second")
        try FileManager.default.removeItem(at: first)
        let prune = try XCTUnwrap(scan().first { if case .worktree(.prune) = $0.action { return true }; return false })
        try FileManager.default.removeItem(at: second)       // a second record went stale after the preview
        let report = cleaner().clean([prune])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(calls("worktree prune"), 0)
    }

    func testAMissingWorktreeOutsideTheHomeFolderIsNeverPruned() throws {
        let repo = try makeRepo("Developer/alpha")
        let outside = box.home.deletingLastPathComponent().appendingPathComponent("unplugged-disk-wt")
        try addWorktree(repo, at: outside, branch: "usb")
        try FileManager.default.removeItem(at: outside)
        XCTAssertNil(scan().first { if case .worktree(.prune) = $0.action { return true }; return false })
        let forgedPrune = Finding(id: "p", ecosystem: .worktrees, title: "p", location: "p", bytes: 0, tier: .review, rebuild: .seconds,
                                  action: .worktree(.prune(repo: repo, paths: [outside.path])))
        XCTAssertEqual(cleaner().clean([forgedPrune]).removed, 0)
        XCTAssertEqual(calls("worktree prune"), 0)
    }

    func testALockedStaleRecordIsNotPruned() throws {
        let repo = try makeRepo("Developer/alpha")
        let wt = try addWorktree(repo, at: home("Developer/alpha-lockgone"), branch: "lockgone")
        git(["worktree", "lock", wt.path], in: repo)
        try FileManager.default.removeItem(at: wt)
        XCTAssertNil(scan().first { if case .worktree(.prune) = $0.action { return true }; return false })
    }

    // MARK: Overlap, menu, words

    func testABuildFolderInsideARemovableWorktreeIsNotCountedTwice() throws {
        let inside = Finding(id: "a", ecosystem: .javascript, title: "node_modules", location: "x", bytes: 9_000_000, tier: .safe, rebuild: .minutes,
                             action: .removeArtifact(home("Developer/w/node_modules")))
        let outside = Finding(id: "b", ecosystem: .javascript, title: "node_modules", location: "x", bytes: 9_000_000, tier: .safe, rebuild: .minutes,
                              action: .removeArtifact(home("Developer/other/node_modules")))
        func wt(_ blocked: String?) -> Finding {
            Finding(id: "w", ecosystem: .worktrees, title: "w", location: "x", bytes: 9_000_000, tier: .review, rebuild: .recreate,
                    action: .worktree(.remove(repo: home("Developer/r"), path: home("Developer/w"))), blockedReason: blocked)
        }
        XCTAssertEqual(DiskScanner.removeWorktreeOverlap([inside, outside, wt(nil)]).map(\.id), ["b", "w"])
        XCTAssertEqual(DiskScanner.removeWorktreeOverlap([inside, outside, wt("It is locked")]).map(\.id), ["a", "b", "w"])
    }

    private func menu(_ findings: [Finding]) -> MenuModel {
        let disk = DiskUsage(total: 500_000_000_000, free: 100_000_000_000)
        return MenuModel.make(MenuInput(result: ScanResult(findings: findings, disk: disk), disk: disk, scanning: false, cleaning: false,
                                        running: RunningSnapshot(apps: []), staleDays: 30))
    }

    private func sampleFindings() -> (removable: Finding, blocked: Finding) {
        let ok = Finding(id: "worktree:/h/Developer/one", ecosystem: .worktrees, title: "one · worktree of alpha", location: "~/Developer/one · branch one",
                         bytes: 80_000_000, tier: .review, rebuild: .recreate,
                         action: .worktree(.remove(repo: URL(fileURLWithPath: "/h/Developer/alpha"), path: URL(fileURLWithPath: "/h/Developer/one"))),
                         note: "No changes that are not committed")
        let no = Finding(id: "worktree:/h/Developer/two", ecosystem: .worktrees, title: "two · worktree of alpha", location: "~/Developer/two · branch two",
                         bytes: 60_000_000, tier: .review, rebuild: .recreate,
                         action: .worktree(.remove(repo: URL(fileURLWithPath: "/h/Developer/alpha"), path: URL(fileURLWithPath: "/h/Developer/two"))),
                         note: "It has changes that are not committed", blockedReason: "It has changes that are not committed")
        return (ok, no)
    }

    func testTheMenuShowsABlockedWorktreeWithNoActionAndNeverPutsOneInABulkClean() throws {
        let (ok, no) = sampleFindings()
        let model = menu([ok, no])
        let group = try XCTUnwrap(model.rows.first { $0.title == "Git worktrees" })
        let rows = try XCTUnwrap(group.submenu).rows
        let blockedRow = try XCTUnwrap(rows.first { $0.title.hasPrefix("two") })
        XCTAssertFalse(blockedRow.enabled)
        XCTAssertNil(blockedRow.action)
        XCTAssertEqual(blockedRow.subtitle, "It has changes that are not committed")
        XCTAssertTrue(rows.contains { $0.title == "Stays · cannot be removed here" })
        let okRow = try XCTUnwrap(rows.first { $0.title.hasPrefix("one") })
        guard case .clean(let prompt)? = okRow.action else { return XCTFail("no dialog") }
        XCTAssertEqual(prompt.findings.map(\.id), [ok.id])
        XCTAssertTrue(prompt.cancelIsDefault, "the default button keeps the worktree")
        XCTAssertEqual(prompt.title, "Remove this git worktree?")
        // No bulk row anywhere takes a worktree.
        func bulk(_ rows: [MenuModel.Row]) -> [MenuModel.Row] {
            rows.flatMap { r -> [MenuModel.Row] in
                var out: [MenuModel.Row] = []
                if case .clean(let p)? = r.action, p.findings.count != 1 || p.findings.contains(where: { $0.ecosystem == .worktrees }) && p.findings.count > 1 { out.append(r) }
                if let sub = r.submenu { out += bulk(sub.rows) }
                return out
            }
        }
        XCTAssertTrue(bulk(model.rows).allSatisfy { r in
            if case .clean(let p)? = r.action { return !p.findings.contains { $0.ecosystem == .worktrees } }
            return true
        })
    }

    func testABlockedWorktreeAddsNothingToTheTotals() {
        let (ok, no) = sampleFindings()
        XCTAssertEqual(ScanResult(findings: [ok, no], disk: DiskUsage(total: 1, free: 1)).reviewable, ok.bytes)
        XCTAssertEqual(SplitBar.rowBytes([ok, no]), ok.bytes)
    }

    func testWhenNoWorktreeCanBeRemovedAGoodToKnowRowSaysSo() throws {
        let (ok, no) = sampleFindings()
        XCTAssertNil(StorageFacts.worktrees([ok, no]))
        let row = try XCTUnwrap(StorageFacts.worktrees([no]))
        XCTAssertTrue(row.title.contains("1 git worktree stays"), row.title)
        XCTAssertTrue(StorageFacts.rows(from: [no]).contains(row))
    }

    func testTheDialogsKeepTheDefaultAndNeverSayUnused() {
        let (ok, no) = sampleFindings()
        let prune = Finding(id: "p", ecosystem: .worktrees, title: "alpha · 1 record of missing worktrees", location: "~/x", bytes: 0, tier: .review,
                            rebuild: .seconds, action: .worktree(.prune(repo: URL(fileURLWithPath: "/h/Developer/alpha"), paths: ["/h/x"])))
        for f in [ok, no, prune] {
            let c = Confirmation.forOne(f, staleDays: 30)
            XCTAssertTrue(c.cancelIsDefault)
            let all = [f.title, f.location, f.note ?? "", f.blockedReason ?? "", c.title, c.body, c.footer ?? "", c.confirmTitle ?? ""].joined(separator: " ").lowercased()
            XCTAssertFalse(all.contains("unused"), all)
        }
        XCTAssertEqual(Confirmation.kind(of: ok), .worktree)
        XCTAssertEqual(Confirmation.kind(of: prune), .worktreeRecords)
    }

    func testTrashModeSaysThatGitRemovesItAndItDoesNotGoToTheTrash() {
        let (ok, _) = sampleFindings()
        XCTAssertFalse(DeleteMode.movesFiles(ok.action))
        let note = DeleteModeText.note(mode: .trash, findings: [ok])
        XCTAssertTrue(note.contains("This item is not a file. A tool removes it for good. It does not go to the Trash."), note)
        let c = Confirmation.forOne(ok, staleDays: 30)
        XCTAssertEqual(DeleteModeText.footer(c.footer ?? "", mode: .trash, findings: [ok]), c.footer, "no file in the list: the footer keeps its words")
        XCTAssertEqual(DeleteModeText.note(mode: .permanent, findings: [ok]), "")
    }

    // MARK: Source scan

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/PandaCore/\(name)"), encoding: .utf8)
    }

    func testTheWorktreeCodeNeverForcesAndNeverStartsAProcessItself() throws {
        let cleaner = try source("Cleaner.swift")
        let start = try XCTUnwrap(cleaner.range(of: "// MARK: Worktrees")).lowerBound
        let end = try XCTUnwrap(cleaner.range(of: "// MARK: AI agents")).lowerBound
        let section = String(cleaner[start..<end])
        for (name, text) in [("Worktrees.swift", try source("Worktrees.swift")), ("Cleaner worktree section", section)] {
            XCTAssertFalse(text.contains("--force"), name)
            XCTAssertFalse(text.contains("\"-f\""), name)
            XCTAssertFalse(text.contains("--no-verify"), name)
            XCTAssertFalse(text.contains("Process("), name)
            XCTAssertFalse(text.contains("\"-D\""), name)
            XCTAssertFalse(text.contains("\"branch\", \"-"), "a branch is never deleted: \(name)")
        }
        XCTAssertFalse(section.contains("removeItem"), "the worktree handler never deletes files itself")
        XCTAssertFalse(section.contains("dispose("), "the worktree handler never deletes files itself")
        XCTAssertFalse(section.contains("trashItem"))
    }

    func testTheOnlyGitCommandsThatChangeTheRepositoryAreRemoveAndPrune() throws {
        let text = try source("Worktrees.swift") + (try source("Cleaner.swift"))
        for word in ["\"checkout\"", "\"reset\"", "\"clean\"", "\"gc\"", "\"push\"", "\"commit\"", "\"stash\"", "\"rm\"", "\"branch\""] {
            XCTAssertFalse(text.contains("run([\(word)"), word)
        }
        XCTAssertTrue(Shell.systemTools["git"] == "/usr/bin/git", "git has one fixed path")
    }

    func testGitIsStartedWithoutTheVariablesThatPointToAnotherRepository() {
        XCTAssertTrue(Git.unsetVariables.contains("GIT_DIR"))
        XCTAssertTrue(Git.unsetVariables.contains("GIT_WORK_TREE"))
    }
}
