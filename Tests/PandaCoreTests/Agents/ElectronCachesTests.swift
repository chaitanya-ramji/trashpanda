import XCTest
@testable import PandaCore

/// #61: the Chromium cache folders of Claude, Codex, and Antigravity. Logins, chats, and settings are in the same folders.
final class ElectronCachesTests: XCTestCase {
    private let claude = "Library/Application Support/Claude"
    private let codex = "Library/Application Support/Codex"
    private let allNames = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache", "Shared Dictionary"]
    /// What a real profile holds besides the caches. None of it may ever be removed.
    private let data = ["IndexedDB/a/x", "Local Storage/leveldb/x", "Session Storage/x", "Cookies", "Cookies-journal", "Preferences",
                        "config.json", "User/settings.json", "Network/Cookies", "WebStorage/x", "blob_storage/x", "Crashpad/x",
                        "Partitions/p1/Local Storage/x", "Partitions/p1/IndexedDB/x", "Partitions/p1/Cookies"]

    private func make(_ box: Sandbox, root: String, extra: [String] = []) throws {
        for n in allNames + extra { try box.file("\(root)/\(n)/f", bytes: 200_000) }
        for n in allNames { try box.file("\(root)/Partitions/p1/\(n)/f", bytes: 100_000) }
        for d in data { try box.file("\(root)/\(d)", bytes: 500) }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox, running: [RunningApp] = []) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func items(_ box: Sandbox) -> [Finding] { scanner(box).scanElectronCaches() }

    // MARK: The shape rules

    func testEveryCacheNameIsAllowedAtTheRootAndInAPartition() {
        for app in AgentCaches.electronApps {
            for n in app.names {
                XCTAssertTrue(AgentCaches.isCleanableShape(relative: "\(app.supportRoot)/\(n)"), "\(app.id) \(n)")
                XCTAssertTrue(AgentCaches.isCleanableShape(relative: "\(app.supportRoot)/Partitions/launch-preview-cowork-shared/\(n)"), "\(app.id) \(n)")
            }
        }
    }

    func testTheShapeRefusesEverythingThatIsNotACacheFolder() {
        for app in AgentCaches.electronApps {
            let r = app.supportRoot
            var bad = ["\(r)", "\(r)/Partitions", "\(r)/Partitions/p1", "\(r)/Partitions/../Cache", "\(r)/Partitions/./Cache",
                       "\(r)/Partitions//Cache", "\(r)/Partitions/p1/Cache/x", "\(r)/Cache/x", "\(r)/Cache/", "\(r)/cache", "\(r)/CODE CACHE",
                       "\(r)/gpucache", "\(r)/Partitions/p1/../Cookies", "\(r)/Partitions/..hidden/Cache", "\(r)/Partitions/-x/Cache",
                       "\(r)/Partitions/a b/Cache", "\(r)/Partitions/p1/p2/Cache", "\(r)/Cache\u{0}", "\(r)Cache", "\(r)2/Cache",
                       "Library/Application Support/Other/Cache", "Library/Application Support/Cache", "Library/Caches/Cache"]
            for d in data { bad.append("\(r)/\(d)") }
            for p in bad { XCTAssertFalse(AgentCaches.isCleanableShape(relative: p), "\(app.id) \"\(p)\"") }
        }
    }

    func testEachAppAllowsOnlyItsOwnNames() {
        XCTAssertTrue(AgentCaches.isCleanableShape(relative: "\(codex)/component_crx_cache"))
        XCTAssertTrue(AgentCaches.isCleanableShape(relative: "\(codex)/extensions_crx_cache"))
        XCTAssertFalse(AgentCaches.isCleanableShape(relative: "\(claude)/component_crx_cache"), "Only the Codex app has this")
        XCTAssertFalse(AgentCaches.isElectronShape(relative: "Library/Application Support/Antigravity/CachedData"), "VS Code names belong to the editor table")
    }

    func testTheGuardFollowsTheShapes() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        func check(_ rel: String) -> Refusal? { g.check(box.home.appendingPathComponent(rel)) }
        for app in AgentCaches.electronApps {
            XCTAssertNil(check("\(app.supportRoot)/Cache"), app.id)
            XCTAssertNil(check("\(app.supportRoot)/Partitions/p1/Code Cache"), app.id)
            for d in data { XCTAssertNotNil(check("\(app.supportRoot)/\(d)"), "\(app.id) \(d)") }
            XCTAssertNotNil(check(app.supportRoot))
        }
    }

    func testTheTableMatchesTheProductTable() {
        for app in AgentCaches.electronApps {
            XCTAssertNotNil(AgentProduct.info(forTitle: app.title), app.title)
            XCTAssertFalse(app.owner.bundleIDs.isEmpty)
            XCTAssertTrue(AgentCaches.electronApp(id: app.id) == app)
        }
        XCTAssertEqual(Set(AgentCaches.electronApps.map(\.id)).count, AgentCaches.electronApps.count)
    }

    // MARK: The items

    func testOneSafeItemForEachAppThatHasCaches() throws {
        let box = try Sandbox()
        try make(box, root: claude)
        try make(box, root: codex, extra: ["component_crx_cache"])
        try box.file("Library/Caches/Codex/Default/Cache/f", bytes: 300_000)
        try box.file("Library/Caches/Codex/Default/Partitions/x", bytes: 300_000)       // not a cache name here
        let found = items(box)
        XCTAssertEqual(Set(found.map(\.id)), ["agent.electron:claude", "agent.electron:codex"])
        let c = try XCTUnwrap(found.first { $0.id == "agent.electron:claude" })
        XCTAssertEqual(c.title, "Claude · app caches")
        XCTAssertEqual(c.tier, .safe)
        XCTAssertEqual(c.ecosystem, .aiAgents)
        XCTAssertEqual(c.owner?.bundleIDs, ["com.anthropic.claudefordesktop*"])
        XCTAssertTrue(c.bytes >= 2_100_000 && c.bytes < 2_600_000, "7 root folders and 7 partition folders: \(c.bytes)")
    }

    func testTheAntigravityAppsAreTwoItemsWithTheirOwnOwners() throws {
        let box = try Sandbox()
        try make(box, root: "Library/Application Support/Antigravity")
        try make(box, root: "Library/Application Support/Antigravity IDE")
        let found = items(box)
        XCTAssertEqual(Set(found.map(\.title)), ["Antigravity · app caches", "Antigravity · IDE app caches"])
        XCTAssertEqual(found.first { $0.id.hasSuffix("-ide") }?.owner?.bundleIDs, ["com.google.antigravity-ide", "com.google.antigravity-ide.helper*"])
    }

    func testNothingWhenThereIsNothing() throws {
        let box = try Sandbox()
        XCTAssertTrue(items(box).isEmpty)
        try box.file("\(claude)/config.json", bytes: 2_000_000)
        XCTAssertTrue(items(box).isEmpty, "Data is not a cache")
    }

    // MARK: Links

    func testLinksAreNeverFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/big", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(claude), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(claude)/Cache"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("\(claude)/Partitions"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(claude)/Partitions/p1"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(items(box).isEmpty)
    }

    func testALinkAboveTheAppFolderIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/Claude/Cache/f", bytes: 3_000_000)
        try box.file("elsewhere/Claude/Partitions/p1/Code Cache/f", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Application Support"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(items(box).isEmpty)
        let forged = Finding(id: "f", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                             action: .agent(.removeAgentCaches(appID: "claude")))
        XCTAssertEqual(cleaner(box).clean([forged]).removed, 0)
        XCTAssertTrue(exists(box, "elsewhere/Claude/Cache/f") && exists(box, "elsewhere/Claude/Partitions/p1/Code Cache/f"))
    }

    func testAPartitionThatBecameALinkAfterThePreviewIsNotFollowed() throws {
        let box = try Sandbox()
        try make(box, root: claude)
        try box.file("proj/Cache/precious", bytes: 1_000)
        let item = try XCTUnwrap(items(box).first)
        try FileManager.default.removeItem(at: box.home.appendingPathComponent("\(claude)/Partitions/p1"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(claude)/Partitions/p1"),
                                                   withDestinationURL: box.home.appendingPathComponent("proj"))
        _ = cleaner(box).clean([item])
        XCTAssertTrue(exists(box, "proj/Cache/precious"), "A link that replaced a folder is never followed")
        XCTAssertFalse(exists(box, "\(claude)/Cache"), "The real caches are still removed")
    }

    func testARootThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/Cache/f", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(claude),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(items(box).isEmpty)
    }

    // MARK: The clean

    func testACleanRemovesTheCachesAndKeepsEverythingElse() throws {
        let box = try Sandbox()
        try make(box, root: claude)
        try make(box, root: codex, extra: ["component_crx_cache"])
        try box.file("Library/Caches/Codex/Default/Cache/f", bytes: 300_000)
        try box.file("Library/Caches/Codex/Default/Code Cache/f", bytes: 300_000)
        let item = try XCTUnwrap(items(box).first { $0.id == "agent.electron:claude" })
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, item.bytes)
        for n in allNames {
            XCTAssertFalse(exists(box, "\(claude)/\(n)"), n)
            XCTAssertFalse(exists(box, "\(claude)/Partitions/p1/\(n)"), n)
        }
        for d in data { XCTAssertTrue(exists(box, "\(claude)/\(d)"), d) }
        XCTAssertTrue(exists(box, "\(codex)/Cache/f"), "Another app is another item")
        XCTAssertEqual(scanner(box).remainingBytes(of: item), 0)
    }

    func testTheCodexItemAlsoCleansItsFolderInLibraryCaches() throws {
        let box = try Sandbox()
        try make(box, root: codex, extra: ["component_crx_cache"])
        try box.file("Library/Caches/Codex/Default/Cache/f", bytes: 300_000)
        try box.file("Library/Caches/Codex/Default/Code Cache/f", bytes: 300_000)
        try box.file("Library/Caches/Codex/Other/f", bytes: 300_000)
        let item = try XCTUnwrap(items(box).first { $0.id == "agent.electron:codex" })
        _ = cleaner(box).clean([item])
        XCTAssertFalse(exists(box, "Library/Caches/Codex/Default/Cache"))
        XCTAssertFalse(exists(box, "Library/Caches/Codex/Default/Code Cache"))
        XCTAssertFalse(exists(box, "\(codex)/component_crx_cache"))
        XCTAssertTrue(exists(box, "Library/Caches/Codex/Other/f"))
        for d in data { XCTAssertTrue(exists(box, "\(codex)/\(d)"), d) }
    }

    func testAnOpenAppBlocksItsItem() throws {
        let box = try Sandbox()
        try make(box, root: claude)
        let report = cleaner(box, running: [RunningApp(bundleID: "com.anthropic.claudefordesktop.helper", name: "Claude Helper")])
            .clean(items(box))
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(box, "\(claude)/Cache/f"))
    }

    func testOnlyTheOpenAppIsBlocked() throws {
        let box = try Sandbox()
        try make(box, root: claude)
        try make(box, root: codex)
        let report = cleaner(box, running: [RunningApp(bundleID: "com.openai.codex", name: "ChatGPT")]).clean(items(box))
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "\(claude)/Cache"))
        XCTAssertTrue(exists(box, "\(codex)/Cache"))
    }

    func testForgedFindingsForUserDataRemoveNothing() throws {
        let box = try Sandbox()
        try make(box, root: claude)
        func forged(_ rel: String) -> Finding {
            Finding(id: rel, ecosystem: .aiAgents, title: "x", location: rel, bytes: 5_000_000, tier: .safe, rebuild: .download,
                    action: .removeContents(box.home.appendingPathComponent("\(claude)/\(rel)")))
        }
        let report = cleaner(box).clean((data.map { String($0.split(separator: "/")[0]) } + ["", "Partitions", "Partitions/p1"]).map(forged))
        XCTAssertEqual(report.removed, 0)
        for d in data { XCTAssertTrue(exists(box, "\(claude)/\(d)"), d) }
    }

    func testAnUnknownAppIdRemovesNothing() throws {
        let box = try Sandbox()
        try make(box, root: claude)
        let f = Finding(id: "x", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                        action: .agent(.removeAgentCaches(appID: "../../Documents")))
        XCTAssertEqual(cleaner(box).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, "\(claude)/Cache/f"))
    }

    func testTheItemsAreInTheOneClickTotal() throws {
        let box = try Sandbox()
        try make(box, root: claude)
        XCTAssertTrue(ScanResult(findings: items(box), disk: DiskUsage(total: 1, free: 1)).reclaimable > 0)
    }
}
