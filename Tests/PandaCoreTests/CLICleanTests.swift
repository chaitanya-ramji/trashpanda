import CryptoKit
import XCTest
@testable import PandaCore

/// Step 3 of #197: `trashpanda --clean-safe --yes`, the one command line command that deletes.
///
/// EVERY test here uses a fixture home (a made temp folder). None of them touches the real home folder, the real Trash, or the real
/// log. The Trash is a folder inside the fixture. A tool item never reaches a real tool: the Cleaner of the hand-built tests has fake
/// finders, and each fake counts its calls. A test that starts the binary must use `FakeHomeEnvironment` (none does here).
final class CLICleanTests: XCTestCase {
    private let mb = 1_500_000

    // MARK: Fixture

    private func makeHome() throws -> Sandbox {
        let box = try Sandbox()
        try box.file("Library/Caches/pip/data.bin", bytes: mb)                  // safe
        try box.file("Library/Caches/pip/sub/more.bin", bytes: 100)
        try box.file("Library/Caches/Yarn/data.bin", bytes: mb)                 // safe
        try box.file("Library/pnpm/store/data.bin", bytes: mb)                  // review
        try box.file("Library/Caches/node-gyp/data.bin", bytes: mb)             // on the keep list
        try box.file("Developer/app/package.json", bytes: 10)
        try box.file("Developer/app/node_modules/x/data.bin", bytes: mb)        // a build folder of a project
        try box.file("Documents/letter.txt", bytes: 100)                         // personal data
        try box.file(".ssh/id_test", bytes: 100)                                 // a secret
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches/linked"),
                                                   withDestinationURL: box.home.appendingPathComponent("Documents"))
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        for case let url as URL in FileManager.default.enumerator(at: box.home, includingPropertiesForKeys: nil)! {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        return box
    }

    private func scanner(_ box: Sandbox, mode: DeleteMode = .permanent) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(keep: [box.home.path + "/Library/Caches/node-gyp"], deleteMode: mode),
                    useOwnerTools: false, programPaths: { [] }, openClaudeBinaries: { _ in [] }, appName: { _ in nil },
                    activeDirectories: { [] })
    }

    /// path -> kind, size, modification time, link target, and a hash of the bytes, for every file and folder below `root`.
    private func snapshot(_ root: URL) -> [String: String] {
        // The keys are paths below `root` (the root is "."). /var and /private/var are one place, so full paths would not compare.
        var out: [String: String] = [:]
        let fm = FileManager.default
        func describe(_ url: URL) -> String {
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let type = (attrs[.type] as? FileAttributeType)?.rawValue ?? "?"
            let time = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            // SHA-256 of the whole content: a real content hash, so `byte-identical` is true.
            let bytes = type == FileAttributeType.typeRegular.rawValue
                ? ((try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unreadable") : "-"
            return "\(type) \(size) \(time) \(target) \(bytes)"
        }
        out["."] = describe(root)
        for sub in (try? fm.subpathsOfDirectory(atPath: root.path)) ?? [] {
            out[sub] = describe(root.appendingPathComponent(sub))
        }
        return out
    }

    /// Checks that `after` is `before` without the removed paths, and that every other entry is equal (bytes, size, time, links).
    /// `gone` are paths that must not exist any more (and nothing below them). `touched` are folders that may show a new time,
    /// because a child was removed. They must still exist, and they are only compared by kind.
    private func assertOnlyChanged(_ before: [String: String], _ after: [String: String], gone: [String], touched: [String],
                                   file: StaticString = #filePath, line: UInt = #line) {
        func isGone(_ path: String) -> Bool { gone.contains { path == $0 || path.hasPrefix($0 + "/") } }
        for (path, was) in before {
            if isGone(path) {
                XCTAssertNil(after[path], "\(path) must be gone", file: file, line: line)
            } else if touched.contains(path) {
                XCTAssertEqual(after[path]?.split(separator: " ").first, was.split(separator: " ").first, "\(path) stays a folder", file: file, line: line)
            } else {
                XCTAssertEqual(after[path], was, "\(path) must be byte-identical and time-identical", file: file, line: line)
            }
        }
        for path in after.keys where before[path] == nil { XCTFail("\(path) is new", file: file, line: line) }
    }

    private func lockFolder(_ box: Sandbox) -> URL { box.home.deletingLastPathComponent().appendingPathComponent("locks") }
    private func trashFolder(_ box: Sandbox) -> URL { box.home.deletingLastPathComponent().appendingPathComponent("fixture-trash") }

    /// The move to the Trash of the tests: it moves the item into a folder inside the fixture. The real Trash is never used.
    private func trasher(_ box: Sandbox) -> (URL) throws -> Void {
        let folder = trashFolder(box)
        return { url in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
    }

    private func environment(_ box: Sandbox, mode: DeleteMode = .permanent, stop: CLIStop = CLIStop(), euid: UInt32 = 501,
                             willClean: ((Finding) -> Void)? = nil, lock: URL? = nil,
                             refresh: @escaping @Sendable () -> Void = {}) -> CLICleanEnvironment {
        var env = CLICleanEnvironment()
        // The default hook runs the main run loop. Tests do not: they count the calls where it matters.
        env.refreshRunningApps = refresh
        env.homeValues = { (box.home.path, box.home.path, box.home.path) }
        env.lockFolder = lock ?? lockFolder(box)
        env.effectiveUserID = { euid }
        env.stop = stop
        env.activeDirectories = { [] }
        env.willClean = willClean
        if mode == .trash { env.moveToTrash = trasher(box) }
        return env
    }

    private struct Run {
        var result: CLIResult?
        var logs: [String]
        var scannersBuilt: Int
        var sentToCleaner: [String]
    }

    /// Runs the command like `main.swift` does, on the fixture home. `apps` is read again for each call, so a test can change it.
    private func run(_ args: [String], _ box: Sandbox, mode: DeleteMode = .permanent, stop: CLIStop = CLIStop(), euid: UInt32 = 501,
                     apps: @escaping @Sendable () -> RunningSnapshot = { RunningSnapshot(apps: []) },
                     lock: URL? = nil, refresh: @escaping @Sendable () -> Void = {}, extra: [Finding] = [],
                     before: ((Finding) -> Void)? = nil) -> Run {
        var built = 0
        var logs: [String] = []
        var sent: [String] = []
        var env = environment(box, mode: mode, stop: stop, euid: euid, willClean: { f in sent.append(ScanReport.id(f.id, home: box.home.path)); before?(f) }, lock: lock, refresh: refresh)
        if !extra.isEmpty { env.scanResult = { ScanResult(findings: $0.scan().findings + extra, disk: DiskUsage(total: 1, free: 1)) } }
        let result = CLICommand.run(arguments: ["trashpanda"] + args, scanner: { built += 1; return self.scanner(box, mode: mode) }(),
                                    runningApps: RunningApps(apps), version: "9.9.9", clean: env, log: { _, text in logs.append(text) })
        return Run(result: result, logs: logs, scannersBuilt: built, sentToCleaner: sent)
    }

    private func decodeClean(_ run: Run) throws -> CleanReportJSON {
        let out = try XCTUnwrap(run.result?.stdout)
        return try JSONDecoder().decode(CleanReportJSON.self, from: Data(out.utf8))
    }

    private func dryRunReport(_ box: Sandbox, mode: DeleteMode = .permanent) throws -> DryRunReport {
        let r = run(["--clean-safe", "--dry-run", "--json"], box, mode: mode)
        return try JSONDecoder().decode(DryRunReport.self, from: Data(try XCTUnwrap(r.result?.stdout).utf8))
    }

    // MARK: End to end on the fixture home

    func testPermanentCleanRemovesExactlyTheDryRunItemsAndNothingElse() throws {
        let box = try makeHome()
        let preview = try dryRunReport(box)
        let planned = Set(preview.findings.filter(\.wouldClean).map(\.base.id))
        XCTAssertGreaterThanOrEqual(planned.count, 2, "pip and Yarn at least")
        let before = snapshot(box.home)

        let r = run(["--clean-safe", "--yes", "--json"], box)
        XCTAssertEqual(r.result?.exitCode, 0)
        XCTAssertEqual(r.result?.stderr, "")
        let report = try decodeClean(r)
        XCTAssertEqual(report.mode, "clean")
        XCTAssertEqual(report.deleteMode, "permanent")
        XCTAssertEqual(report.schema, 1)
        XCTAssertFalse(report.stopped)
        // The dry run is an exact preview: the cleaned set is the planned set, and the Cleaner got exactly that set.
        let cleaned = Set(report.findings.filter { $0.result == "cleaned" }.map(\.base.id))
        XCTAssertEqual(cleaned, planned)
        XCTAssertEqual(Set(r.sentToCleaner), planned)
        XCTAssertEqual(r.sentToCleaner.count, planned.count, "each item goes once")
        for e in report.findings where e.result != "cleaned" {
            XCTAssertEqual(e.result, "skipped", e.base.id)
            XCTAssertFalse(e.skipReason.isEmpty, e.base.id)
            XCTAssertEqual(e.failReason, "")
            XCTAssertEqual(e.freedBytes, 0)
        }
        for e in report.findings where e.result == "cleaned" { XCTAssertEqual(e.skipReason, ""); XCTAssertEqual(e.failReason, "") }
        XCTAssertEqual(report.totals.cleaned, planned.count)
        XCTAssertEqual(report.totals.failed, 0)
        XCTAssertEqual(report.totals.freedBytes, report.findings.reduce(0) { $0 + $1.freedBytes })
        XCTAssertGreaterThan(report.totals.freedBytes, 2 * Int64(mb) - 1)
        XCTAssertEqual(report.totals.movedToTrashBytes, 0)
        XCTAssertEqual(report.note, "")

        let home = box.home.path
        var gone = ["Library/Caches/pip/data.bin", "Library/Caches/pip/sub", "Library/Caches/Yarn/data.bin"]
        var touched = [".", "Library/Caches/pip", "Library/Caches/Yarn"]
        if planned.contains(where: { $0.contains("node_modules") }) {
            gone.append("Developer/app/node_modules")
            touched.append("Developer/app")
        }
        XCTAssertTrue(planned.contains { $0.contains("node_modules") }, "the build folder is part of the fixture clean")
        assertOnlyChanged(before, snapshot(box.home), gone: gone, touched: touched)
        for kept in ["Library/pnpm/store/data.bin", "Library/Caches/node-gyp/data.bin", "Documents/letter.txt", ".ssh/id_test"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent(kept).path), kept)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/Library/Caches/linked"), home + "/Documents")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashFolder(box).path), "permanent mode never uses the Trash")
    }

    func testTrashModeMovesTheSameItemsIntoTheFixtureTrashAndSaysTheSpaceIsNotFree() throws {
        let box = try makeHome()
        let planned = Set(try dryRunReport(box, mode: .trash).findings.filter(\.wouldClean).map(\.base.id))
        let before = snapshot(box.home)
        let r = run(["--clean-safe", "--yes", "--json"], box, mode: .trash)
        XCTAssertEqual(r.result?.exitCode, 0)
        let report = try decodeClean(r)
        XCTAssertEqual(report.deleteMode, "trash")
        XCTAssertEqual(report.note, DeleteModeText.notFreeYet)
        XCTAssertEqual(Set(report.findings.filter { $0.result == "cleaned" }.map(\.base.id)), planned)
        XCTAssertEqual(report.totals.freedBytes, 0, "files that move to the Trash are not freed")
        XCTAssertGreaterThan(report.totals.movedToTrashBytes, 2 * Int64(mb) - 1)
        var gone = ["Library/Caches/pip/data.bin", "Library/Caches/pip/sub", "Library/Caches/Yarn/data.bin"]
        var touched = [".", "Library/Caches/pip", "Library/Caches/Yarn"]
        if planned.contains(where: { $0.contains("node_modules") }) {
            gone.append("Developer/app/node_modules")
            touched.append("Developer/app")
        }
        assertOnlyChanged(before, snapshot(box.home), gone: gone, touched: touched)
        let moved = try FileManager.default.contentsOfDirectory(atPath: trashFolder(box).path)
        XCTAssertFalse(moved.isEmpty, "the items are in the folder of the fixture")
        XCTAssertTrue(moved.contains { $0.hasSuffix("data.bin") })

        let text = try XCTUnwrap(run(["--clean-safe", "--yes"], try makeHome(), mode: .trash).result?.stdout)
        XCTAssertTrue(text.contains(DeleteModeText.notFreeYet), text)
        XCTAssertTrue(text.contains("to the Trash"), text)
        XCTAssertFalse(text.contains("Freed 0"), "trash mode never says Freed for bytes that only move: \(text)")
    }

    func testTextOfAPermanentCleanSaysMeasuredAndNeverTheTrashLine() throws {
        let box = try makeHome()
        let text = try XCTUnwrap(run(["--clean-safe", "--yes"], box).result?.stdout)
        XCTAssertTrue(text.contains("cleaned"), text)
        XCTAssertTrue(text.contains("(measured)"), text)
        XCTAssertFalse(text.contains("Trash"), text)
    }

    // MARK: Exit codes

    func testAFailingItemGivesExit1AndTheOtherItemsAreStillCleaned() throws {
        let box = try makeHome()
        let locked = box.home.appendingPathComponent("Library/Caches/pip/locked")
        try box.file("Library/Caches/pip/locked/inner.bin", bytes: 100)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let r = run(["--clean-safe", "--yes", "--json"], box)
        XCTAssertEqual(r.result?.exitCode, 1)
        let report = try decodeClean(r)
        let pip = try XCTUnwrap(report.findings.first { $0.base.location.hasSuffix("Library/Caches/pip") })
        XCTAssertEqual(pip.result, "failed")
        XCTAssertEqual(pip.skipReason, "")
        XCTAssertTrue(pip.failReason.contains("stayed"), pip.failReason)
        XCTAssertFalse(pip.failReason.contains(box.home.path), "the home folder is written as ~")
        XCTAssertGreaterThan(pip.freedBytes, 0, "the part that left the disk is shown")
        XCTAssertGreaterThanOrEqual(report.totals.failed, 1)
        // The partial result is real: the files that could be removed are gone, the locked folder stays.
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("Library/Caches/pip/data.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.appendingPathComponent("inner.bin").path))
        let yarn = try XCTUnwrap(report.findings.first { $0.base.location.hasSuffix("Library/Caches/Yarn") })
        XCTAssertEqual(yarn.result, "cleaned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("Library/Caches/Yarn/data.bin").path))
        XCTAssertTrue(r.logs.last?.contains("exit=1") == true)
        XCTAssertTrue(r.logs.contains { $0.contains("result=failed") })
    }

    func testSkipsAreNotFailures() throws {
        let box = try makeHome()
        let r = run(["--clean-safe", "--yes"], box)
        XCTAssertEqual(r.result?.exitCode, 0)
        XCTAssertTrue(r.result?.stdout.contains("skipped") == true)
    }

    func testRootIsRefusedWithExit77AndNothingRuns() throws {
        let box = try makeHome()
        let before = snapshot(box.home)
        let r = run(["--clean-safe", "--yes"], box, euid: 0)
        XCTAssertEqual(r.result?.exitCode, 77)
        XCTAssertEqual(r.result?.stdout, "")
        XCTAssertTrue(r.result?.stderr.contains("does not run as root") == true)
        XCTAssertEqual(r.scannersBuilt, 0, "no scan before the root check")
        XCTAssertTrue(r.sentToCleaner.isEmpty)
        XCTAssertEqual(snapshot(box.home), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockFolder(box).path), "no lock is made")
        XCTAssertTrue(r.logs.contains { $0.contains("refused to run as root, exit 77") })
        // The dry run is not affected by the root check: it only reads.
        XCTAssertEqual(run(["--clean-safe", "--dry-run"], box, euid: 0).result?.exitCode, 0)
    }

    func testAnUnknownHomeFolderGivesExit1AndNeverFallsBackToTheRoot() throws {
        let box = try makeHome()
        let before = snapshot(box.home)
        for home in [URL(fileURLWithPath: "/"), box.home.appendingPathComponent("nope"), box.home.appendingPathComponent("Documents/letter.txt")] {
            var logs: [String] = []
            let bad = DiskScanner(home: home, config: Config(keep: [], deleteMode: .permanent), useOwnerTools: false, programPaths: { [] },
                                  openClaudeBinaries: { _ in [] }, appName: { _ in nil }, activeDirectories: { [] })
            let result = CLICommand.run(arguments: ["t", "--clean-safe", "--yes"], scanner: bad, runningApps: RunningApps { RunningSnapshot(apps: []) },
                                        clean: environment(box), log: { _, text in logs.append(text) })
            XCTAssertEqual(result?.exitCode, 1, home.path)
            XCTAssertTrue(result?.stderr.contains("home folder could not be found") == true, home.path)
            XCTAssertFalse(logs.contains { $0.contains("plan:") }, "no scan, no plan")
            XCTAssertEqual(logs, [], "no log line before the home is known to exist: the log would make it")
        }
        XCTAssertEqual(snapshot(box.home), before)
    }

    func testNothingToCleanIsExit0() throws {
        let box = try Sandbox()
        try box.file("Documents/letter.txt", bytes: 100)
        let before = snapshot(box.home)
        let text = run(["--clean-safe", "--yes"], box)
        XCTAssertEqual(text.result?.exitCode, 0)
        XCTAssertEqual(text.result?.stdout, "Nothing to clean.\n")
        let json = try decodeClean(run(["--clean-safe", "--yes", "--json"], box))
        XCTAssertEqual(json.findings.count, 0)
        XCTAssertEqual(json.totals.cleaned, 0)
        XCTAssertEqual(json.totals.freedBytes, 0)
        XCTAssertEqual(snapshot(box.home), before)
    }

    // MARK: The lock

    func testALockThatAnotherRunHoldsGivesExit75AndNothingIsDeleted() throws {
        let box = try makeHome()
        let before = snapshot(box.home)
        let held = try XCTUnwrap(try? CLILock.acquire(in: lockFolder(box)).get())
        let r = run(["--clean-safe", "--yes"], box)
        XCTAssertEqual(r.result?.exitCode, 75)
        XCTAssertEqual(r.result?.stdout, "")
        XCTAssertTrue(r.result?.stderr.contains("Another trashpanda clean is running") == true)
        XCTAssertTrue(r.sentToCleaner.isEmpty)
        XCTAssertEqual(snapshot(box.home), before)
        XCTAssertTrue(r.logs.contains { $0.contains("lock is held by another run, exit 75") })
        held.release()
        // The lock is free again: the run goes on and the lock is free after it.
        XCTAssertEqual(run(["--clean-safe", "--yes"], box).result?.exitCode, 0)
        XCTAssertNoThrow(try CLILock.acquire(in: lockFolder(box)).get().release())
    }

    func testTheLockIsARealFlockWithPrivateModes() throws {
        let box = try Sandbox()
        let folder = box.home.deletingLastPathComponent().appendingPathComponent("lock-test/logs")
        let first = try CLILock.acquire(in: folder).get()
        let path = folder.appendingPathComponent("clean.lock").path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        // A second lock does not wait. It fails at once.
        let started = Date()
        XCTAssertEqual(CLILock.acquire(in: folder).mapError { $0 }.failureValue, .held)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        // A real flock from another descriptor says the same.
        let other = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(other, 0)
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        first.release()
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0, "released, so another descriptor can take it")
        close(other)
        XCTAssertNoThrow(try CLILock.acquire(in: folder).get().release())
    }

    func testALinkInPlaceOfTheLockFileIsRefusedAndNotFollowed() throws {
        let box = try Sandbox()
        let folder = box.home.deletingLastPathComponent().appendingPathComponent("lock-link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = try box.file("victim.txt", bytes: 5)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("clean.lock"), withDestinationURL: target)
        XCTAssertEqual(CLILock.acquire(in: folder).failureValue.map { if case .cannotOpen = $0 { return true } else { return false } }, true)
        XCTAssertEqual(try Data(contentsOf: target).count, 5)
    }

    // MARK: Signals

    func testASignalBeforeTheFirstItemStopsTheRunAndTheReportIsComplete() throws {
        for (number, code) in [(SIGINT, Int32(130)), (SIGTERM, Int32(143))] {
            let box = try makeHome()
            let before = snapshot(box.home)
            let stop = CLIStop()
            stop.request(signal: number)
            let r = run(["--clean-safe", "--yes", "--json"], box, stop: stop)
            XCTAssertEqual(r.result?.exitCode, code)
            XCTAssertTrue(r.sentToCleaner.isEmpty, "nothing reaches the Cleaner after the signal")
            XCTAssertEqual(snapshot(box.home), before)
            let report = try decodeClean(r)
            XCTAssertTrue(report.stopped)
            XCTAssertEqual(report.totals.cleaned, 0)
            let stoppedItems = report.findings.filter { $0.skipReason == "stopped by signal" }
            XCTAssertFalse(stoppedItems.isEmpty)
            XCTAssertEqual(stoppedItems.count, report.findings.filter(\.wouldClean).count, "every planned item reads exactly this text")
            XCTAssertEqual(report.findings.count, try dryRunReport(try makeHome()).findings.count, "every finding is in the report")
            XCTAssertTrue(r.logs.contains { $0.contains("stopped by signal") })
            XCTAssertTrue(r.logs.last?.contains("exit=\(code)") == true)
            let text = try XCTUnwrap(run(["--clean-safe", "--yes"], try makeHome(), stop: stop).result?.stdout)
            XCTAssertTrue(text.contains("This report is partial."), text)
        }
        XCTAssertEqual(CLIStop().exitCode, 128)
    }

    func testASignalDuringTheRunStopsAfterTheCurrentItem() throws {
        let box = try makeHome()
        let stop = CLIStop()
        var count = 0
        let r = run(["--clean-safe", "--yes", "--json"], box, stop: stop) { _ in
            count += 1
            // The signal comes while the second item is about to run.
            if count == 2 { stop.request(signal: SIGTERM) }
        }
        XCTAssertEqual(r.result?.exitCode, 143)
        let report = try decodeClean(r)
        XCTAssertTrue(report.stopped)
        // The signal comes after the run's own check of item 2, so item 2 still runs and finishes. Item 3 and the rest do not start.
        XCTAssertEqual(report.totals.cleaned, 2, "the second item was already started, so it was finished")
        XCTAssertEqual(r.sentToCleaner.count, 2)
        XCTAssertEqual(report.totals.failed, 0)
        let planned = try dryRunReport(try makeHome()).findings.filter(\.wouldClean).count
        XCTAssertEqual(report.findings.filter { $0.result == "skipped" && $0.skipReason == "stopped by signal" }.count, planned - 2)
        XCTAssertFalse(report.findings.contains { $0.skipReason.contains("Stopped by you") })
    }

    // MARK: Logging

    func testTheLogHasTheAuditTrailAndNoPrivateText() throws {
        let box = try makeHome()
        let r = run(["--clean-safe", "--yes", "--json"], box)
        XCTAssertEqual(r.result?.exitCode, 0)
        let logs = r.logs
        XCTAssertTrue(logs[0].hasPrefix("cli begin version=9.9.9 mode=clean-safe --yes --json"), logs[0])
        XCTAssertTrue(logs[0].contains("options=--clean-safe --yes --json other=0"), logs[0])
        XCTAssertTrue(logs[0].contains("deleteMode=permanent"), logs[0])
        XCTAssertTrue(logs.contains { $0.contains("lock taken") })
        let plan = try XCTUnwrap(logs.first { $0.hasPrefix("cli plan deleteMode=permanent wouldClean=") })
        XCTAssertTrue(plan.contains("wouldFree="), plan)
        let before = logs.filter { $0.hasPrefix("clean item id=") && $0.contains(" bytes=") && $0.contains("action=") }
        let after = logs.filter { $0.hasPrefix("clean item id=") && $0.contains(" result=") }
        XCTAssertEqual(before.count, r.sentToCleaner.count)
        XCTAssertEqual(after.count, r.sentToCleaner.count)
        XCTAssertTrue(after.allSatisfy { $0.contains("freed=") && $0.contains("movedToTrash=") && $0.contains("reason=") })
        XCTAssertTrue(before.allSatisfy { $0.contains("action=removeContents") || $0.contains("action=removeArtifact") })
        let end = try XCTUnwrap(logs.last)
        XCTAssertTrue(end.hasPrefix("cli end clean-safe --yes cleaned="), end)
        for part in ["skipped=", "failed=", "freed=", "movedToTrash=", "duration_ms=", "exit=0"] { XCTAssertTrue(end.contains(part), end) }
        for line in logs {
            XCTAssertFalse(line.contains(box.home.path), "the home folder is written as ~: \(line)")
        }
        // A wrong option logs the known options and a count, never a value.
        let bad = run(["--clean-safe", "--yes", "secret-value"], box)
        XCTAssertEqual(bad.result?.exitCode, 64)
        XCTAssertFalse(bad.logs.contains { $0.contains("secret-value") }, "raw arguments are never logged")
    }

    // MARK: Forged plans: the Cleaner is the only judge, and the command never trusts a plan blindly

    private final class Spy: @unchecked Sendable {
        var tool = 0, docker = 0, trash = 0
        var total: Int { tool + docker + trash }
    }

    private func makeCleaner(_ box: Sandbox, mode: DeleteMode = .permanent, spy: Spy, keep: [String] = [],
                             apps: @escaping @Sendable () -> RunningSnapshot = { RunningSnapshot(apps: []) }) -> Cleaner {
        let c = Cleaner(guardian: PathGuard(home: box.home, keep: keep), remaining: nil,
                        dockerEngine: { spy.docker += 1; return .failure(.noDocker) }, runningApps: RunningApps(apps),
                        simctl: { spy.tool += 1; return nil }, programPaths: { [] },
                        emptyTrash: { spy.trash += 1; return .failure(.notAllowed) }, mountedImages: { [] },
                        brew: { spy.tool += 1; return nil }, openClaudeBinaries: { _ in [] }, ollama: { spy.tool += 1; return nil },
                        hfTool: { spy.tool += 1; return nil }, packageTool: { _ in spy.tool += 1; return nil },
                        runtimeRequests: { spy.tool += 1; return [] }, freeSpace: { _ in 0 }, deleteMode: mode, git: { spy.tool += 1; return nil })
        c.activeDirectories = { [] }
        if mode == .trash { c.useTrashMove(trasher(box)) }
        return c
    }

    private func finding(_ id: String, _ action: Action, tier: Tier = .safe, bytes: Int64 = 1_000, blocked: String? = nil,
                         owner: AppOwner? = nil) -> Finding {
        Finding(id: id, ecosystem: .python, title: id, location: "~/" + id, bytes: bytes, tier: tier, rebuild: .seconds, action: action,
                owner: owner, blockedReason: blocked)
    }

    /// A plan that says `wouldClean` for every finding, whatever the rules say.
    private func forgedPlan(_ findings: [Finding], mode: DeleteMode = .permanent) -> (CleanPlan, ScanResult) {
        let items = findings.map { CleanPlan.Item(finding: $0, wouldClean: true, skipReason: "", checkedNow: false, checkedAtCleanTime: "") }
        return (CleanPlan(items: items, deleteMode: mode, unattended: true),
                ScanResult(findings: findings, disk: DiskUsage(total: 1, free: 1)))
    }

    private func runPlan(_ plan: CleanPlan, _ result: ScanResult, cleaner: Cleaner, box: Sandbox, stop: CLIStop = CLIStop(),
                         sent: ((Finding) -> Void)? = nil) -> CleanRun {
        CLIClean.runPlan(plan: plan, result: result, cleaner: cleaner, home: box.home.path, stop: stop, willClean: sent, log: { _, _ in })
    }

    func testForgedItemsNeverDeleteAnythingOutsideWhatTheGuardsAllow() throws {
        let box = try Sandbox()
        let victim = try box.file("Library/Caches/Victim/keep.me", bytes: 20)
        let outside = try box.file("../outside/keep.me", bytes: 20)
        let letter = try box.file("Documents/letter.txt", bytes: 20)
        let secret = try box.file(".ssh/id_test", bytes: 20)
        let marker = try box.file("Library/Caches/Kept/keep.me", bytes: 20)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches/LinkDir"),
                                                   withDestinationURL: box.home.appendingPathComponent("Library/Caches/Victim"))
        let others = [victim, outside, letter, secret, marker]
        let forged: [Finding] = [
            finding("outside", .removeContents(outside.deletingLastPathComponent())),
            finding("etc", .removeContents(URL(fileURLWithPath: "/etc"))),
            finding("dotdot", .removeContents(URL(fileURLWithPath: box.home.path + "/Library/Caches/Victim/../../../../outside"))),
            finding("documents", .removeContents(box.home.appendingPathComponent("Documents"))),
            finding("ssh", .removeContents(box.home.appendingPathComponent(".ssh"))),
            finding("home", .removeContents(box.home)),
            finding("link", .removeContents(box.home.appendingPathComponent("Library/Caches/LinkDir"))),
            finding("kept", .removeContents(box.home.appendingPathComponent("Library/Caches/Kept"))),
            finding("artifact-link", .removeArtifact(box.home.appendingPathComponent("Library/Caches/LinkDir"))),
            finding("artifact-docs", .removeArtifact(box.home.appendingPathComponent("Documents"))),
            finding("not-there", .removeContents(box.home.appendingPathComponent("Library/Caches/NotThere"))),
        ]
        let before = snapshot(box.home.deletingLastPathComponent())
        let spy = Spy()
        let (plan, result) = forgedPlan(forged)
        let done = runPlan(plan, result, cleaner: makeCleaner(box, spy: spy, keep: [marker.deletingLastPathComponent().path]), box: box)
        for url in others { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.path) must stay") }
        XCTAssertEqual(snapshot(box.home.deletingLastPathComponent()), before, "nothing changed at all")
        XCTAssertEqual(done.cleaned, 0)
        XCTAssertEqual(done.failed, 0)
        XCTAssertEqual(done.skipped, forged.count, "\((0..<forged.count).map { done.outcome($0) })")
        XCTAssertEqual(spy.total, 0)
    }

    func testAToolItemInAForgedPlanNeverReachesTheCleaner() throws {
        let box = try Sandbox()
        let tools: [Finding] = [
            finding("trash", .emptyTrash), finding("docker", .docker(.removeContainer(id: "abc"))),
            finding("brew", .brew(.uninstall(name: "x"))), finding("npm", .globalPackage(manager: .npm, name: "x")),
            finding("ollama", .agent(.removeOllamaModel(name: "m"))), finding("hf", .agent(.removeHuggingFaceRepo(id: "a/b"))),
            finding("runtime", .removeRuntime(storeID: "a", tool: "b", name: "c")),
            finding("worktree", .worktree(.prune(repo: box.home, paths: []))),
            finding("review", .removeContents(box.home), tier: .review), finding("blocked", .removeContents(box.home), blocked: "busy"),
            finding("info", .inform),
        ]
        let spy = Spy()
        var sent: [String] = []
        let (plan, result) = forgedPlan(tools)
        let done = runPlan(plan, result, cleaner: makeCleaner(box, spy: spy), box: box) { sent.append($0.id) }
        XCTAssertEqual(sent, [], "no tool item, review item, blocked item, or information line is sent to the Cleaner")
        XCTAssertEqual(spy.total, 0, "no tool was looked for or run")
        XCTAssertEqual(done.skipped, tools.count)
        XCTAssertEqual(done.outcome(0).skipReason, "needs a person (tool item)")
        XCTAssertEqual(done.outcome(8).skipReason, "not part of the one-click clean")
    }

    func testOnlyTheItemsOfThePlanWithWouldCleanReachTheCleaner() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/A/a.bin", bytes: 20)
        try box.file("Library/Caches/B/b.bin", bytes: 20)
        let a = finding("a", .removeContents(box.home.appendingPathComponent("Library/Caches/A")))
        let b = finding("b", .removeContents(box.home.appendingPathComponent("Library/Caches/B")))
        let items = [CleanPlan.Item(finding: a, wouldClean: true, skipReason: "", checkedNow: true, checkedAtCleanTime: ""),
                     CleanPlan.Item(finding: b, wouldClean: false, skipReason: "on the keep list", checkedNow: true, checkedAtCleanTime: "")]
        let plan = CleanPlan(items: items, deleteMode: .permanent, unattended: true)
        var sent: [String] = []
        let done = runPlan(plan, ScanResult(findings: [a, b], disk: DiskUsage(total: 1, free: 1)), cleaner: makeCleaner(box, spy: Spy()), box: box) {
            sent.append($0.id)
        }
        XCTAssertEqual(sent, ["a"])
        XCTAssertEqual(done.outcome(1).skipReason, "on the keep list", "a skipped item keeps the reason of the plan")
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("Library/Caches/A/a.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("Library/Caches/B/b.bin").path))
    }

    // MARK: Links

    func testAPathThatBecameALinkAfterThePlanIsNotCleaned() throws {
        let box = try Sandbox()
        let victim = try box.file("Library/Caches/Victim/keep.me", bytes: 20)
        let cache = box.home.appendingPathComponent("Library/Caches/Swap")
        let artifact = box.home.appendingPathComponent("Developer/app/node_modules")
        try box.file("Library/Caches/Swap/a.bin", bytes: 100_000)
        try box.file("Developer/app/package.json", bytes: 10)
        try box.file("Developer/app/node_modules/x/b.bin", bytes: 100_000)
        let result = ScanResult(findings: [finding("swap", .removeContents(cache)), finding("art", .removeArtifact(artifact))],
                                disk: DiskUsage(total: 1, free: 1))
        let plan = CleanPlan(result, guardian: PathGuard(home: box.home), running: RunningSnapshot(apps: []), deleteMode: .permanent,
                             activeDirectories: [], unattended: true)
        XCTAssertEqual(plan.wouldClean.count, 2, "the plan said yes: both are real folders now")
        // After the plan, both folders are replaced by links to a folder in the home folder.
        for url in [cache, artifact] {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: victim.deletingLastPathComponent())
        }
        let done = runPlan(plan, result, cleaner: makeCleaner(box, spy: Spy()), box: box)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertEqual(done.cleaned, 0)
        XCTAssertEqual(done.failed, 0)
        XCTAssertEqual(done.skipped, 2)
        XCTAssertTrue(done.outcome(0).skipReason.contains("symbolic link"), done.outcome(0).skipReason)
        XCTAssertTrue(done.outcome(1).skipReason.contains("link"), done.outcome(1).skipReason)
    }

    func testAParentThatBecameALinkIsRefusedByThePlanAndByTheCleaner() throws {
        let box = try Sandbox()
        let leak = try box.file("Other/pip/leak.bin", bytes: 100_000)
        let real = try box.file(".cache/pip/a.bin", bytes: 100_000)
        let target = box.home.appendingPathComponent(".cache/pip")
        let f = finding("pip", .removeContents(target))
        let result = ScanResult(findings: [f], disk: DiskUsage(total: 1, free: 1))
        func plan() -> CleanPlan {
            CleanPlan(result, guardian: PathGuard(home: box.home), running: RunningSnapshot(apps: []), deleteMode: .permanent,
                      activeDirectories: [], unattended: true)
        }
        let planned = plan()
        XCTAssertTrue(planned.items[0].wouldClean, "no link yet")
        // `~/.cache` becomes a link to another folder of the home folder.
        let cache = box.home.appendingPathComponent(".cache")
        try FileManager.default.moveItem(at: cache, to: box.home.appendingPathComponent(".cache-real"))
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: box.home.appendingPathComponent("Other"))
        // The old plan goes to the real Cleaner: it refuses by itself.
        let done = runPlan(planned, result, cleaner: makeCleaner(box, spy: Spy()), box: box)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leak.path), "a file in the linked folder is never deleted")
        XCTAssertEqual(done.skipped, 1)
        XCTAssertEqual(done.failed, 0)
        XCTAssertTrue(done.outcome(0).skipReason.hasSuffix("a folder in the path is a link"), done.outcome(0).skipReason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent(".cache-real/pip/a.bin").path))
        // A new plan says so before the clean.
        XCTAssertFalse(plan().items[0].wouldClean)
        XCTAssertEqual(plan().items[0].skipReason, "a folder in the path is a link")
        _ = real
    }

    func testTheMenuCleanerRefusesAParentLinkWithThePlainReason() throws {
        let box = try Sandbox()
        let leak = try box.file("Other/pip/leak.bin", bytes: 100_000)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".cache"),
                                                   withDestinationURL: box.home.appendingPathComponent("Other"))
        let f = finding("pip", .removeContents(box.home.appendingPathComponent(".cache/pip")))
        let spy = Spy()
        let report = makeCleaner(box, spy: spy).clean([f])
        XCTAssertTrue(FileManager.default.fileExists(atPath: leak.path))
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertTrue(report.skipped.first?.hasSuffix("a folder in the path is a link") == true, "\(report.skipped)")
    }

    func testAChildThatIsALinkInsideAPlainFolderIsStillKept() throws {
        let box = try Sandbox()
        let docs = try box.file("Documents/letter.txt", bytes: 20)
        let folder = box.home.appendingPathComponent("Library/Caches/Mixed")
        try box.file("Library/Caches/Mixed/a.bin", bytes: 100_000)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("child-link"),
                                                   withDestinationURL: box.home.appendingPathComponent("Documents"))
        let f = finding("mixed", .removeContents(folder))
        let (plan, result) = forgedPlan([f])
        let done = runPlan(plan, result, cleaner: makeCleaner(box, spy: Spy()), box: box)
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.bin").path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("child-link").path),
                        "the link itself stays: the guard refuses a link")
        XCTAssertEqual(done.cleaned + done.skipped + done.failed, 1)
    }

    // MARK: The owner app

    func testAnOwnerAppThatOpensBetweenThePlanAndTheCleanSkipsTheItemWithoutAFailure() throws {
        let box = try Sandbox()
        let editor = CleanPlanTests.editor
        let file = try box.file("Library/Caches/Editor/a.bin", bytes: 100_000)
        let f = finding("editor", .removeContents(file.deletingLastPathComponent()), owner: editor)
        let result = ScanResult(findings: [f], disk: DiskUsage(total: 1, free: 1))
        // The app is closed when the plan is made.
        let plan = CleanPlan(result, guardian: PathGuard(home: box.home), running: RunningSnapshot(apps: []), deleteMode: .permanent,
                             activeDirectories: [], unattended: true)
        XCTAssertTrue(plan.items[0].wouldClean)
        // It is open when the Cleaner looks again, right before the item.
        let cleaner = makeCleaner(box, spy: Spy(), apps: { CleanPlanTests.editorOpen })
        let done = runPlan(plan, result, cleaner: cleaner, box: box)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(done.outcome(0).result, .skipped)
        XCTAssertTrue(done.outcome(0).skipReason.contains("Example Editor is running"), done.outcome(0).skipReason)
        XCTAssertEqual(done.failed, 0)
        // Closed: the item is cleaned.
        let again = runPlan(plan, result, cleaner: makeCleaner(box, spy: Spy()), box: box)
        XCTAssertEqual(again.outcome(0).result, .cleaned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnOwnerAppThatIsOpenAtPlanTimeIsSkippedByThePlan() throws {
        let box = try Sandbox()
        let file = try box.file("Library/Caches/Editor/a.bin", bytes: 100)
        let f = finding("editor", .removeContents(file.deletingLastPathComponent()), owner: CleanPlanTests.editor)
        let result = ScanResult(findings: [f], disk: DiskUsage(total: 1, free: 1))
        let plan = CleanPlan(result, guardian: PathGuard(home: box.home), running: CleanPlanTests.editorOpen, deleteMode: .permanent,
                             activeDirectories: [], unattended: true)
        XCTAssertEqual(plan.items[0].skipReason, "owner app is open (Example Editor)")
        var sent = 0
        _ = runPlan(plan, result, cleaner: makeCleaner(box, spy: Spy()), box: box) { _ in sent += 1 }
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Measured bytes

    func testFreedIsMeasuredAndNeverTheEstimate() throws {
        let box = try Sandbox()
        let file = try box.file("Library/Caches/Big/a.bin", bytes: 200_000)
        let f = finding("big", .removeContents(file.deletingLastPathComponent()), bytes: 5_300_000_000)
        let (plan, result) = forgedPlan([f])
        let done = runPlan(plan, result, cleaner: makeCleaner(box, spy: Spy()), box: box)
        XCTAssertEqual(done.outcome(0).result, .cleaned)
        XCTAssertGreaterThanOrEqual(done.outcome(0).freedBytes, 200_000)
        XCTAssertLessThan(done.outcome(0).freedBytes, 1_000_000, "the estimate of 5.3 GB is never reported")
        XCTAssertEqual(done.freedBytes, done.outcome(0).freedBytes)
    }

    func testClassifyTheReportOfTheCleaner() {
        var failedAndPartial = CleanReport()
        failedAndPartial.removed = 1; failedAndPartial.freed = 7; failedAndPartial.failed = ["/Users/example/x: 2 items stayed"]
        let a = CLIClean.classify(failedAndPartial, home: "/Users/example")
        XCTAssertEqual(a.result, .failed)
        XCTAssertEqual(a.freedBytes, 7)
        XCTAssertEqual(a.failReason, "~/x: 2 items stayed")
        XCTAssertEqual(a.skipReason, "")
        var cleaned = CleanReport(); cleaned.removed = 1; cleaned.freed = 9
        XCTAssertEqual(CLIClean.classify(cleaned, home: "/h").result, .cleaned)
        var allChildrenKept = CleanReport(); allChildrenKept.removed = 1; allChildrenKept.skipped = ["/Users/example/x/a: path is on the keep list"]
        let k = CLIClean.classify(allChildrenKept, home: "/Users/example")
        XCTAssertEqual(k.result, .skipped)
        XCTAssertEqual(k.skipReason, "~/x/a: path is on the keep list")
        XCTAssertEqual(CLIClean.classify(CleanReport(), home: "/h").skipReason, "nothing was cleaned")
        var trash = CleanReport(); trash.removed = 1; trash.movedToTrash = 5
        let t = CLIClean.classify(trash, home: "/h")
        XCTAssertEqual(t.result, .cleaned)
        XCTAssertEqual(t.freedBytes, 0)
        XCTAssertEqual(t.movedToTrashBytes, 5)
    }

    // MARK: Goldens of the clean report

    private func golden(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/cleanplan"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The fixture of the plan tests, cleaned for real on a temp home. The sizes are fixed, so the output is the same on every disk.
    static func goldenRun(mode: DeleteMode, box: Sandbox, trash: ((URL) throws -> Void)?) throws -> CleanRun {
        try CleanPlanTests.populate(box)
        let result = CleanPlanTests.fixture(box.home)
        let plan = CleanPlanTests.plan(result, home: box.home, mode: mode)
        let spy = Spy()
        let cleaner = Cleaner(guardian: PathGuard(home: box.home, keep: [box.home.path + "/Library/Caches/Kept"]), remaining: nil,
                              dockerEngine: { spy.docker += 1; return .failure(.noDocker) },
                              runningApps: RunningApps { CleanPlanTests.editorOpen }, simctl: { spy.tool += 1; return nil },
                              programPaths: { [] }, emptyTrash: { spy.trash += 1; return .failure(.notAllowed) },
                              freeSpace: { _ in 0 }, deleteMode: mode)
        cleaner.activeDirectories = { [] }
        cleaner.sizeOf = { url in ((try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty ?? true) ? 0 : 1_000_000_000 }
        if let trash { cleaner.useTrashMove(trash) }
        let done = CLIClean.runPlan(plan: plan, result: result, cleaner: cleaner, home: box.home.path, stop: CLIStop(), willClean: nil,
                                    log: { _, _ in })
        // The fixture has a file item in the Docker group. The Cleaner only looks up the engine for its space note: no command runs.
        XCTAssertEqual(spy.tool + spy.trash, 0, "no tool ran")
        return done
    }

    func testCleanReportEqualsGolden() throws {
        let box = try Sandbox()
        let done = try Self.goldenRun(mode: .permanent, box: box, trash: nil)
        XCTAssertEqual(done.json(), try golden("clean.json"))
        XCTAssertEqual(done.text(verbose: false, nothing: false), try golden("clean.txt"))
        XCTAssertEqual(done.text(verbose: true, nothing: false), try golden("clean-verbose.txt"))
        XCTAssertFalse(done.json().contains(box.home.path), "the output never holds the home folder")
        XCTAssertEqual(done.json().filter { $0 == "\n" }.count, 1)
        let decoded = try JSONDecoder().decode(CleanReportJSON.self, from: Data(done.json().utf8))
        XCTAssertEqual(decoded, CleanReportJSON(done))
    }

    func testCleanReportInTrashModeEqualsGolden() throws {
        let box = try Sandbox()
        let done = try Self.goldenRun(mode: .trash, box: box, trash: trasher(box))
        XCTAssertEqual(done.json(), try golden("clean-trash.json"))
        XCTAssertEqual(done.text(verbose: false, nothing: false), try golden("clean-trash.txt"))
        XCTAssertTrue(done.json().contains(DeleteModeText.notFreeYet))
        XCTAssertTrue(done.text(verbose: false, nothing: false).contains(DeleteModeText.notFreeYet))
    }

    func testTheFieldsOfTheScanAndTheDryRunAreUnchangedInTheCleanReport() throws {
        let box = try Sandbox()
        let done = try Self.goldenRun(mode: .permanent, box: box, trash: nil)
        let scan = ScanReport(done.result, home: box.home.path)
        let report = CleanReportJSON(done)
        XCTAssertEqual(report.findings.map(\.base), scan.findings)
        XCTAssertEqual(report.disk, scan.disk)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(done.json().utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "mode", "deleteMode", "stopped", "note", "disk", "totals", "findings"])
        XCTAssertEqual(Set((object["totals"] as? [String: Any] ?? [:]).keys),
                       ["reclaimable", "reviewable", "cleaned", "skipped", "failed", "freedBytes", "movedToTrashBytes", "wouldFree"])
        for entry in try XCTUnwrap(object["findings"] as? [[String: Any]]) {
            XCTAssertEqual(Set(entry.keys), ["id", "group", "title", "bytes", "tier", "rebuild", "location", "blocked", "blockedReason",
                                             "upperLimit", "countedBytes", "result", "skipReason", "failReason", "freedBytes",
                                             "movedToTrashBytes", "wouldClean", "checkedNow", "checkedAtCleanTime"])
        }
    }

    func testTheCleanReportCarriesTheFieldsOfThePlan() throws {
        let box = try Sandbox()
        let done = try Self.goldenRun(mode: .permanent, box: box, trash: nil)
        let report = CleanReportJSON(done)
        let dry = DryRunReport(done.result, plan: done.plan, home: box.home.path)
        XCTAssertEqual(report.totals.wouldFree, dry.totals.wouldFree)
        XCTAssertGreaterThan(report.totals.wouldFree, 0)
        XCTAssertEqual(report.findings.map(\.wouldClean), dry.findings.map(\.wouldClean))
        XCTAssertEqual(report.findings.map(\.checkedNow), dry.findings.map(\.checkedNow))
        XCTAssertEqual(report.findings.map(\.checkedAtCleanTime), dry.findings.map(\.checkedAtCleanTime))
    }

    // MARK: The dry run is an exact preview of --yes

    /// A fixture with a file item (pip) and a tool item (a Homebrew-style item built by hand is not possible through the scan, so a
    /// scanner that finds the file item and a hand-made tool finding is used): the dry run and the clean use ONE plan factory.
    func testTheDryRunAndTheCleanMakeTheSamePlanAndTheCleanSendsExactlyTheWouldCleanSet() throws {
        let box = try makeHome()
        let result = scanner(box).scan()
        let tool = Finding(id: "tool.item", ecosystem: .homebrew, title: "A tool item", location: "~/tool", bytes: 10, tier: .safe,
                           rebuild: .download, action: .brew(.uninstall(name: "x")))
        let withTool = ScanResult(findings: result.findings + [tool], disk: result.disk)
        let sc = scanner(box)
        let running = RunningSnapshot(apps: [])
        let plan = CleanPlan.unattended(withTool, scanner: sc, running: running, activeDirectories: [], now: Date())
        let toolItem = try XCTUnwrap(plan.items.first { $0.finding.id == "tool.item" })
        XCTAssertFalse(toolItem.wouldClean)
        XCTAssertEqual(toolItem.skipReason, "needs a person (tool item)")
        XCTAssertTrue(plan.unattended, "the shared factory makes an unattended plan: a tool item is never cleaned")
        // The same factory feeds the run: the Cleaner gets exactly the items of this plan with wouldClean.
        var sent: [String] = []
        let done = CLIClean.runPlan(plan: plan, result: withTool, cleaner: makeCleaner(box, spy: Spy()), home: box.home.path, stop: CLIStop(),
                                    willClean: { sent.append(ScanReport.id($0.id, home: box.home.path)) }, log: { _, _ in })
        let planned = Set(plan.wouldClean.map { ScanReport.id($0.finding.id, home: box.home.path) })
        XCTAssertEqual(Set(sent), planned)
        XCTAssertFalse(sent.contains("tool.item"))
        XCTAssertEqual(done.cleaned, planned.count)
    }

    func testTheDryRunJSONMarksAToolItemAndItsWouldCleanSetIsWhatTheCleanSends() throws {
        let box = try makeHome()
        let tool = Finding(id: "tool.item", ecosystem: .homebrew, title: "A tool item", location: "~/tool", bytes: 10, tier: .safe,
                           rebuild: .download, action: .brew(.uninstall(name: "x")))
        let dry = run(["--clean-safe", "--dry-run", "--json"], box, extra: [tool])
        let preview = try JSONDecoder().decode(DryRunReport.self, from: Data(try XCTUnwrap(dry.result?.stdout).utf8))
        let toolEntry = try XCTUnwrap(preview.findings.first { $0.base.id == "tool.item" })
        XCTAssertFalse(toolEntry.wouldClean)
        XCTAssertEqual(toolEntry.skipReason, "needs a person (tool item)")
        let planned = Set(preview.findings.filter(\.wouldClean).map(\.base.id))
        XCTAssertFalse(planned.isEmpty, "the file items are planned")
        let r = run(["--clean-safe", "--yes", "--json"], box, extra: [tool])
        XCTAssertEqual(Set(r.sentToCleaner), planned, "the clean sends exactly the wouldClean set of the dry run")
        XCTAssertFalse(r.sentToCleaner.contains("tool.item"))
        let report = try decodeClean(r)
        XCTAssertEqual(report.findings.first { $0.base.id == "tool.item" }?.skipReason, "needs a person (tool item)")
        XCTAssertEqual(report.findings.first { $0.base.id == "tool.item" }?.wouldClean, false)
    }

    // MARK: Stray arguments never reach the run

    func testStrayArgumentsGive64WithNoScanAndNoLock() throws {
        let box = try makeHome()
        let before = snapshot(box.home)
        for args in [["--clean-safe", "--yes", "/some/path"], ["--clean-safe", "--yes", ""], ["onlythis", "--clean-safe", "--yes"],
                     ["--clean-safe", "--yes", "--yes"], ["--clean-safe", "--clean-safe", "--yes"], ["--clean-safe", "--yes", "--json", "--json"],
                     ["--clean-safe", "--yes", "-psn_0_12345"], ["--clean-safe", "--yes", "--verbose", "--verbose"],
                     ["--clean-safe", "--dry-run", "x"], ["--clean-safe", "--dry-run", "--json", "--json"]] {
            let r = run(args, box)
            XCTAssertEqual(r.result?.exitCode, 64, "\(args)")
            XCTAssertEqual(r.scannersBuilt, 0, "\(args)")
            XCTAssertTrue(r.sentToCleaner.isEmpty, "\(args)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: lockFolder(box).path), "\(args): no lock")
        }
        XCTAssertEqual(snapshot(box.home), before)
    }

    // MARK: A lock that cannot be opened stops the run

    private func assertLockRefusal(_ lock: URL, _ box: Sandbox, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let before = snapshot(box.home)
        let r = run(["--clean-safe", "--yes", "--json"], box, lock: lock)
        XCTAssertEqual(r.result?.exitCode, 1, name, file: file, line: line)
        XCTAssertEqual(r.result?.stdout, "", name, file: file, line: line)
        XCTAssertTrue(r.result?.stderr.contains("The lock could not be taken") == true, name, file: file, line: line)
        XCTAssertTrue(r.sentToCleaner.isEmpty, "\(name): the Cleaner is never called", file: file, line: line)
        XCTAssertTrue(r.logs.contains { $0.contains("lock could not be taken, exit 1") }, "\(name): \(r.logs)", file: file, line: line)
        XCTAssertFalse(r.logs.contains { $0.contains("plan:") || $0.hasPrefix("cli plan") }, "\(name): no plan", file: file, line: line)
        XCTAssertEqual(snapshot(box.home), before, name, file: file, line: line)
    }

    func testARunWithALockThatCannotBeOpenedExits1AndNeverCallsTheCleaner() throws {
        let holder = try Sandbox()
        let outside = holder.home.deletingLastPathComponent()
        let box = try makeHome()
        // 1. The log folder is a regular file.
        let notAFolder = outside.appendingPathComponent("lock-is-a-file")
        try Data("x".utf8).write(to: notAFolder)
        assertLockRefusal(notAFolder, box, "folder is a file")
        // 2. The lock file is a link.
        let linked = outside.appendingPathComponent("lock-link-run")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("clean.lock"),
                                                   withDestinationURL: box.home.appendingPathComponent("Documents/letter.txt"))
        assertLockRefusal(linked, box, "lock file is a link")
        XCTAssertEqual(try Data(contentsOf: box.home.appendingPathComponent("Documents/letter.txt")).count, 100)
        // 3. The lock file is a FIFO.
        let fifo = outside.appendingPathComponent("lock-fifo")
        try FileManager.default.createDirectory(at: fifo, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(fifo.appendingPathComponent("clean.lock").path, 0o600), 0)
        assertLockRefusal(fifo, box, "lock file is a FIFO")
        // 4. The lock file has a second hard link.
        let hard = outside.appendingPathComponent("lock-hard")
        try FileManager.default.createDirectory(at: hard, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: hard.appendingPathComponent("clean.lock"))
        XCTAssertEqual(link(hard.appendingPathComponent("clean.lock").path, hard.appendingPathComponent("second-name").path), 0)
        assertLockRefusal(hard, box, "lock file has two names")
    }

    func testTheLockRefusesAFileThatIsNotAPlainFileWithOneName() throws {
        let holder = try Sandbox()
        let outside = holder.home.deletingLastPathComponent()
        let fifo = outside.appendingPathComponent("l-fifo")
        try FileManager.default.createDirectory(at: fifo, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(fifo.appendingPathComponent("clean.lock").path, 0o600), 0)
        XCTAssertEqual(CLILock.acquire(in: fifo).failureValue.map { if case .cannotOpen = $0 { return true } else { return false } }, true)
        let hard = outside.appendingPathComponent("l-hard")
        try FileManager.default.createDirectory(at: hard, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: hard.appendingPathComponent("clean.lock"))
        XCTAssertEqual(link(hard.appendingPathComponent("clean.lock").path, hard.appendingPathComponent("other").path), 0)
        XCTAssertEqual(CLILock.acquire(in: hard).failureValue.map { if case .cannotOpen = $0 { return true } else { return false } }, true)
        // A plain file with one name still works.
        let ok = outside.appendingPathComponent("l-ok")
        XCTAssertNoThrow(try CLILock.acquire(in: ok).get().release())
    }

    // MARK: The home folder

    func testAHomeThatIsNotAbsoluteIsRefusedAndNothingIsScanned() throws {
        let box = try makeHome()
        let before = snapshot(box.home)
        let cases: [(String?, String?, String)] = [(".", box.home.path, box.home.path), (box.home.path, "relative", box.home.path),
                                                   ("", box.home.path, box.home.path), (box.home.path, box.home.path, "relative")]
        for (cffixed, home, resolved) in cases {
            var logs: [String] = []
            var built = 0
            var env = environment(box)
            env.homeValues = { (cffixed, home, resolved) }
            let result = CLICommand.run(arguments: ["t", "--clean-safe", "--yes"], scanner: { built += 1; return self.scanner(box) }(),
                                        runningApps: RunningApps { RunningSnapshot(apps: []) }, clean: env, log: { _, t in logs.append(t) })
            XCTAssertEqual(result?.exitCode, 1, "\(cffixed ?? "nil") \(home ?? "nil") \(resolved)")
            XCTAssertTrue(result?.stderr.contains("not an absolute path") == true)
            XCTAssertEqual(built, 0, "nothing is scanned")
            XCTAssertFalse(logs.contains { $0.hasPrefix("cli plan") })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockFolder(box).path))
        XCTAssertEqual(snapshot(box.home), before)
        // Not set at all is fine (the system gives the home).
        var ok = environment(box)
        ok.homeValues = { (nil, nil, box.home.path) }
        XCTAssertEqual(CLICommand.run(arguments: ["t", "--clean-safe", "--yes"], scanner: scanner(box),
                                      runningApps: RunningApps { RunningSnapshot(apps: []) }, clean: ok, log: { _, _ in })?.exitCode, 0)
    }

    // MARK: The running apps are read fresh

    func testTheRunningAppsAreRefreshedRightBeforeEachRead() throws {
        let box = try makeHome()
        // An item with an owner app: the Cleaner reads the running apps again for it.
        try box.file("Library/Developer/Xcode/DerivedData/Demo-abc/Build/a.bin", bytes: mb)
        final class Order: @unchecked Sendable {
            let lock = NSLock(); var events: [String] = []
            func add(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
        }
        let order = Order()
        let r = run(["--clean-safe", "--yes", "--json"], box, apps: { order.add("take"); return RunningSnapshot(apps: []) },
                    refresh: { order.add("refresh") })
        XCTAssertEqual(r.result?.exitCode, 0)
        let events = order.events
        XCTAssertGreaterThanOrEqual(events.filter { $0 == "take" }.count, 2, "the plan, and at least one item with an owner app: \(events)")
        XCTAssertEqual(events.count % 2, 0)
        for pair in stride(from: 0, to: events.count, by: 2) {
            XCTAssertEqual(Array(events[pair...pair + 1]), ["refresh", "take"], "each read is right after a refresh: \(events)")
        }
    }

    // MARK: Signals: exact text, counted as skipped

    func testASignalDuringAnItemIsReportedAsStoppedBySignalNeverAsTheMenuText() throws {
        let box = try makeHome()
        let stop = CLIStop()
        var count = 0
        let r = run(["--clean-safe", "--yes", "--json"], box, stop: stop) { _ in
            count += 1
            if count == 1 { stop.request(signal: SIGINT) }   // the signal arrives while the first item is already in the Cleaner
        }
        XCTAssertEqual(r.result?.exitCode, 130)
        let report = try decodeClean(r)
        XCTAssertTrue(report.stopped)
        XCTAssertEqual(r.sentToCleaner.count, 1, "the item that runs finishes, and no other starts")
        XCTAssertEqual(report.totals.cleaned, 1)
        let planned = try dryRunReport(try makeHome()).findings.filter(\.wouldClean).count
        let stopped = report.findings.filter { $0.wouldClean && $0.result == "skipped" }
        XCTAssertEqual(stopped.count, planned - 1)
        for e in stopped { XCTAssertEqual(e.skipReason, "stopped by signal", e.base.id) }
        XCTAssertFalse(report.findings.contains { $0.skipReason.contains("Stopped by you") })
        XCTAssertEqual(report.totals.skipped, report.findings.filter { $0.result == "skipped" }.count)
        XCTAssertTrue(r.logs.contains { $0.contains("stopped by signal") })
    }

    func testASignalAtTheVeryEndStillGivesExit143AndSaysSo() throws {
        let box = try makeHome()
        let stop = CLIStop()
        let planned = try dryRunReport(try makeHome()).findings.filter(\.wouldClean).count
        var count = 0
        let r = run(["--clean-safe", "--yes", "--json"], box, stop: stop) { _ in
            count += 1
            if count == planned { stop.request(signal: SIGTERM) }   // during the last item
        }
        XCTAssertEqual(r.sentToCleaner.count, planned, "every item was already started")
        XCTAssertEqual(r.result?.exitCode, 143)
        let report = try decodeClean(r)
        XCTAssertTrue(report.stopped)
        XCTAssertEqual(report.totals.cleaned, planned)
        XCTAssertTrue(r.logs.contains { $0.contains("stopped by signal SIGTERM") }, "\(r.logs)")
        let again = try makeHome()
        let stop2 = CLIStop()
        var n = 0
        let text = try XCTUnwrap(run(["--clean-safe", "--yes"], again, stop: stop2) { _ in
            n += 1
            if n == planned { stop2.request(signal: SIGTERM) }
        }.result?.stdout)
        XCTAssertTrue(text.contains("A signal arrived at the end of the run. Every item was already finished."), text)
        XCTAssertFalse(text.contains("partial"), text)
    }

    func testASignalDuringTheScanStopsBeforeTheFirstItem() throws {
        let box = try makeHome()
        let stop = CLIStop()
        // The signal comes while the plan is made: the first read of the running apps is part of the plan.
        let r = run(["--clean-safe", "--yes", "--json"], box, stop: stop, apps: { stop.request(signal: SIGINT); return RunningSnapshot(apps: []) })
        XCTAssertEqual(r.result?.exitCode, 130)
        XCTAssertTrue(r.sentToCleaner.isEmpty)
        XCTAssertTrue(r.logs.contains { $0.contains("stopped by signal SIGINT") })
    }

    // MARK: The log

    func testTheBeginLineComesBeforeTheScanAndEverySkippedItemIsLogged() throws {
        let box = try makeHome()
        var logs: [String] = []
        var scanSeenAt: Int?
        let env = environment(box)
        // The scanner is built when the autoclosure runs. The scan itself starts later, so the begin line must already be there.
        let sc = DiskScanner(home: box.home, config: Config(keep: [box.home.path + "/Library/Caches/node-gyp"], deleteMode: .permanent),
                             useOwnerTools: false, programPaths: { [] }, openClaudeBinaries: { _ in [] }, appName: { _ in nil },
                             activeDirectories: { scanSeenAt = logs.count; return [] })
        let result = CLICommand.run(arguments: ["t", "--clean-safe", "--yes"], scanner: sc, runningApps: RunningApps { RunningSnapshot(apps: []) },
                                    clean: env, log: { _, t in logs.append(t) })
        XCTAssertEqual(result?.exitCode, 0)
        let begin = try XCTUnwrap(logs.first { $0.hasPrefix("cli begin version=") })
        XCTAssertTrue(begin.contains("options=--clean-safe --yes other=0"), begin)
        XCTAssertTrue(begin.contains("deleteMode=permanent"), begin)
        if let seen = scanSeenAt { XCTAssertLessThanOrEqual(logs.firstIndex(of: begin) ?? 99, seen) }
        XCTAssertLessThan(try XCTUnwrap(logs.firstIndex(of: begin)), try XCTUnwrap(logs.firstIndex { $0.hasPrefix("cli plan") }))
        let skippedInPlan = try dryRunReport(try makeHome()).findings.filter { !$0.wouldClean }
        let skipLines = logs.filter { $0.hasPrefix("clean plan-skip id=") }
        XCTAssertEqual(skipLines.count, skippedInPlan.count)
        XCTAssertTrue(skipLines.allSatisfy { $0.contains("reason=\"") })
    }

    // MARK: Follow-ups of #252

    /// A scanner on any folder, also one that does not exist.
    private func scanner(at home: URL) -> DiskScanner {
        DiskScanner(home: home, config: Config(keep: [], deleteMode: .permanent), useOwnerTools: false, programPaths: { [] },
                    openClaudeBinaries: { _ in [] }, appName: { _ in nil }, activeDirectories: { [] })
    }

    private func command(_ args: [String], home: URL, values: (String?, String?, String),
                         box: Sandbox, canLog: Bool = true, log: @escaping (CLILogLevel, String) -> Void) -> (CLIResult?, Int) {
        var built = 0
        var env = environment(box)
        env.homeValues = { values }
        env.canLog = { canLog }
        let result = CLICommand.run(arguments: ["t"] + args, scanner: { built += 1; return self.scanner(at: home) }(),
                                    runningApps: RunningApps { RunningSnapshot(apps: []) }, clean: env, log: log)
        return (result, built)
    }

    /// F1. The REAL log is pointed at a file below the missing home. A log line would make the missing home folder.
    /// An injected log closure cannot show this, so the test uses `Log` itself.
    func testAMissingHomeIsNeverMadeByTheRealLogAndGivesExit1() throws {
        let box = try makeHome()
        let missing = box.home.deletingLastPathComponent().appendingPathComponent("missing-home")
        let saved = Log.fileURL
        Log.fileURL = missing.appendingPathComponent("Library/Logs/TrashPanda/trashpanda.log")
        defer { Log.fileURL = saved }
        for args in [["--clean-safe", "--yes"], ["--clean-safe", "--yes", "--json"]] {
            let (result, _) = command(args, home: missing, values: (missing.path, missing.path, missing.path), box: box) { level, text in
                switch level { case .info: Log.info(text); case .warn: Log.warn(text) }
            }
            Log.flush()
            XCTAssertEqual(result?.exitCode, 1)
            XCTAssertEqual(result?.stdout, "")
            XCTAssertTrue(result?.stderr.contains("home folder could not be found") == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "the missing home folder must NOT be made")
            XCTAssertFalse(FileManager.default.fileExists(atPath: lockFolder(box).path), "no lock is made")
        }
    }

    func testAMissingHomeGivesNoLogLineAndNoScan() throws {
        let box = try makeHome()
        let missing = box.home.appendingPathComponent("nope")
        var logs: [String] = []
        let (result, _) = command(["--clean-safe", "--yes"], home: missing, values: (nil, nil, missing.path), box: box) { _, t in logs.append(t) }
        XCTAssertEqual(result?.exitCode, 1)
        XCTAssertEqual(logs, [], "a log line would make the missing folders")
    }

    /// F2. The values are text only. The system home is never asked when a value is bad (that call can recurse without end).
    func testAHomeValueWithATildeOrEmptyIsRefusedBeforeAnythingElse() throws {
        let box = try makeHome()
        let before = snapshot(box.home)
        let bad: [(String?, String?, String)] = [("~", box.home.path, box.home.path), (box.home.path, "~", box.home.path), ("~/x", nil, ""),
                                                 ("~user", nil, ""), ("", nil, ""), (nil, "", ""), (nil, nil, "~"), (nil, nil, "")]
        for values in bad {
            for args in [["--clean-safe", "--yes"], ["--clean-safe", "--dry-run"], ["--scan"]] {
                var logs: [String] = []
                let (result, built) = command(args, home: box.home, values: values, box: box) { _, t in logs.append(t) }
                XCTAssertEqual(result?.exitCode, 1, "\(values) \(args)")
                XCTAssertEqual(result?.stdout, "")
                XCTAssertTrue(result?.stderr.contains("not an absolute path") == true)
                XCTAssertEqual(built, 0, "\(values) \(args): no scanner")
                XCTAssertFalse(logs.contains { $0.hasPrefix("cli plan") || $0.hasPrefix("cli lock") })
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockFolder(box).path))
        XCTAssertEqual(snapshot(box.home), before)
    }

    func testLogDoesNotAskTheSystemForAHomeThatIsNotPlain() {
        var asked = 0
        let normal: () -> URL = { asked += 1; return URL(fileURLWithPath: "/never") }
        for value in ["~", "~/x", "~root", "", ".", "sub", ".."] {
            let url = Log.realHome(cffixed: value, home: "/Users/example", passwd: { "/Users/example" }, normal: normal)
            XCTAssertEqual(url.path, "/Users/example", value)
            let other = Log.realHome(cffixed: nil, home: value, passwd: { "/Users/example" }, normal: normal)
            XCTAssertEqual(other.path, "/Users/example", value)
        }
        XCTAssertEqual(asked, 0, "the system call that recurses is never made for a bad value")
        // A bad value and no usable passwd home: a fixed folder, never a relative one.
        XCTAssertEqual(Log.realHome(cffixed: "~", home: nil, passwd: { nil }, normal: normal).path, "/var/empty")
        XCTAssertEqual(Log.realHome(cffixed: "~", home: nil, passwd: { "relative" }, normal: normal).path, "/var/empty")
        // Plain values use the usual way.
        XCTAssertEqual(Log.realHome(cffixed: "/Users/example", home: nil, passwd: { "/x" }, normal: normal).path, "/never")
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(Log.isPlainAbsolute("/Users/example"))
        for value in ["~", "", ".", "x", "~/a", "/a\u{0}b"] { XCTAssertFalse(Log.isPlainAbsolute(value), value) }
    }

    /// F3. No log line is written when the log file is not in an absolute place.
    func testARefusedHomeIsLoggedOnlyWhenTheLogFileIsAbsolute() throws {
        let box = try makeHome()
        for canLog in [false, true] {
            var logs: [String] = []
            let (result, _) = command(["--clean-safe", "--yes"], home: box.home, values: (".", nil, box.home.path), box: box, canLog: canLog) { _, t in logs.append(t) }
            XCTAssertEqual(result?.exitCode, 1)
            if canLog {
                XCTAssertTrue(logs.contains { $0.contains("home folder is not a plain absolute path, exit 1") }, "\(logs)")
            } else {
                XCTAssertEqual(logs, [], "no log line is written under a relative path")
            }
            var scanLogs: [String] = []
            _ = command(["--scan"], home: box.home, values: ("sub", nil, box.home.path), box: box, canLog: canLog) { _, t in scanLogs.append(t) }
            XCTAssertEqual(scanLogs.isEmpty, !canLog)
        }
        // The real default says no when the log file is relative.
        let saved = Log.fileURL
        defer { Log.fileURL = saved }
        Log.fileURL = URL(fileURLWithPath: "/tmp/x/trashpanda.log")
        XCTAssertTrue(CLICleanEnvironment().canLog())
        Log.fileURL = URL(string: "relative/trashpanda.log") ?? saved
        XCTAssertEqual(CLICleanEnvironment().canLog(), Log.isPlainAbsolute(Log.fileURL.path))
    }

    /// F4. A value of an argument is never printed.
    func testNoArgumentValueIsRepeatedOnStderr() throws {
        let box = try makeHome()
        let long = String(repeating: "A", count: 5000)
        let secret = "hunter2SECRET"
        let sets: [[String]] = [["--clean-safe", "--yes", "-psn_\(secret)"], ["--clean-safe", "--yes", "--password=\(secret)"],
                                ["--clean-safe", "--dry-run", "--password=\(secret)"], ["--scan", "--token=\(secret)"],
                                ["--clean-safe", "--yes", long], ["--clean-safe", "--yes", "--" + long], ["--nope=\(secret)"],
                                ["-psn_\(secret)", "--clean-safe", "--dry-run"], ["--clean-safe", "--yes", "-x\(secret)"]]
        for args in sets {
            let r = run(args, box)
            let err = try XCTUnwrap(r.result?.stderr, "\(args)")
            XCTAssertEqual(r.result?.exitCode, 64, "\(args)")
            XCTAssertFalse(err.contains(secret), "\(args): \(err)")
            XCTAssertFalse(err.contains("AAAA"), "\(args)")
            XCTAssertFalse(r.logs.joined().contains(secret), "\(args)")
            XCTAssertLessThan(err.count, 2000, "\(args)")
        }
        XCTAssertTrue(try XCTUnwrap(run(["--nope"], box).result?.stderr).hasPrefix("Unknown option\n"))
        XCTAssertTrue(try XCTUnwrap(run(["--clean-safe", "--yes", "--scan"], box).result?.stderr).hasPrefix("--yes cannot be used with --scan\n"))
        XCTAssertTrue(try XCTUnwrap(run(["--clean-safe", "--yes", "-psn_1"], box).result?.stderr)
            .hasPrefix("--clean-safe --yes cannot be used with other arguments\n"))
    }

    /// F5. An old lock file with a wide mode is fixed to 0600.
    func testAnExistingLockFileWithAWideModeIsFixedTo0600() throws {
        let box = try Sandbox()
        let folder = box.home.deletingLastPathComponent().appendingPathComponent("lock-mode")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("clean.lock")
        try Data().write(to: file)
        for mode in [0o644, 0o666, 0o640, 0o755] {
            XCTAssertEqual(chmod(file.path, mode_t(mode)), 0)
            let lock = try CLILock.acquire(in: folder).get()
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "from \(String(mode, radix: 8))")
            lock.release()
        }
        // A file that we cannot open for writing (mode 0400) is refused, and its mode is not changed.
        XCTAssertEqual(chmod(file.path, 0o400), 0)
        XCTAssertNotNil(CLILock.acquire(in: folder).failureValue)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        // A link in place of the file is still refused, and the file behind it keeps its mode.
        let target = try box.file("victim.txt", bytes: 5)
        XCTAssertEqual(chmod(target.path, 0o644), 0)
        let linked = box.home.deletingLastPathComponent().appendingPathComponent("lock-mode-link")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("clean.lock"), withDestinationURL: target)
        XCTAssertNotNil(CLILock.acquire(in: linked).failureValue)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    /// F6. The home is replaced only at the start of a path.
    func testRedactReplacesTheHomeOnlyAtTheStartOfAPath() {
        XCTAssertEqual(Log.redact("/private/tmp/x/a", home: "/tmp/x"), "/private/tmp/x/a")
        XCTAssertEqual(Log.redact("/tmp/xyz/a", home: "/tmp/x"), "/tmp/xyz/a")
        XCTAssertEqual(Log.redact("/tmp/x.bak", home: "/tmp/x"), "/tmp/x.bak")
        XCTAssertEqual(Log.redact("/tmp/x/Library/a", home: "/tmp/x"), "~/Library/a")
        XCTAssertEqual(Log.redact("/tmp/x", home: "/tmp/x"), "~")
        XCTAssertEqual(Log.redact("id=/tmp/x/a and \"/tmp/x/b\" (/tmp/x). /tmp/x.", home: "/tmp/x"), "id=~/a and \"~/b\" (~). ~.")
        XCTAssertEqual(Log.redact("a /tmp/x/a /private/tmp/x/b /tmp/x/c", home: "/tmp/x"), "a ~/a /private/tmp/x/b ~/c")
        XCTAssertEqual(Log.redact("/Users/example/Library/x", home: "/Users/example/"), "~/Library/x")
        XCTAssertEqual(Log.redact("/Users/exampleuser/x", home: "/Users/example"), "/Users/exampleuser/x")
        XCTAssertEqual(Log.redact("nothing", home: "/"), "nothing")
        XCTAssertEqual(Log.redact("nothing", home: ""), "nothing")
    }

    /// F7. A signal during the last item: the log does not say that items are left.
    func testTheSignalLogLineIsRightWhenTheSignalComesDuringTheLastItem() throws {
        let box = try makeHome()
        let planned = try dryRunReport(try makeHome()).findings.filter(\.wouldClean).count
        let stopLast = CLIStop()
        var count = 0
        let last = run(["--clean-safe", "--yes"], box, stop: stopLast) { _ in count += 1; if count == planned { stopLast.request(signal: SIGTERM) } }
        let line = try XCTUnwrap(last.logs.first { $0.hasPrefix("cli stopped by signal") }, "\(last.logs)")
        XCTAssertEqual(last.logs.filter { $0.hasPrefix("cli stopped by signal") }.count, 1)
        XCTAssertTrue(line.contains("SIGTERM"), line)
        XCTAssertFalse(line.contains("left"), line)
        XCTAssertTrue(line.contains("every item was already finished"), line)
        // A signal in the middle: items are left, and the line says so.
        let stopFirst = CLIStop()
        var n = 0
        let first = run(["--clean-safe", "--yes"], try makeHome(), stop: stopFirst) { _ in n += 1; if n == 1 { stopFirst.request(signal: SIGTERM) } }
        let mid = try XCTUnwrap(first.logs.first { $0.hasPrefix("cli stopped by signal") })
        XCTAssertTrue(mid.contains("the items that are left are not cleaned"), mid)
        XCTAssertEqual(first.logs.filter { $0.hasPrefix("cli stopped by signal") }.count, 1)
    }

    /// F9. SIGQUIT is a stop like SIGTERM (131). SIGHUP is ignored.
    func testSIGQUITStopsLikeSIGTERMWithExit131AndSIGHUPIsIgnored() throws {
        let stop = CLIStop()
        XCTAssertEqual(stop.signalName, "signal 0")
        stop.request(signal: SIGQUIT)
        XCTAssertEqual(stop.exitCode, 131)
        XCTAssertEqual(stop.signalName, "SIGQUIT")
        XCTAssertEqual(CLISignals.stopSignals, [SIGINT, SIGTERM, SIGQUIT])
        XCTAssertEqual(CLISignals.ignoredSignals, [SIGHUP])
        let box = try makeHome()
        let before = snapshot(box.home)
        let quit = CLIStop()
        quit.request(signal: SIGQUIT)
        let r = run(["--clean-safe", "--yes", "--json"], box, stop: quit)
        XCTAssertEqual(r.result?.exitCode, 131)
        XCTAssertTrue(r.sentToCleaner.isEmpty)
        XCTAssertEqual(snapshot(box.home), before)
        XCTAssertTrue(try decodeClean(r).stopped)
        XCTAssertTrue(r.logs.contains { $0.contains("stopped by signal SIGQUIT") })
        // A stop in the middle: the item that runs finishes.
        let mid = CLIStop()
        var count = 0
        let m = run(["--clean-safe", "--yes", "--json"], try makeHome(), stop: mid) { _ in count += 1; if count == 1 { mid.request(signal: SIGQUIT) } }
        XCTAssertEqual(m.result?.exitCode, 131)
        XCTAssertEqual(m.sentToCleaner.count, 1)
        XCTAssertFalse(CLISignals.stopSignals.contains(SIGHUP))
    }

    private func editorFinding(_ box: Sandbox) throws -> Finding {
        let file = try box.file("Library/Caches/Editor/a.bin", bytes: 100_000)
        return Finding(id: "editor", ecosystem: .python, title: "Editor cache", location: "~/Library/Caches/Editor", bytes: 100_000, tier: .safe,
                       rebuild: .seconds, action: .removeContents(file.deletingLastPathComponent()), owner: CleanPlanTests.editor)
    }

    /// F10. The list of programs could not be read: an item with an owner app is skipped, other items are cleaned.
    func testAnItemWithAnOwnerAppIsSkippedWhenTheProgramListCannotBeRead() throws {
        let box = try makeHome()
        let editor = try editorFinding(box)
        let file = box.home.appendingPathComponent("Library/Caches/Editor/a.bin")
        let unreadable: @Sendable () -> RunningSnapshot = { RunningSnapshot(apps: [], processes: [], processListRead: false) }
        let dry = run(["--clean-safe", "--dry-run", "--json"], box, apps: unreadable, extra: [editor])
        let planned = try JSONDecoder().decode(DryRunReport.self, from: Data(try XCTUnwrap(dry.result?.stdout).utf8))
        let entry = try XCTUnwrap(planned.findings.first { $0.base.id == "editor" })
        XCTAssertFalse(entry.wouldClean)
        XCTAssertEqual(entry.skipReason, CleanPlan.processListUnreadReason)
        let r = run(["--clean-safe", "--yes", "--json"], box, apps: unreadable, extra: [editor])
        XCTAssertEqual(r.result?.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the owner item stays")
        XCTAssertFalse(r.sentToCleaner.contains("editor"))
        let report = try decodeClean(r)
        XCTAssertEqual(report.findings.first { $0.base.id == "editor" }?.skipReason, CleanPlan.processListUnreadReason)
        XCTAssertGreaterThan(report.totals.cleaned, 0, "items without an owner app are still cleaned")
        // The list is read: the same item is cleaned.
        let box2 = try makeHome()
        let editor2 = try editorFinding(box2)
        XCTAssertTrue(run(["--clean-safe", "--yes"], box2, extra: [editor2]).sentToCleaner.contains("editor"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: box2.home.appendingPathComponent("Library/Caches/Editor/a.bin").path))
    }

    /// F10, at the Cleaner: a forged plan says wouldClean, and the Cleaner still skips. The menu (default) is not changed.
    func testTheCleanerSkipsAnOwnerItemWhenTheProgramListCannotBeReadAndOnlyForTheCommandLine() throws {
        let box = try Sandbox()
        let editor = try editorFinding(box)
        let file = box.home.appendingPathComponent("Library/Caches/Editor/a.bin")
        let (plan, result) = forgedPlan([editor])
        let cleaner = makeCleaner(box, spy: Spy(), apps: { RunningSnapshot(apps: [], processListRead: false) })
        cleaner.requireProgramList = true
        let done = runPlan(plan, result, cleaner: cleaner, box: box)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(done.outcome(0).result, .skipped)
        XCTAssertTrue(done.outcome(0).skipReason.contains(CleanPlan.processListUnreadReason), done.outcome(0).skipReason)
        XCTAssertEqual(done.failed, 0)
        // The menu does not set the flag: it works as before.
        let menu = makeCleaner(box, spy: Spy(), apps: { RunningSnapshot(apps: [], processListRead: false) })
        XCTAssertFalse(menu.requireProgramList)
        XCTAssertEqual(runPlan(plan, result, cleaner: menu, box: box).outcome(0).result, .cleaned)
    }

    /// The home that is a link: stop at the start with a clear message. A plain fixture home still works (all other tests).
    func testAHomeThatIsALinkIsRefusedAtTheStart() throws {
        let box = try makeHome()
        let before = snapshot(box.home)
        let link = box.home.deletingLastPathComponent().appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: box.home)
        var logs: [String] = []
        let (result, _) = command(["--clean-safe", "--yes"], home: link, values: (link.path, link.path, link.path), box: box) { _, t in logs.append(t) }
        XCTAssertEqual(result?.exitCode, 1)
        XCTAssertEqual(result?.stdout, "")
        XCTAssertTrue(result?.stderr.contains("home folder is a link") == true, result?.stderr ?? "")
        XCTAssertFalse(logs.contains { $0.hasPrefix("cli plan") || $0.hasPrefix("cli lock") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockFolder(box).path))
        XCTAssertEqual(snapshot(box.home), before)
        // A link in the path of the home is refused too.
        let parentLink = box.home.deletingLastPathComponent().appendingPathComponent("parent-link")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: box.home.deletingLastPathComponent())
        let deep = parentLink.appendingPathComponent("home")
        let (second, _) = command(["--clean-safe", "--yes"], home: deep, values: (nil, nil, deep.path), box: box) { _, _ in }
        XCTAssertEqual(second?.exitCode, 1)
        XCTAssertTrue(second?.stderr.contains("home folder is a link") == true)
        XCTAssertEqual(snapshot(box.home), before)
    }

    // MARK: Source

    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(relative), encoding: .utf8)
    }

    func testTheCleanFileHasNoDeleteWordAndNoToolRunner() throws {
        let text = try source("Sources/PandaCore/CLIClean.swift")
        XCTAssertEqual(CLICommandTests.dangerHits(text, words: CLICommandTests.dangers), [], "CLIClean.swift has no delete, move, or start word")
        XCTAssertEqual(CLICommandTests.rawHits(ShellHardeningTests.codeOnly(text, keepStrings: true)), [])
        let code = ShellHardeningTests.codeOnly(text)
        for word in ["removeContents", "removeArtifact", "removeItem", "trashItem", "deleteItem", "dispose(", "Shell.", "Process"] {
            XCTAssertFalse(code.contains(word), "CLIClean.swift must not contain \(word)")
        }
        XCTAssertTrue(code.contains("cleaner.clean("), "it gives each finding to the real Cleaner")
    }

    func testOnlyTheCleanFileTakesALockAndHandlesSignals() throws {
        let dir = root().appendingPathComponent("Sources")
        var lockFiles: Set<String> = [], signalFiles: Set<String> = [], geteuidFiles: Set<String> = []
        for file in try FileManager.default.subpathsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
            let code = ShellHardeningTests.codeOnly(try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8))
            let name = (file as NSString).lastPathComponent
            if code.range(of: #"\bflock\s*\("#, options: .regularExpression) != nil { lockFiles.insert(name) }
            if code.range(of: #"\bmakeSignalSource\s*\(|\bsignal\s*\(\s*SIG"#, options: .regularExpression) != nil { signalFiles.insert(name) }
            if code.range(of: #"\bgeteuid\s*\("#, options: .regularExpression) != nil { geteuidFiles.insert(name) }
        }
        XCTAssertEqual(lockFiles, ["CLIClean.swift"], "flock: one exclusive, non-blocking lock for the real clean")
        XCTAssertEqual(signalFiles, ["CLIClean.swift"], "signals: SIGINT and SIGTERM set a stop flag that is read between two items")
        XCTAssertEqual(geteuidFiles, ["CLIClean.swift"], "the root check of the real clean")
        let clean = ShellHardeningTests.codeOnly(try source("Sources/PandaCore/CLIClean.swift"))
        XCTAssertTrue(clean.contains("LOCK_EX | LOCK_NB"), "never waits for the lock")
        // No exit call in the command code. Every exit is in main.swift, after Log.flush().
        for file in ["Sources/PandaCore/CLIClean.swift", "Sources/PandaCore/CLICommand.swift"] {
            XCTAssertNil(ShellHardeningTests.codeOnly(try source(file)).range(of: #"\bexit\s*\("#, options: .regularExpression), file)
        }
        let main = ShellHardeningTests.codeOnly(try source("Sources/TrashPanda/main.swift"))
        XCTAssertTrue(main.contains("CLISignals.install("))
    }

    func testTheReadOnlyFilesDoNotNameTheLockTheCleanerOrTheSignals() throws {
        for file in ["CLICommand", "CleanPlan", "CleanRules", "ScanReport"] {
            let code = ShellHardeningTests.codeOnly(try source("Sources/PandaCore/\(file).swift"))
            for word in ["Cleaner", "CLILock", "flock", "makeSignalSource", "geteuid", "useTrashMove", "CleanOutcome"] {
                XCTAssertFalse(code.contains(word), "\(file).swift must not contain \(word)")
            }
        }
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
