import XCTest
@testable import PandaCore

final class CleanPlanTests: XCTestCase {
    static let home = "/Users/example"
    static let editor = AppOwner(name: "Example Editor", bundleIDs: ["com.example.editor"])

    static func folder(_ name: String, home: String = home) -> URL {
        URL(fileURLWithPath: home + "/Library/Caches/" + name)
    }

    /// A scan with fixed values. It has a safe item, a review item, a blocked item, an info item, a kept item,
    /// an item whose owner app is open, and an upper-limit item. It never reads the real disk.
    static func fixture(home: String = home) -> ScanResult {
        let findings = [
            Finding(id: "example.cache", ecosystem: .swift, title: "Example build cache", location: "~/Library/Caches/Example",
                    bytes: 5_300_000_000, tier: .safe, rebuild: .minutes, action: .removeContents(folder("Example", home: home))),
            Finding(id: "example.models", ecosystem: .aiAgents, title: "Example models", location: "~/.example/models",
                    bytes: 12_000_000_000, tier: .review, rebuild: .download, action: .removeContents(folder("Models", home: home))),
            Finding(id: "example.blocked", ecosystem: .worktrees, title: "Example blocked", location: "~/code/busy",
                    bytes: 40_000_000, tier: .safe, rebuild: .recreate, action: .removeContents(folder("Blocked", home: home)),
                    blockedReason: "Has changes that are not committed"),
            Finding(id: "example.info", ecosystem: .homebrew, title: "Example note", location: "~/Library/Example",
                    bytes: 1_500_000, tier: .safe, rebuild: .never, action: .inform),
            Finding(id: "example.kept", ecosystem: .javascript, title: "Example kept cache", location: "~/Library/Caches/Kept",
                    bytes: 90_000_000, tier: .safe, rebuild: .seconds, action: .removeContents(folder("Kept", home: home))),
            Finding(id: "example.open", ecosystem: .apps, title: "Example editor cache", location: "~/Library/Caches/Editor",
                    bytes: 250_000_000, tier: .safe, rebuild: .seconds, action: .removeContents(folder("Editor", home: home)),
                    owner: editor),
            Finding(id: "example.upper", ecosystem: .docker, title: "Example upper limit", location: "Docker",
                    bytes: 700_000_000, tier: .safe, rebuild: .seconds, action: .removeContents(folder("Upper", home: home)),
                    sizeIsUpperLimit: true),
        ]
        return ScanResult(findings: findings, disk: DiskUsage(total: 500_000_000_000, free: 42_000_000_000),
                          date: Date(timeIntervalSince1970: 0))
    }

    static let editorOpen = RunningSnapshot(apps: [RunningApp(bundleID: "com.example.editor", name: "Example Editor")])

    static func plan(_ result: ScanResult = fixture(), home: String = home, keep: [String]? = nil,
                     running: RunningSnapshot = editorOpen, mode: DeleteMode = .permanent) -> CleanPlan {
        let guardian = PathGuard(home: URL(fileURLWithPath: home), keep: keep ?? [home + "/Library/Caches/Kept"])
        return CleanPlan(result, guardian: guardian, running: running, deleteMode: mode)
    }

    private func golden(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/cleanplan"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func reason(_ plan: CleanPlan, _ id: String) -> String? { plan.items.first { $0.finding.id == id }?.skipReason }

    // MARK: Decisions and output

    func testEachItemGetsItsReason() {
        let plan = Self.plan()
        XCTAssertEqual(plan.items.map(\.wouldClean), [true, false, false, false, false, false, true])
        XCTAssertEqual(plan.items.map(\.skipReason), ["", "review item", "blocked: Has changes that are not committed", "info only",
                                                      "on the keep list", "owner app is open: Example Editor", ""])
        XCTAssertEqual(plan.wouldClean.map(\.finding.id), ["example.cache", "example.upper"])
        // The upper-limit item counts 0, as in the app.
        XCTAssertEqual(plan.wouldFree, 5_300_000_000)
        XCTAssertEqual(plan.wouldFree, plan.wouldClean.reduce(0) { $0 + $1.finding.countedBytes })
    }

    func testClosedOwnerAppIsNotASkip() {
        let plan = Self.plan(running: RunningSnapshot(apps: []))
        XCTAssertEqual(plan.items[5].skipReason, "")
        XCTAssertTrue(plan.items[5].wouldClean)
    }

    func testJSONEqualsGolden() throws {
        let report = DryRunReport(Self.fixture(), plan: Self.plan(), home: Self.home)
        let json = report.json()
        XCTAssertEqual(json, try golden("dry-run.json"))
        XCTAssertEqual(json.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(json.contains("\"mode\":\"dry-run\""))
        XCTAssertTrue(json.contains("\"wouldFree\":5300000000"))
        let decoded = try JSONDecoder().decode(DryRunReport.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.schema, 1)
    }

    func testStep1FieldsAreStillThereAndUnchanged() throws {
        let scan = ScanReport(Self.fixture(), home: Self.home)
        let dry = DryRunReport(Self.fixture(), plan: Self.plan(), home: Self.home)
        XCTAssertEqual(dry.findings.map(\.base), scan.findings)
        XCTAssertEqual(dry.disk, scan.disk)
        XCTAssertEqual(dry.totals.reclaimable, scan.totals.reclaimable)
        XCTAssertEqual(dry.totals.reviewable, scan.totals.reviewable)
        // Each finding object has all the keys of step 1, and two more.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(dry.json().utf8)) as? [String: Any])
        let first = try XCTUnwrap((object["findings"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["id", "group", "title", "bytes", "tier", "rebuild", "location", "blocked", "blockedReason",
                                         "upperLimit", "countedBytes", "wouldClean", "skipReason"])
        XCTAssertEqual(Set((object["totals"] as? [String: Any] ?? [:]).keys), ["reclaimable", "reviewable", "wouldFree"])
    }

    func testTextEqualsGolden() throws {
        XCTAssertEqual(Self.plan().text(verbose: false), try golden("dry-run.txt"))
        XCTAssertEqual(Self.plan().text(verbose: true), try golden("dry-run-verbose.txt"))
    }

    func testTextForNothingAndForTrashMode() {
        let none = Self.plan(ScanResult(findings: [], disk: DiskUsage(total: 1, free: 1)))
        XCTAssertEqual(none.text(verbose: false), "0 items would be cleaned. Would free 0 KB\nNothing was deleted.\n")
        XCTAssertTrue(Self.plan(mode: .trash).text(verbose: false).contains("Delete mode is trash"))
        XCTAssertFalse(Self.plan().text(verbose: false).contains("Delete mode is trash"))
        XCTAssertTrue(DryRunReport(Self.fixture(), plan: Self.plan(mode: .trash), home: Self.home).json().contains("\"deleteMode\":\"trash\""))
    }

    // MARK: The same rule as the app

    /// The findings that the one-click clean of the menu would take.
    private func appSelection(_ result: ScanResult, running: RunningSnapshot) throws -> [String] {
        let input = MenuInput(result: result, disk: result.disk, scanning: false, cleaning: false, running: running, staleDays: 90)
        let model = MenuModel.make(input)
        for row in model.rows {
            if case .clean(let prompt)? = row.action { return prompt.findings.map(\.id) }
        }
        return []
    }

    func testPlanSelectionEqualsTheOneClickSelectionOfTheApp() throws {
        for running in [Self.editorOpen, RunningSnapshot(apps: [])] {
            let result = Self.fixture()
            let app = try appSelection(result, running: running)
            XCTAssertFalse(app.isEmpty)
            // The app does not know the keep list (the scan drops such items). The plan must differ only by that.
            let plan = Self.plan(result, running: running)
            XCTAssertEqual(plan.wouldClean.map(\.finding.id), app.filter { $0 != "example.kept" })
            // With an empty keep list the two are equal.
            let open = Self.plan(result, keep: [], running: running)
            XCTAssertEqual(open.wouldClean.map(\.finding.id), app)
        }
    }

    // MARK: Safety: the dry run cannot delete

    func testDryRunPathHasNoDelete() throws {
        let main = try String(contentsOf: root().appendingPathComponent("Sources/TrashPanda/main.swift"), encoding: .utf8)
        let begin = try XCTUnwrap(main.range(of: "// BEGIN dry-run"))
        let end = try XCTUnwrap(main.range(of: "// END dry-run"))
        let path = String(main[begin.upperBound..<end.lowerBound])
        XCTAssertTrue(path.contains("CleanPlan("))
        let plan = try String(contentsOf: root().appendingPathComponent("Sources/PandaCore/CleanPlan.swift"), encoding: .utf8)
        for (name, text) in [("dry-run in main.swift", path), ("CleanPlan.swift", plan)] {
            for word in ["Cleaner", "removeItem", "trashItem", "unlink", "Shell.run", "Shell.", "perform", "Process(", "moveItem", "FileManager.default.remove",
                         "createFile", ".write(to", "rmdir", "NSWorkspace.shared.recycle"] {
                XCTAssertFalse(text.contains(word), "\(name) must not contain \(word)")
            }
        }
    }

    private func makeHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tp-plan-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return home.resolvingSymlinksInPath()
    }

    private func put(_ path: URL, _ text: String = "data") throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    /// path -> modification time and size, for each file and folder below `root`.
    private func snapshot(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return out }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            out[url.path] = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1) \(values?.fileSize ?? -1) \(values?.isSymbolicLink ?? false)"
        }
        return out
    }

    func testDryRunLeavesEveryFileAndTimeAsItWas() throws {
        let home = try makeHome()
        let caches = home.appendingPathComponent("Library/Caches")
        for name in ["Example", "Kept", "Models", "Editor"] {
            try put(caches.appendingPathComponent("\(name)/a.bin"))
            try put(caches.appendingPathComponent("\(name)/sub/b.bin"))
        }
        try put(home.appendingPathComponent("Documents/letter.txt"))
        // Old times, so that a touch would show.
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        for case let url as URL in FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)! {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let before = snapshot(home)
        XCTAssertGreaterThan(before.count, 10)

        let findings = ["Example", "Kept", "Models", "Editor"].enumerated().map { index, name in
            Finding(id: "fixture.\(name)", ecosystem: .swift, title: name, location: "~/Library/Caches/\(name)", bytes: 1000,
                    tier: name == "Models" ? .review : .safe, rebuild: .seconds, action: .removeContents(caches.appendingPathComponent(name)),
                    owner: name == "Editor" ? Self.editor : nil)
        }
        let result = ScanResult(findings: findings, disk: DiskUsage(total: 100, free: 50))
        let guardian = PathGuard(home: home, keep: [caches.appendingPathComponent("Kept").path])
        let plan = CleanPlan(result, guardian: guardian, running: Self.editorOpen, deleteMode: .permanent)
        XCTAssertEqual(plan.wouldClean.map(\.finding.id), ["fixture.Example"])
        _ = plan.text(verbose: true)
        _ = plan.summary()
        _ = DryRunReport(result, plan: plan, home: home.path).json()

        XCTAssertEqual(snapshot(home), before, "the dry run must not add, remove, or touch any file")
    }

    func testForgedItemsNeverWouldClean() throws {
        let home = try makeHome()
        let guardian = PathGuard(home: home, keep: [])
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tp-outside-\(UUID().uuidString)")
        try put(outside.appendingPathComponent("x"))
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let h = home.path
        let actions: [(String, Action)] = [
            ("outside", .removeContents(outside)),
            ("etc", .removeContents(URL(fileURLWithPath: "/etc"))),
            ("system", .removeContents(URL(fileURLWithPath: "/System/Library"))),
            ("root", .removeContents(URL(fileURLWithPath: "/"))),
            ("dotdot", .removeContents(URL(fileURLWithPath: h + "/Library/Caches/../../../etc"))),
            ("home", .removeContents(home)),
            ("documents", .removeContents(home.appendingPathComponent("Documents"))),
            ("documents-deep", .removeContents(home.appendingPathComponent("Documents/Project/build"))),
            ("ssh", .removeContents(home.appendingPathComponent(".ssh"))),
            ("caches-itself", .removeContents(home.appendingPathComponent("Library/Caches"))),
            ("apple-cache", .removeContents(home.appendingPathComponent("Library/Caches/com.apple.Safari"))),
            ("relative", .removeContents(URL(fileURLWithPath: "relative/path"))),
            ("artifact-outside", .removeArtifact(outside)),
            ("name-dotdot", .removeCacheFolderContents(name: "../../Documents")),
            ("name-escape", .removeCacheFolderContents(name: "x/../../../../../../etc")),
            ("name-dot", .removeCacheFolderContents(name: "..")),
            ("name-empty", .removeCacheFolderContents(name: "")),
            ("worktree-outside", .worktree(.remove(repo: outside, path: outside))),
        ]
        // The ids are forged too: one is a safe-looking name, one points at a protected place. The plan does not use the id.
        let findings = actions.enumerated().map { index, entry in
            Finding(id: index % 2 == 0 ? "example.cache" : "/etc", ecosystem: .swift, title: entry.0, location: "x", bytes: 1,
                    tier: .safe, rebuild: .seconds, action: entry.1)
        }
        let plan = CleanPlan(ScanResult(findings: findings, disk: DiskUsage(total: 1, free: 1)), guardian: guardian,
                             running: RunningSnapshot(apps: []), deleteMode: .permanent)
        for item in plan.items {
            XCTAssertFalse(item.wouldClean, "\(item.finding.title) must not be cleaned")
            XCTAssertFalse(item.skipReason.isEmpty, item.finding.title)
        }
        // A valid path stays valid even when its id is forged: the path decides, not the id.
        let good = home.appendingPathComponent("Library/Caches/Fine")
        let forged = Finding(id: "/etc", ecosystem: .swift, title: "good", location: "x", bytes: 1, tier: .safe, rebuild: .seconds,
                             action: .removeContents(good))
        let single = CleanPlan(ScanResult(findings: [forged], disk: DiskUsage(total: 1, free: 1)), guardian: guardian,
                               running: RunningSnapshot(apps: []), deleteMode: .permanent)
        XCTAssertTrue(single.items[0].wouldClean)
    }

    func testAnItemThatBecameALinkIsNotCleaned() throws {
        let home = try makeHome()
        let caches = home.appendingPathComponent("Library/Caches")
        let target = caches.appendingPathComponent("Example")
        try put(target.appendingPathComponent("a.bin"))
        let guardian = PathGuard(home: home, keep: [])
        let finding = Finding(id: "example.cache", ecosystem: .swift, title: "Example", location: "x", bytes: 1, tier: .safe,
                              rebuild: .seconds, action: .removeContents(target))
        func plan() -> CleanPlan {
            CleanPlan(ScanResult(findings: [finding], disk: DiskUsage(total: 1, free: 1)), guardian: guardian,
                      running: RunningSnapshot(apps: []), deleteMode: .permanent)
        }
        XCTAssertTrue(plan().items[0].wouldClean, "before the change")

        // The scan saw a folder. Now the folder is a link to a folder outside the home folder.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tp-link-\(UUID().uuidString)")
        try put(outside.appendingPathComponent("keep.me"))
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        XCTAssertFalse(plan().items[0].wouldClean)
        XCTAssertEqual(plan().items[0].skipReason, "refused by the path guard: path is a symbolic link")

        // A link in a parent folder.
        let inner = Finding(id: "example.inner", ecosystem: .swift, title: "Inner", location: "x", bytes: 1, tier: .safe,
                            rebuild: .seconds, action: .removeContents(target.appendingPathComponent("keep.me")))
        let deep = CleanPlan(ScanResult(findings: [inner], disk: DiskUsage(total: 1, free: 1)), guardian: guardian,
                             running: RunningSnapshot(apps: []), deleteMode: .permanent)
        XCTAssertFalse(deep.items[0].wouldClean)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.me").path))
    }

    // MARK: Command line

    func testCommandLineCombinations() {
        func err(_ a: String...) -> String? { CommandLineCheck.error(["trashpanda"] + a) }
        // Fine.
        for ok in [[], ["--scan"], ["--scan", "--json"], ["--clean-safe", "--dry-run"], ["--dry-run", "--clean-safe"],
                   ["--clean-safe", "--dry-run", "--json"], ["--json", "--clean-safe", "--dry-run"],
                   ["--clean-safe", "--dry-run", "--verbose"], ["--clean-safe", "--dry-run", "--json", "--verbose"],
                   ["--scan", "--verbose"], ["--verbose"], ["--version"], ["--help"], ["--demo"]] {
            XCTAssertNil(CommandLineCheck.error(["trashpanda"] + ok), "\(ok)")
        }
        // Wrong.
        XCTAssertEqual(err("--clean-safe"), "--clean-safe needs --dry-run in this version")
        XCTAssertEqual(err("--clean-safe", "--json"), "--clean-safe needs --dry-run in this version")
        XCTAssertEqual(err("--clean-safe", "--verbose"), "--clean-safe needs --dry-run in this version")
        XCTAssertEqual(err("--dry-run"), "--dry-run works only with --clean-safe")
        XCTAssertEqual(err("--dry-run", "--scan"), "--dry-run works only with --clean-safe")
        XCTAssertEqual(err("--dry-run", "--json"), "--dry-run works only with --clean-safe")
        XCTAssertNotNil(err("--yes"))
        XCTAssertNotNil(err("--clean-safe", "--yes"))
        XCTAssertNotNil(err("--clean-safe", "--dry-run", "--yes"))
        XCTAssertNotNil(err("--clean-safe", "--dry-run", "--yes", "--json"))
        XCTAssertNotNil(err("--scan", "--yes"))
        XCTAssertNotNil(err("--scan", "--clean-safe", "--dry-run"))
        XCTAssertNotNil(err("--json"))
        XCTAssertNotNil(err("--json", "--demo"))
        XCTAssertNotNil(err("--json", "--verbose"))
        XCTAssertNotNil(err("--clean-safe", "--dry-run", "--nope"))
        XCTAssertNotNil(err("--delete"))
        XCTAssertTrue(CommandLineCheck.isDryRun(["t", "--clean-safe", "--dry-run"]))
        XCTAssertFalse(CommandLineCheck.isDryRun(["t", "--clean-safe"]))
        XCTAssertFalse(CommandLineCheck.isDryRun(["t", "--dry-run"]))
        XCTAssertEqual(CommandLineCheck.mode(["t", "--clean-safe", "--dry-run"]), "clean-safe --dry-run")
        XCTAssertEqual(CommandLineCheck.mode(["t", "--clean-safe", "--dry-run", "--json"]), "clean-safe --dry-run --json")
        XCTAssertEqual(CommandLineCheck.logOptions(["t", "--clean-safe", "--dry-run", "x"]), "options=--clean-safe --dry-run other=1")
    }

    func testRealCleanDoesNotExistYet() throws {
        // Step 2 has no real clean: the main file has no way to start one.
        let main = try String(contentsOf: root().appendingPathComponent("Sources/TrashPanda/main.swift"), encoding: .utf8)
        XCTAssertFalse(main.contains("\"--yes\""))
        XCTAssertTrue(CommandLineCheck.knownOptions.contains("--yes"), "known, so that the error says why")
        XCTAssertNotNil(CommandLineCheck.error(["t", "--clean-safe", "--dry-run", "--yes"]))
    }

    // MARK: Log

    func testLogLinesHoldTheAuditTrail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-planlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Log.fileURL
        defer { Log.fileURL = old }
        Log.fileURL = dir.appendingPathComponent("logs/trashpanda.log")
        let report = DryRunReport(Self.fixture(), plan: Self.plan(), home: Self.home)
        for entry in report.findings { Log.info(entry.logLine) }
        Log.info("cli end dry-run \(Self.plan().summary()) duration_ms=1 exit=0")
        Log.flush()
        let text = try String(contentsOf: Log.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("dry-run item id=example.cache wouldClean=true skipReason=\"\" bytes=5300000000"))
        XCTAssertTrue(text.contains("dry-run item id=example.kept wouldClean=false skipReason=\"on the keep list\" bytes=90000000"))
        XCTAssertEqual(text.components(separatedBy: "dry-run item id=").count - 1, 7)
        XCTAssertTrue(text.contains("wouldClean=2 skipped=5 wouldFree=5300000000"))
        XCTAssertTrue(text.hasSuffix("exit=0\n"))
    }

    // MARK: Ids

    func testIdsStayUniqueAfterTheRewrite() {
        for result in [ScanReportTests.fixture(), ScanReportTests.edgeFixture(), Self.fixture()] {
            let report = ScanReport(result, home: Self.home)
            XCTAssertEqual(Set(report.findings.map(\.id)).count, result.findings.count)
            // The raw ids are unique too, so the rewrite did not merge two of them.
            XCTAssertEqual(Set(result.findings.map(\.id)).count, result.findings.count)
        }
        XCTAssertEqual(ScanReport.id("worktree:/Users/example/a", home: Self.home), "worktree:~/a")
        XCTAssertEqual(ScanReport.id("kind:sub:/Users/example/a", home: Self.home), "kind:sub:~/a")
        XCTAssertNotEqual(ScanReport.id("worktree:/Users/example/a", home: Self.home), ScanReport.id("worktree:/Users/example/b", home: Self.home))
    }
}
