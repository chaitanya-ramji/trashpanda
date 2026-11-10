import XCTest
@testable import PandaCore

/// #58: leftover installs and the downloaded runtime of the Codex app.
final class CodexRuntimesTests: XCTestCase {
    private let root = ".cache/codex-runtimes"
    private let staging = "codex-runtime-install-odLBYG"

    private func makeCache(_ box: Sandbox, stagingAge: Int = 3) throws {
        try box.file("\(root)/\(staging)/payload/bin/python", bytes: 3_000_000)
        try box.file("\(root)/\(staging)/node-runtime.tar.xz", bytes: 1_000_000)
        try box.file("\(root)/codex-primary-runtime/dependencies/lib/x", bytes: 2_000_000)
        try box.file("\(root)/codex-primary-runtime/runtime.json", bytes: 100)
        box.age(box.home.appendingPathComponent("\(root)/\(staging)"), days: stagingAge)
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox, running: [RunningApp] = [], programs: [String] = []) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider,
                       programPaths: { programs })
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func found(_ box: Sandbox) -> [Finding] { scanner(box).scanCodexRuntimes() }

    // MARK: The group

    func testTheGroupHasNamesAndAProductPrefix() {
        XCTAssertEqual(Ecosystem.aiAgents.shortName, "AI agents")
        XCTAssertEqual(Ecosystem.aiAgents.name, "AI agents & local models")
        XCTAssertEqual(AgentProduct.name(ofTitle: "Codex · downloaded runtime"), "Codex")
        XCTAssertEqual(AgentProduct.name(ofTitle: "Ollama · model llama3:8b"), "Ollama")
        XCTAssertNil(AgentProduct.name(ofTitle: "No product here"))
        XCTAssertNil(AgentProduct.name(ofTitle: " · starts with the separator"))
    }

    func testEveryProductHasAnIconPlan() {
        let names = AgentProduct.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "Names are unique")
        for p in AgentProduct.all {
            XCTAssertFalse(p.symbol.isEmpty, p.name)
            XCTAssertFalse(p.name.contains(AgentProduct.separator))
            XCTAssertTrue(p.iconBundleIDs.allSatisfy { !$0.contains("*") }, "\(p.name): an icon needs an exact bundle ID")
        }
        XCTAssertEqual(AgentProduct.info(forTitle: "Codex · downloaded runtime")?.iconBundleIDs, ["com.openai.codex"])
        XCTAssertNil(AgentProduct.info(forTitle: "Unknown · x"))
        XCTAssertNotNil(AgentProduct.info(forTitle: "Ollama · model x")?.symbol)
    }

    func testTheOwnerOfEachFindingIsAProduct() throws {
        let box = try Sandbox()
        try makeCache(box)
        for f in found(box) { XCTAssertNotNil(AgentProduct.info(forTitle: f.title), f.title) }
    }

    // MARK: The items

    func testBothFoldersAreListedWithTheRightTiers() throws {
        let box = try Sandbox()
        try makeCache(box)
        let items = found(box)
        XCTAssertEqual(items.count, 2)
        let stale = try XCTUnwrap(items.first { $0.id == "agent.codex.staging:\(staging)" })
        XCTAssertEqual(stale.title, "Codex · leftover runtime install")
        XCTAssertEqual(stale.tier, .safe)
        XCTAssertTrue(stale.location.contains("3 days old"), stale.location)
        XCTAssertTrue(stale.bytes >= 4_000_000 && stale.bytes < 5_000_000, "\(stale.bytes)")
        let runtime = try XCTUnwrap(items.first { $0.id == "agent.codex.runtime" })
        XCTAssertEqual(runtime.title, "Codex · downloaded runtime")
        XCTAssertEqual(runtime.tier, .review)
        XCTAssertNotNil(runtime.note)
        for f in items {
            XCTAssertEqual(f.ecosystem, .aiAgents)
            XCTAssertEqual(f.owner?.bundleIDs, ["com.openai.codex*"])
            XCTAssertEqual(f.rebuild, .download)
        }
    }

    func testAnInstallYoungerThanADayIsNotListed() throws {
        let box = try Sandbox()
        try makeCache(box, stagingAge: 0)
        XCTAssertEqual(found(box).map(\.id), ["agent.codex.runtime"], "It can still be running")
    }

    func testTheLimitIsOneDay() throws {
        let box = try Sandbox()
        try makeCache(box)
        let dir = box.home.appendingPathComponent("\(root)/\(staging)")
        let now = Date()
        func set(_ hours: Double) {
            try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-hours * 3_600)], ofItemAtPath: dir.path)
        }
        set(25)
        XCTAssertEqual(CodexRuntimes.list(home: box.home, now: now).filter { $0.kind == .staging }.count, 1)
        set(23)
        XCTAssertEqual(CodexRuntimes.list(home: box.home, now: now).filter { $0.kind == .staging }.count, 0)
    }

    func testOnlyTheKnownNamesCount() throws {
        let box = try Sandbox()
        for n in ["codex-runtime-install-abc", "codex-runtime-install-toolong1", "codex-runtime-install-", "codex-runtime-install-ab_cde",
                  "other-folder", "codex-primary-runtime-old", "Codex-Primary-Runtime"] {
            try box.file("\(root)/\(n)/x", bytes: 2_000_000, age: 5)
        }
        try box.file("\(root)/codex-runtime-install-FILEXX", bytes: 2_000_000, age: 5)   // a file, not a folder
        XCTAssertTrue(found(box).isEmpty)
    }

    func testALinkIsNeverFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/big/x", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(root), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(root)/\(staging)"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere/big"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(root)/codex-primary-runtime"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere/big"))
        XCTAssertTrue(found(box).isEmpty)
    }

    func testARootThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/codex-primary-runtime/x", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(root),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(found(box).isEmpty)
    }

    func testNothingWhenTheCacheIsMissing() throws {
        XCTAssertTrue(found(try Sandbox()).isEmpty)
    }

    // MARK: The clean

    func testCleaningTheLeftoverKeepsTheRuntime() throws {
        let box = try Sandbox()
        try makeCache(box)
        let item = try XCTUnwrap(found(box).first { $0.tier == .safe })
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, item.bytes)
        XCTAssertFalse(exists(box, "\(root)/\(staging)"))
        XCTAssertTrue(exists(box, "\(root)/codex-primary-runtime/runtime.json"), "The runtime stays")
    }

    func testCleaningTheRuntimeKeepsTheLeftoverAndTheRest() throws {
        let box = try Sandbox()
        try makeCache(box)
        try box.file(".codex/auth.json", bytes: 50)
        let item = try XCTUnwrap(found(box).first { $0.tier == .review })
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "\(root)/codex-primary-runtime"))
        XCTAssertTrue(exists(box, "\(root)/\(staging)/node-runtime.tar.xz"))
        XCTAssertTrue(exists(box, ".codex/auth.json"), "The login is never touched")
        XCTAssertEqual(scanner(box).remainingBytes(of: item), 0)
    }

    func testAnOpenAppBlocksBothItems() throws {
        let box = try Sandbox()
        try makeCache(box)
        let report = cleaner(box, running: [RunningApp(bundleID: "com.openai.codex", name: "ChatGPT")]).clean(found(box))
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.blockedApps, ["ChatGPT"])
        XCTAssertTrue(exists(box, "\(root)/\(staging)") && exists(box, "\(root)/codex-primary-runtime"))
    }

    func testAnOpenHelperOfTheAppAlsoBlocks() throws {
        let box = try Sandbox()
        try makeCache(box)
        let report = cleaner(box, running: [RunningApp(bundleID: "com.openai.codex.helper", name: "Codex Helper")]).clean(found(box))
        XCTAssertEqual(report.removed, 0)
    }

    func testAProgramThatRunsFromTheFolderKeepsIt() throws {
        let box = try Sandbox()
        try makeCache(box)
        let python = box.home.appendingPathComponent("\(root)/codex-primary-runtime/dependencies/bin/python").path
        let report = cleaner(box, programs: [python]).clean(found(box).filter { $0.tier == .review })
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.skipped[0].contains("runs"), report.skipped[0])
        XCTAssertTrue(exists(box, "\(root)/codex-primary-runtime"))
    }

    func testAnInstallThatBecameNewIsKept() throws {
        let box = try Sandbox()
        try makeCache(box)
        let item = try XCTUnwrap(found(box).first { $0.tier == .safe })
        box.age(box.home.appendingPathComponent("\(root)/\(staging)"), days: 0)     // a new install started after the scan
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(box, "\(root)/\(staging)"))
    }

    func testForgedFindingsRemoveNothing() throws {
        let box = try Sandbox()
        try makeCache(box)
        try box.file("Documents/keep.txt", bytes: 100)
        func forged(_ rel: String) -> Finding {
            Finding(id: rel, ecosystem: .aiAgents, title: "x", location: rel, bytes: 5_000_000, tier: .safe, rebuild: .download,
                    action: .agent(.removeCodexRuntime(box.home.appendingPathComponent(rel))))
        }
        let paths = [root, ".cache", "\(root)/codex-primary-runtime/dependencies", "\(root)/codex-primary-runtime/runtime.json",
                     "\(root)/other", "Documents", "Documents/keep.txt", "\(root)/../.codex", "\(root)/\(staging)/payload"]
        let report = cleaner(box).clean(paths.map(forged))
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, paths.count)
        for rel in ["\(root)/codex-primary-runtime/dependencies/lib/x", "\(root)/\(staging)/payload/bin/python", "Documents/keep.txt"] {
            XCTAssertTrue(exists(box, rel), rel)
        }
    }

    // MARK: Totals and dialogs

    func testOnlyTheLeftoverIsInTheOneClickTotal() throws {
        let box = try Sandbox()
        try makeCache(box)
        let result = ScanResult(findings: found(box), disk: DiskUsage(total: 1, free: 1))
        XCTAssertTrue(result.reclaimable >= 4_000_000 && result.reclaimable < 5_000_000, "\(result.reclaimable)")
        XCTAssertTrue(result.reviewable >= 2_000_000)
    }

    func testTheRuntimeDialogKeepsTheRuntimeByDefault() throws {
        let box = try Sandbox()
        try makeCache(box)
        let runtime = try XCTUnwrap(found(box).first { $0.tier == .review })
        let c = Confirmation.forOne(runtime, staleDays: 30)
        XCTAssertEqual(Confirmation.kind(of: runtime), .agentRuntime)
        XCTAssertEqual(c.title, "Remove this downloaded runtime?")
        XCTAssertEqual(c.confirmTitle, "Remove runtime")
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertTrue(c.body.contains("1.7 GB"))
        let stale = try XCTUnwrap(found(box).first { $0.tier == .safe })
        XCTAssertEqual(Confirmation.kind(of: stale), .ordinary)
    }
}
