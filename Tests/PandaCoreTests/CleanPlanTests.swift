import XCTest
@testable import PandaCore

final class CleanPlanTests: XCTestCase {
    static let editor = AppOwner(name: "Example Editor", bundleIDs: ["com.example.editor"])

    static func folder(_ name: String, in home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/" + name)
    }

    /// Makes the folders of the fixture on a real temporary home. The checks of the plan read the disk now.
    /// "Gone" is not made: it is the item that is not there. Nothing here is the real home folder.
    static func populate(_ box: Sandbox) throws {
        for name in ["Example", "Models", "Blocked", "Kept", "Editor", "Upper"] {
            try box.file("Library/Caches/\(name)/a.bin", bytes: 10)
        }
        try box.file("Documents/letter.txt", bytes: 10)
    }

    /// A scan with fixed values. It has a safe item, a review item, a blocked item, an info item, a kept item,
    /// an item whose owner app is open, an upper-limit item, a tool item, an item that the path guard refuses,
    /// and an item that is not there now. The ids, the titles, and the locations are fixed text, so the output does not hold the temporary home.
    static func fixture(_ home: URL) -> ScanResult {
        let findings = [
            Finding(id: "example.cache", ecosystem: .swift, title: "Example build cache", location: "~/Library/Caches/Example",
                    bytes: 5_300_000_000, tier: .safe, rebuild: .minutes, action: .removeContents(folder("Example", in: home))),
            Finding(id: "example.models", ecosystem: .aiAgents, title: "Example models", location: "~/.example/models",
                    bytes: 12_000_000_000, tier: .review, rebuild: .download, action: .removeContents(folder("Models", in: home))),
            Finding(id: "example.blocked", ecosystem: .worktrees, title: "Example blocked", location: "~/code/busy",
                    bytes: 40_000_000, tier: .safe, rebuild: .recreate, action: .removeContents(folder("Blocked", in: home)),
                    blockedReason: "Has changes that are not committed"),
            Finding(id: "example.info", ecosystem: .homebrew, title: "Example note", location: "~/Library/Example",
                    bytes: 1_500_000, tier: .safe, rebuild: .never, action: .inform),
            Finding(id: "example.kept", ecosystem: .javascript, title: "Example kept cache", location: "~/Library/Caches/Kept",
                    bytes: 90_000_000, tier: .safe, rebuild: .seconds, action: .removeContents(folder("Kept", in: home))),
            Finding(id: "example.open", ecosystem: .apps, title: "Example editor cache", location: "~/Library/Caches/Editor",
                    bytes: 250_000_000, tier: .safe, rebuild: .seconds, action: .removeContents(folder("Editor", in: home)),
                    owner: editor),
            Finding(id: "example.upper", ecosystem: .docker, title: "Example upper limit", location: "Docker",
                    bytes: 700_000_000, tier: .safe, rebuild: .seconds, action: .removeContents(folder("Upper", in: home)),
                    sizeIsUpperLimit: true),
            Finding(id: "example.tool", ecosystem: .homebrew, title: "Example tool item", location: "Trash",
                    bytes: 300_000_000, tier: .safe, rebuild: .never, action: .emptyTrash),
            Finding(id: "example.refused", ecosystem: .swift, title: "Example refused", location: "~/Documents/letter.txt",
                    bytes: 20_000_000, tier: .safe, rebuild: .never, action: .removeContents(home.appendingPathComponent("Documents/letter.txt"))),
            Finding(id: "example.gone", ecosystem: .python, title: "Example gone", location: "~/Library/Caches/Gone",
                    bytes: 10_000_000, tier: .safe, rebuild: .seconds, action: .removeContents(folder("Gone", in: home))),
        ]
        return ScanResult(findings: findings, disk: DiskUsage(total: 500_000_000_000, free: 42_000_000_000),
                          date: Date(timeIntervalSince1970: 0))
    }

    static let editorOpen = RunningSnapshot(apps: [RunningApp(bundleID: "com.example.editor", name: "Example Editor")])

    static func plan(_ result: ScanResult, home: URL, keep: [String]? = nil,
                     running: RunningSnapshot = editorOpen, mode: DeleteMode = .permanent) -> CleanPlan {
        let guardian = PathGuard(home: home, keep: keep ?? [home.path + "/Library/Caches/Kept"])
        return CleanPlan(result, guardian: guardian, running: running, deleteMode: mode)
    }

    private func golden(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/cleanplan"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fixtureBox() throws -> Sandbox {
        let box = try Sandbox()
        try Self.populate(box)
        return box
    }

    // MARK: Decisions and output

    func testEachItemGetsItsReason() throws {
        let box = try fixtureBox()
        let plan = Self.plan(Self.fixture(box.home), home: box.home)
        XCTAssertEqual(plan.items.map(\.wouldClean), [true, false, false, false, false, false, true, true, false, false])
        XCTAssertEqual(plan.items.map(\.skipReason), [
            "", "review item", "blocked: Has changes that are not committed", "info only", "on the keep list",
            "owner app is open (Example Editor)", "", "", "refused by the path guard: path is protected (Documents)", "not there now",
        ])
        XCTAssertEqual(plan.wouldClean.map(\.finding.id), ["example.cache", "example.upper", "example.tool"])
        // The upper-limit item counts 0, as in the app.
        XCTAssertEqual(plan.wouldFree, 5_600_000_000)
        XCTAssertEqual(plan.wouldFree, plan.wouldClean.reduce(0) { $0 + $1.finding.countedBytes })
    }

    func testCheckedNowAndCheckedAtCleanTime() throws {
        let box = try fixtureBox()
        let plan = Self.plan(Self.fixture(box.home), home: box.home, running: RunningSnapshot(apps: []))
        // A path item is checked now. A tool item is not, and a tool decides at clean time.
        XCTAssertEqual(plan.items.map(\.checkedNow), [true, false, false, false, true, true, true, false, true, true])
        XCTAssertEqual(plan.items.map(\.checkedAtCleanTime), ["", "", "", "", "", "app state is read again", "", "tool decides", "", ""])
        // The owner app is closed here, so the item is cleaned, and its app state is read again.
        XCTAssertTrue(plan.items[5].wouldClean)
        XCTAssertEqual(plan.checkedAgainAtCleanTime.map(\.finding.id), ["example.open", "example.tool"])
        // A skipped item never says what is checked at clean time.
        let open = Self.plan(Self.fixture(box.home), home: box.home)
        for item in open.skipped { XCTAssertEqual(item.checkedAtCleanTime, "", item.finding.title) }
    }

    func testClosedOwnerAppIsNotASkip() throws {
        let box = try fixtureBox()
        let plan = Self.plan(Self.fixture(box.home), home: box.home, running: RunningSnapshot(apps: []))
        XCTAssertEqual(plan.items[5].skipReason, "")
        XCTAssertTrue(plan.items[5].wouldClean)
    }

    func testJSONEqualsGolden() throws {
        let box = try fixtureBox()
        let result = Self.fixture(box.home)
        let report = DryRunReport(result, plan: Self.plan(result, home: box.home), home: box.home.path)
        let json = report.json()
        XCTAssertEqual(json, try golden("dry-run.json"))
        XCTAssertFalse(json.contains(box.home.path), "the output never holds the home folder")
        XCTAssertEqual(json.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(json.contains("\"mode\":\"dry-run\""))
        XCTAssertTrue(json.contains("\"wouldFree\":5600000000"))
        let decoded = try JSONDecoder().decode(DryRunReport.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.schema, 1)
    }

    func testStep1FieldsAreStillThereAndUnchanged() throws {
        let box = try fixtureBox()
        let result = Self.fixture(box.home)
        let scan = ScanReport(result, home: box.home.path)
        let dry = DryRunReport(result, plan: Self.plan(result, home: box.home), home: box.home.path)
        XCTAssertEqual(dry.findings.map(\.base), scan.findings)
        XCTAssertEqual(dry.disk, scan.disk)
        XCTAssertEqual(dry.totals.reclaimable, scan.totals.reclaimable)
        XCTAssertEqual(dry.totals.reviewable, scan.totals.reviewable)
        // Each finding object has all the keys of step 1 and step 2, and two more. Every key is always present.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(dry.json().utf8)) as? [String: Any])
        for entry in try XCTUnwrap(object["findings"] as? [[String: Any]]) {
            XCTAssertEqual(Set(entry.keys), ["id", "group", "title", "bytes", "tier", "rebuild", "location", "blocked", "blockedReason",
                                             "upperLimit", "countedBytes", "wouldClean", "skipReason", "checkedNow", "checkedAtCleanTime"])
            XCTAssertTrue(entry["checkedNow"] is Bool)
            XCTAssertTrue(entry["checkedAtCleanTime"] is String)
        }
        XCTAssertEqual(Set((object["totals"] as? [String: Any] ?? [:]).keys), ["reclaimable", "reviewable", "wouldFree"])
    }

    func testTextEqualsGolden() throws {
        let box = try fixtureBox()
        let plan = Self.plan(Self.fixture(box.home), home: box.home)
        XCTAssertEqual(plan.text(verbose: false), try golden("dry-run.txt"))
        XCTAssertEqual(plan.text(verbose: true), try golden("dry-run-verbose.txt"))
        let trash = Self.plan(Self.fixture(box.home), home: box.home, mode: .trash)
        XCTAssertEqual(trash.text(verbose: false), try golden("dry-run-trash.txt"))
        XCTAssertEqual(DryRunReport(Self.fixture(box.home), plan: trash, home: box.home.path).json(), try golden("dry-run-trash.json"))
    }

    func testVerboseLinesReadCleanly() throws {
        let box = try fixtureBox()
        let text = Self.plan(Self.fixture(box.home), home: box.home).text(verbose: true)
        // No line has two colons that follow each other in a reason.
        XCTAssertTrue(text.contains("owner app is open (Example Editor) - "))
        XCTAssertFalse(text.contains("owner app is open: "))
        for line in text.split(separator: "\n") where line.contains(" - ") {
            XCTAssertLessThanOrEqual(line.prefix(while: { $0 != "[" }).filter { $0 == ":" }.count, 1, String(line))
        }
    }

    func testTextForNothingAndForTrashMode() throws {
        let box = try fixtureBox()
        let none = Self.plan(ScanResult(findings: [], disk: DiskUsage(total: 1, free: 1)), home: box.home)
        XCTAssertEqual(none.text(verbose: false), "0 items would be cleaned. Would free 0 KB\nNothing was deleted.\n")
        let result = Self.fixture(box.home)
        XCTAssertTrue(Self.plan(result, home: box.home, mode: .trash).text(verbose: false).contains("Delete mode is trash"))
        XCTAssertFalse(Self.plan(result, home: box.home).text(verbose: false).contains("Delete mode is trash"))
        XCTAssertTrue(DryRunReport(result, plan: Self.plan(result, home: box.home, mode: .trash), home: box.home.path).json().contains("\"deleteMode\":\"trash\""))
    }

    func testSafetyNetReasonCannotBeReachedByAnyItem() throws {
        // The last step of the plan repeats the rule of steps 1 to 3 and 8. A test cannot make an item that fails only it.
        // So we check that every combination of those inputs is already skipped with another reason.
        let box = try fixtureBox()
        let guardian = PathGuard(home: box.home)
        let folder = Self.folder("Example", in: box.home)
        for tier in [Tier.safe, .review] {
            for blocked in [nil, "busy"] as [String?] {
                for running in [Self.editorOpen, RunningSnapshot(apps: [])] {
                    for action in [Action.removeContents(folder), .inform] {
                        let f = Finding(id: "x", ecosystem: .swift, title: "x", location: "x", bytes: 1, tier: tier, rebuild: .seconds,
                                        action: action, owner: Self.editor, blockedReason: blocked)
                        let reason = CleanPlan.skipReason(f, guardian: guardian, running: running)
                        XCTAssertNotEqual(reason, CleanPlan.safetyNetReason)
                    }
                }
            }
        }
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
        let box = try fixtureBox()
        for running in [Self.editorOpen, RunningSnapshot(apps: [])] {
            let result = Self.fixture(box.home)
            let app = try appSelection(result, running: running)
            XCTAssertFalse(app.isEmpty)
            // The app does not know the keep list, the folders that are gone, and the path guard. The plan differs only by these.
            let onlyApp: Set<String> = ["example.kept", "example.refused", "example.gone"]
            let plan = Self.plan(result, home: box.home, running: running)
            XCTAssertEqual(plan.wouldClean.map(\.finding.id), app.filter { !onlyApp.contains($0) })
            XCTAssertTrue(Set(app).isSuperset(of: Set(plan.wouldClean.map(\.finding.id))))
        }
    }

    // MARK: Forged findings and links

    private func makeHome() throws -> URL { try fixtureBox().home }

    func testForgedItemsNeverWouldClean() throws {
        let box = try Sandbox()
        let home = box.home
        let guardian = PathGuard(home: home, keep: [])
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tp-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "x".write(to: outside.appendingPathComponent("x"), atomically: true, encoding: .utf8)
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
            ("archive-outside", .removeArchive(outside)),
            ("support-outside", .removeDeviceSupport(outside)),
            ("sparkle-outside", .removeUpdateDownloads(outside)),
            ("installer-outside", .removeInstaller(outside.appendingPathComponent("x.dmg"))),
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
            XCTAssertEqual(item.checkedAtCleanTime, "", item.finding.title)
        }
        // A valid path stays valid even when its id is forged: the path decides, not the id.
        try box.file("Library/Caches/Fine/a", bytes: 5)
        let forged = Finding(id: "/etc", ecosystem: .swift, title: "good", location: "x", bytes: 1, tier: .safe, rebuild: .seconds,
                             action: .removeContents(home.appendingPathComponent("Library/Caches/Fine")))
        let single = CleanPlan(ScanResult(findings: [forged], disk: DiskUsage(total: 1, free: 1)), guardian: guardian,
                               running: RunningSnapshot(apps: []), deleteMode: .permanent)
        XCTAssertTrue(single.items[0].wouldClean)
    }

    func testAnItemThatBecameALinkIsNotCleaned() throws {
        let box = try Sandbox()
        let home = box.home
        let target = Self.folder("Example", in: home)
        try box.file("Library/Caches/Example/a.bin", bytes: 10)
        let guardian = PathGuard(home: home, keep: [])
        let finding = Finding(id: "example.cache", ecosystem: .swift, title: "Example", location: "x", bytes: 1, tier: .safe,
                              rebuild: .seconds, action: .removeContents(target))
        func plan(_ f: Finding) -> CleanPlan {
            CleanPlan(ScanResult(findings: [f], disk: DiskUsage(total: 1, free: 1)), guardian: guardian,
                      running: RunningSnapshot(apps: []), deleteMode: .permanent)
        }
        XCTAssertTrue(plan(finding).items[0].wouldClean, "before the change")

        // The scan saw a folder. Now the folder is a link to a folder outside the home folder.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tp-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "x".write(to: outside.appendingPathComponent("keep.me"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        XCTAssertFalse(plan(finding).items[0].wouldClean)
        XCTAssertEqual(plan(finding).items[0].skipReason, "refused by the path guard: path is a symbolic link")

        // A link in a parent folder that leads outside the home folder.
        let inner = Finding(id: "example.inner", ecosystem: .swift, title: "Inner", location: "x", bytes: 1, tier: .safe,
                            rebuild: .seconds, action: .removeContents(target.appendingPathComponent("keep.me")))
        XCTAssertFalse(plan(inner).items[0].wouldClean)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.me").path))
    }

    // MARK: Command line

    func testCommandLineCombinations() {
        func err(_ a: String...) -> String? { CommandLineCheck.error(["trashpanda"] + a) }
        // Fine.
        for ok in [[], ["--scan"], ["--scan", "--json"], ["--clean-safe", "--dry-run"], ["--dry-run", "--clean-safe"],
                   ["--clean-safe", "--dry-run", "--json"], ["--json", "--clean-safe", "--dry-run"],
                   ["--clean-safe", "--dry-run", "--verbose"], ["--verbose", "--dry-run", "--clean-safe"],
                   ["--version"], ["--help"], ["--demo"]] {
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
        XCTAssertNotNil(err("--clean-safe", "--dry-run", "--nope"))
        XCTAssertNotNil(err("--delete"))
        // --verbose changes only the text of the dry run. Anywhere else it is a wrong option.
        XCTAssertEqual(err("--verbose"), "--verbose works only with --clean-safe --dry-run")
        XCTAssertEqual(err("--scan", "--verbose"), "--verbose works only with --clean-safe --dry-run")
        XCTAssertEqual(err("--demo", "--verbose"), "--verbose works only with --clean-safe --dry-run")
        XCTAssertEqual(err("--clean-safe", "--dry-run", "--json", "--verbose"), "--verbose cannot be used with --json")
        XCTAssertNotNil(err("--verbose", "--json"))
        XCTAssertTrue(CommandLineCheck.isDryRun(["t", "--clean-safe", "--dry-run"]))
        XCTAssertFalse(CommandLineCheck.isDryRun(["t", "--clean-safe"]))
        XCTAssertFalse(CommandLineCheck.isDryRun(["t", "--dry-run"]))
        XCTAssertEqual(CommandLineCheck.mode(["t", "--clean-safe", "--dry-run"]), "clean-safe --dry-run")
        XCTAssertEqual(CommandLineCheck.mode(["t", "--clean-safe", "--dry-run", "--json"]), "clean-safe --dry-run --json")
        XCTAssertEqual(CommandLineCheck.logOptions(["t", "--clean-safe", "--dry-run", "x"]), "options=--clean-safe --dry-run other=1")
    }

    func testRealCleanDoesNotExistYet() throws {
        // Step 2 has no real clean: no command can start one.
        XCTAssertTrue(CommandLineCheck.knownOptions.contains("--yes"), "known, so that the error says why")
        XCTAssertNotNil(CommandLineCheck.error(["t", "--clean-safe", "--dry-run", "--yes"]))
        XCTAssertEqual(CommandLineCheck.error(["t", "--clean-safe", "--yes"]), "--yes is not available in this version")
    }

    // MARK: Log

    func testLogLinesHoldTheAuditTrail() throws {
        let box = try fixtureBox()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-planlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Log.fileURL
        defer { Log.fileURL = old }
        Log.fileURL = dir.appendingPathComponent("logs/trashpanda.log")
        let result = Self.fixture(box.home)
        let plan = Self.plan(result, home: box.home)
        let report = DryRunReport(result, plan: plan, home: box.home.path)
        for entry in report.findings { Log.info(entry.logLine) }
        Log.info("cli end dry-run \(plan.summary()) duration_ms=1 exit=0")
        Log.flush()
        let text = try String(contentsOf: Log.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("dry-run item id=example.cache wouldClean=true skipReason=\"\" bytes=5300000000 checkedNow=true checkedAtCleanTime=\"\""))
        XCTAssertTrue(text.contains("dry-run item id=example.kept wouldClean=false skipReason=\"on the keep list\" bytes=90000000"))
        XCTAssertTrue(text.contains("dry-run item id=example.tool wouldClean=true skipReason=\"\" bytes=300000000 checkedNow=false checkedAtCleanTime=\"tool decides\""))
        XCTAssertEqual(text.components(separatedBy: "dry-run item id=").count - 1, 10)
        XCTAssertTrue(text.contains("wouldClean=3 skipped=7 wouldFree=5600000000 checkedAgain=1"))
        XCTAssertTrue(text.hasSuffix("exit=0\n"))
    }

    // MARK: Ids

    func testIdsStayUniqueAfterTheRewrite() throws {
        let box = try fixtureBox()
        for result in [ScanReportTests.fixture(), ScanReportTests.edgeFixture(), Self.fixture(box.home)] {
            let report = ScanReport(result, home: "/Users/example")
            XCTAssertEqual(Set(report.findings.map(\.id)).count, result.findings.count)
            // The raw ids are unique too, so the rewrite did not merge two of them.
            XCTAssertEqual(Set(result.findings.map(\.id)).count, result.findings.count)
        }
        XCTAssertEqual(ScanReport.id("worktree:/Users/example/a", home: "/Users/example"), "worktree:~/a")
        XCTAssertEqual(ScanReport.id("kind:sub:/Users/example/a", home: "/Users/example"), "kind:sub:~/a")
        XCTAssertNotEqual(ScanReport.id("worktree:/Users/example/a", home: "/Users/example"), ScanReport.id("worktree:/Users/example/b", home: "/Users/example"))
    }
}
