import XCTest
@testable import PandaCore

/// #60: old Claude Desktop runtimes and the Cowork VM. The shape table is the safety rule, so it has the longest tests.
final class ClaudeDesktopTests: XCTestCase {
    private let root = "Library/Application Support/Claude"

    /// What a real Claude Desktop folder holds: two runtime families, a VM, and the data that must never go.
    private func makeClaude(_ box: Sandbox, vm: Bool = true) throws {
        for v in ["2.1.309", "2.1.317"] { try box.file("\(root)/claude-code/\(v)/hash/claude.app/bin", bytes: 2_000_000) }
        try box.file("\(root)/claude-code-vm/2.1.156/claude", bytes: 1_500_000)
        try box.file("\(root)/claude-code-vm/2.1.140/claude", bytes: 1_500_000)
        if vm {
            try box.file("\(root)/vm_bundles/claudevm.bundle/rootfs.img", bytes: 3_000_000)
            try box.file("\(root)/vm_bundles/warm/x", bytes: 2_000_000)
        }
        for keep in ["IndexedDB/a/x", "Local Storage/leveldb/x", "Cookies", "config.json", "claude_desktop_config.json",
                     "claude-code-sessions/s1", "local-agent-mode-sessions/s1", "git-shadow/x", "claude-code-spare/2.1.1/x",
                     "Session Storage/x", "Preferences"] {
            try box.file("\(root)/\(keep)", bytes: 1_000)
        }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox, running: [RunningApp] = []) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent("\(root)/\(rel)").path) }
    private let neverRemoved = ["IndexedDB/a/x", "Local Storage/leveldb/x", "Cookies", "config.json", "claude_desktop_config.json",
                                "claude-code-sessions/s1", "local-agent-mode-sessions/s1", "git-shadow/x", "claude-code-spare/2.1.1/x",
                                "Session Storage/x", "Preferences"]

    // MARK: The shape table

    func testTheShapeAcceptsOnlyTheFourKindsOfFolder() {
        let ok = ["\(root)/claude-code/2.1.317", "\(root)/claude-code-vm/2.1.156", "\(root)/claude-code/2.2.0-beta.1",
                  "\(root)/vm_bundles/claudevm.bundle", "\(root)/vm_bundles/warm"]
        for p in ok { XCTAssertTrue(AgentCaches.isCleanableShape(relative: p), p) }
    }

    func testTheShapeRefusesEverythingElse() {
        let r = root
        let bad = ["\(r)", "\(r)/claude-code", "\(r)/claude-code-vm", "\(r)/vm_bundles", "\(r)/claude-code/2.1.317/hash",
                   "\(r)/claude-code/2.1.317/hash/claude.app", "\(r)/claude-code/latest", "\(r)/claude-code/2.1", "\(r)/claude-code/2.1.x",
                   "\(r)/claude-code/../Cookies", "\(r)/claude-code/./2.1.317", "\(r)/claude-code//2.1.317", "\(r)/claude-code/2.1.317/",
                   "\(r)/vm_bundles/other", "\(r)/vm_bundles/claudevm.bundle/rootfs.img", "\(r)/vm_bundles/warm/x", "\(r)/vm_bundles/../Cookies",
                   "\(r)/IndexedDB", "\(r)/Local Storage", "\(r)/Session Storage", "\(r)/Cookies", "\(r)/config.json",
                   "\(r)/claude_desktop_config.json", "\(r)/claude-code-sessions", "\(r)/claude-code-sessions/2.1.317",
                   "\(r)/local-agent-mode-sessions", "\(r)/git-shadow", "\(r)/claude-code-spare/2.1.317", "\(r)/Preferences",
                   "\(r)/Claude-Code/2.1.317", "\(r)/CLAUDE-CODE/2.1.317", "\(r)/VM_BUNDLES/warm",
                   "Library/Application Support/Other/claude-code/2.1.317", "Library/Application Support/Claude2/claude-code/2.1.317",
                   "Library/Application Support/claude-code/2.1.317", "Library/Caches/Claude/claude-code/2.1.317",
                   "claude-code/2.1.317", "", "/", "\(r)/claude-code/2.1.317\u{0}x", "\(r)/vm_bundles/warm\n"]
        for p in bad { XCTAssertFalse(AgentCaches.isCleanableShape(relative: p), "\"\(p)\"") }
    }

    func testTheGuardFollowsTheShapeTable() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        func check(_ rel: String) -> Refusal? { g.check(box.home.appendingPathComponent(rel)) }
        XCTAssertNil(check("\(root)/claude-code/2.1.309"))
        XCTAssertNil(check("\(root)/vm_bundles/claudevm.bundle"))
        for rel in ["IndexedDB", "Local Storage", "Cookies", "config.json", "claude-code-sessions", "claude-code", "vm_bundles",
                    "claude-code/2.1.309/hash", "git-shadow"] {
            XCTAssertNotNil(check("\(root)/\(rel)"), rel)
        }
        XCTAssertNotNil(check(root))
        XCTAssertNotNil(check("Library/Application Support"))
    }

    // MARK: The lists

    func testOnlyTheOldRuntimesAreListedAndTheNewestOfEachFamilyStays() throws {
        let box = try Sandbox()
        try makeClaude(box)
        let old = ClaudeDesktop.oldRuntimes(home: box.home)
        XCTAssertEqual(old.map { "\($0.family)/\($0.url.lastPathComponent)" }, ["claude-code/2.1.309", "claude-code-vm/2.1.140"])
    }

    func testVersionsAreComparedByNumber() throws {
        let box = try Sandbox()
        for v in ["2.1.9", "2.1.10", "2.1.2"] { try box.file("\(root)/claude-code/\(v)/x", bytes: 1_000) }
        XCTAssertEqual(ClaudeDesktop.oldRuntimes(home: box.home).map { $0.url.lastPathComponent }, ["2.1.9", "2.1.2"])
    }

    func testOnlyPlainFoldersWithVersionNamesCount() throws {
        let box = try Sandbox()
        try box.file("\(root)/claude-code/2.1.317/x", bytes: 1_000)
        try box.file("\(root)/claude-code/latest/x", bytes: 1_000)
        try box.file("\(root)/claude-code/2.1.300", bytes: 1_000)                          // a file
        try box.file("elsewhere/x", bytes: 1_000)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(root)/claude-code/2.1.200"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(ClaudeDesktop.oldRuntimes(home: box.home).isEmpty, "Only 2.1.317 is a real version folder, and it is the newest")
    }

    func testAFamilyFolderThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/2.1.1/x", bytes: 1_000)
        try box.file("elsewhere/2.1.2/x", bytes: 1_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(root), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(root)/claude-code"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(ClaudeDesktop.oldRuntimes(home: box.home).isEmpty)
    }

    func testTheVMFoldersAreListedFromFixedNames() throws {
        let box = try Sandbox()
        try makeClaude(box)
        try box.file("\(root)/vm_bundles/other/x", bytes: 1_000)
        XCTAssertEqual(ClaudeDesktop.vmBundles(home: box.home).map { $0.url.lastPathComponent }, ["claudevm.bundle", "warm"])
    }

    // MARK: Pinned versions and the preview

    func testTheVersionThatTheAppPinsStays() throws {
        let box = try Sandbox()
        try box.file("\(root)/claude-code-vm/2.1.156/claude", bytes: 1_000)
        try box.file("\(root)/claude-code-vm/2.1.140/claude", bytes: 1_000)
        try box.file("\(root)/claude-code-vm/2.1.100/claude", bytes: 1_000)
        try "2.1.140\n".write(to: box.home.appendingPathComponent("\(root)/claude-code-vm/.sdk-version"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeDesktop.oldRuntimes(home: box.home).map { $0.url.lastPathComponent }, ["2.1.100"],
                       "2.1.156 is newest and 2.1.140 is pinned")
    }

    func testAPinFileWithJunkIsIgnored() throws {
        let box = try Sandbox()
        try box.file("\(root)/claude-code-vm/2.1.156/claude", bytes: 1_000)
        try box.file("\(root)/claude-code-vm/2.1.140/claude", bytes: 1_000)
        for junk in ["latest", "../2.1.140", "2.1.140 x", ""] {
            try junk.write(to: box.home.appendingPathComponent("\(root)/claude-code-vm/.sdk-version"), atomically: true, encoding: .utf8)
            XCTAssertEqual(ClaudeDesktop.oldRuntimes(home: box.home).map { $0.url.lastPathComponent }, ["2.1.140"], junk)
        }
    }

    func testACleanRemovesOnlyWhatThePreviewNamed() throws {
        let box = try Sandbox()
        try makeClaude(box, vm: false)
        let item = try XCTUnwrap(scanner(box).scanClaudeDesktop().first { $0.id == "agent.claude.runtimes" })
        XCTAssertEqual(item.action.agentNames, ["claude-code/2.1.309", "claude-code-vm/2.1.140"])
        try box.file("\(root)/claude-code/2.1.330/x", bytes: 1_000)          // the app updated after the preview: 2.1.317 is old now
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "claude-code/2.1.309"))
        XCTAssertTrue(exists(box, "claude-code/2.1.317/hash/claude.app/bin"), "It was the newest in the preview, so it was not named")
    }

    func testAFolderThatBecameALinkAfterThePreviewIsNotFollowed() throws {
        let box = try Sandbox()
        try makeClaude(box, vm: false)
        try box.file("proj/Cache/precious", bytes: 1_000)
        let item = try XCTUnwrap(scanner(box).scanClaudeDesktop().first { $0.id == "agent.claude.runtimes" })
        try FileManager.default.removeItem(at: box.home.appendingPathComponent("\(root)/claude-code/2.1.309"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(root)/claude-code/2.1.309"),
                                                   withDestinationURL: box.home.appendingPathComponent("proj"))
        _ = cleaner(box).clean([item])
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("proj/Cache/precious").path))
    }

    func testALinkAboveTheAppFolderIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/Claude/claude-code/2.1.1/x", bytes: 1_000_000)
        try box.file("elsewhere/Claude/claude-code/2.1.2/x", bytes: 1_000_000)
        try box.file("elsewhere/Claude/vm_bundles/warm/x", bytes: 1_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Application Support"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(scanner(box).scanClaudeDesktop().isEmpty)
        let forged = Finding(id: "f", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .download,
                             action: .agent(.removeOldClaudeDesktopRuntimes(names: ["claude-code/2.1.1"])))
        let vm = Finding(id: "g", ecosystem: .aiAgents, title: "y", location: "y", bytes: 1, tier: .review, rebuild: .download,
                         action: .agent(.removeClaudeVMBundle))
        XCTAssertEqual(cleaner(box).clean([forged, vm]).removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("elsewhere/Claude/claude-code/2.1.1/x").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("elsewhere/Claude/vm_bundles/warm/x").path))
    }

    // MARK: The items

    func testTheRuntimeItemIsAReviewItemOfClaudeDesktop() throws {
        let box = try Sandbox()
        try makeClaude(box)
        let item = try XCTUnwrap(scanner(box).scanClaudeDesktop().first { $0.id == "agent.claude.runtimes" })
        XCTAssertEqual(item.title, "Claude · old Desktop runtimes")
        XCTAssertEqual(item.tier, .review)
        XCTAssertEqual(item.ecosystem, .aiAgents)
        XCTAssertEqual(item.owner?.bundleIDs, ["com.anthropic.claudefordesktop*"])
        XCTAssertTrue(item.bytes >= 3_000_000 && item.bytes < 4_000_000, "\(item.bytes)")
        XCTAssertTrue(item.location.contains("claude-code 2.1.309") && item.location.contains("newest of each stays"), item.location)
        XCTAssertNotNil(AgentProduct.info(forTitle: item.title))
    }

    func testTheVMItemWarnsAndLinksToTheChangelog() throws {
        let box = try Sandbox()
        try makeClaude(box)
        let item = try XCTUnwrap(scanner(box).scanClaudeDesktop().first { $0.id == "agent.claude.vm" })
        XCTAssertEqual(item.title, "Claude · Cowork VM")
        XCTAssertEqual(item.tier, .review)
        XCTAssertTrue(item.bytes >= 5_000_000 && item.bytes < 6_000_000, "\(item.bytes)")
        XCTAssertTrue(item.note?.contains("10 GB") == true && item.note?.contains("Settings, Storage") == true)
        XCTAssertEqual(item.helpURL, ClaudeDesktop.changelogURL)
    }

    func testNoItemsWhenThereIsNothingToRemove() throws {
        let box = try Sandbox()
        try box.file("\(root)/claude-code/2.1.317/x", bytes: 2_000_000)
        XCTAssertTrue(scanner(box).scanClaudeDesktop().isEmpty, "One version is the newest, and there is no VM")
        XCTAssertTrue(scanner(try Sandbox()).scanClaudeDesktop().isEmpty)
    }

    func testNeitherItemIsInTheOneClickTotal() throws {
        let box = try Sandbox()
        try makeClaude(box)
        let result = ScanResult(findings: scanner(box).scanClaudeDesktop(), disk: DiskUsage(total: 1, free: 1))
        XCTAssertEqual(result.reclaimable, 0)
        XCTAssertTrue(result.reviewable >= 8_000_000)
    }

    // MARK: The clean

    func testCleaningTheRuntimesKeepsTheNewestAndEverythingElse() throws {
        let box = try Sandbox()
        try makeClaude(box)
        let item = try XCTUnwrap(scanner(box).scanClaudeDesktop().first { $0.id == "agent.claude.runtimes" })
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, item.bytes)
        XCTAssertFalse(exists(box, "claude-code/2.1.309") || exists(box, "claude-code-vm/2.1.140"))
        XCTAssertTrue(exists(box, "claude-code/2.1.317/hash/claude.app/bin") && exists(box, "claude-code-vm/2.1.156/claude"))
        XCTAssertTrue(exists(box, "vm_bundles/claudevm.bundle/rootfs.img"), "The VM is a separate item")
        for keep in neverRemoved { XCTAssertTrue(exists(box, keep), keep) }
    }

    func testCleaningTheVMRemovesOnlyTheTwoFolders() throws {
        let box = try Sandbox()
        try makeClaude(box)
        let item = try XCTUnwrap(scanner(box).scanClaudeDesktop().first { $0.id == "agent.claude.vm" })
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "vm_bundles/claudevm.bundle") || exists(box, "vm_bundles/warm"))
        XCTAssertTrue(exists(box, "claude-code/2.1.309/hash/claude.app/bin"), "The runtimes are a separate item")
        for keep in neverRemoved { XCTAssertTrue(exists(box, keep), keep) }
        XCTAssertEqual(scanner(box).remainingBytes(of: item), 0)
    }

    func testAnOpenClaudeDesktopBlocksBothItems() throws {
        let box = try Sandbox()
        try makeClaude(box)
        let report = cleaner(box, running: [RunningApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude")])
            .clean(scanner(box).scanClaudeDesktop())
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.blockedApps, ["Claude"])
        XCTAssertTrue(exists(box, "claude-code/2.1.309/hash/claude.app/bin") && exists(box, "vm_bundles/warm/x"))
    }

    func testForgedFindingsForUserDataRemoveNothing() throws {
        let box = try Sandbox()
        try makeClaude(box)
        func forged(_ rel: String) -> Finding {
            let url = box.home.appendingPathComponent("\(root)/\(rel)")
            return Finding(id: rel, ecosystem: .aiAgents, title: "x", location: rel, bytes: 5_000_000, tier: .review, rebuild: .download,
                           action: .removeContents(url))
        }
        let report = cleaner(box).clean(["IndexedDB", "Local Storage", "Cookies", "config.json", "claude-code-sessions",
                                         "local-agent-mode-sessions", "git-shadow", "", "claude-code", "vm_bundles"].map(forged))
        XCTAssertEqual(report.removed, 0)
        for keep in neverRemoved { XCTAssertTrue(exists(box, keep), keep) }
        XCTAssertTrue(exists(box, "claude-code/2.1.317/hash/claude.app/bin"))
        XCTAssertTrue(exists(box, "vm_bundles/claudevm.bundle/rootfs.img"))
    }

    // MARK: The dialogs

    func testTheVMDialogWarnsAndKeepsTheVMByDefault() throws {
        let box = try Sandbox()
        try makeClaude(box)
        let vm = try XCTUnwrap(scanner(box).scanClaudeDesktop().first { $0.id == "agent.claude.vm" })
        let c = Confirmation.forOne(vm, staleDays: 30)
        XCTAssertEqual(Confirmation.kind(of: vm), .vmBundle)
        XCTAssertEqual(c.title, "Remove the Cowork VM?")
        XCTAssertEqual(c.confirmTitle, "Remove VM")
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertFalse(c.footer?.contains("GB") == true, "No number that gets old")
        XCTAssertTrue(c.footer?.contains("Settings, Storage") == true && c.footer?.contains("lost") == true)
        let runtimes = try XCTUnwrap(scanner(box).scanClaudeDesktop().first { $0.id == "agent.claude.runtimes" })
        XCTAssertEqual(Confirmation.kind(of: runtimes), .agentRuntime)
        XCTAssertTrue(Confirmation.forOne(runtimes, staleDays: 30).cancelIsDefault)
    }
}
