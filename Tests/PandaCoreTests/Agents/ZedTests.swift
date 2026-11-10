import XCTest
@testable import PandaCore

/// #66: Zed caches and language servers. Its database, extensions, and conversations are in the same folders.
final class ZedTests: XCTestCase {
    private let support = "Library/Application Support/Zed"
    private func make(_ box: Sandbox) throws {
        try box.file("Library/Caches/Zed/a/x", bytes: 1_000_000)
        try box.file("Library/Caches/dev.zed.Zed/b/x", bytes: 1_000_000)
        try box.file("\(support)/languages/rust-analyzer/bin", bytes: 3_000_000)
        for d in ["db/0-stable/db.sqlite", "extensions/installed/x/extension.toml", "conversations/c1.zed", "threads/t1.json", "settings.json",
                  "keymap.json", "logs/Zed.log", "languages-backup/x"] {
            try box.file("\(support)/\(d)", bytes: 400)
        }
        try box.file("Library/Caches/Zed2/x", bytes: 400)
    }
    private let kept = ["db/0-stable/db.sqlite", "extensions/installed/x/extension.toml", "conversations/c1.zed", "threads/t1.json", "settings.json",
                        "keymap.json", "logs/Zed.log", "languages-backup/x"]
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox, running: [RunningApp] = []) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheShapeIsExactlyThreeFolders() {
        for ok in ["Library/Caches/Zed", "Library/Caches/dev.zed.Zed", "\(support)/languages"] { XCTAssertTrue(AgentCaches.isCleanableShape(relative: ok) || FixedFolders.isShape(relative: ok), ok) }
        for bad in [support, "\(support)/db", "\(support)/extensions", "\(support)/conversations", "\(support)/threads", "\(support)/settings.json",
                    "\(support)/languages/rust-analyzer", "\(support)/languages/", "\(support)/Languages", "\(support)/languages/../db", "\(support)//languages",
                    "Library/Caches/Zed/a", "Library/Caches/Zed2", "Library/Caches", "Library/Application Support", "Library/Caches/zed",
                    "Library/Application Support/Other/languages", "", "\(support)/languages\n"] {
            XCTAssertFalse(FixedFolders.isShape(relative: bad), "\"\(bad)\"")
        }
    }

    func testTheGuardFollowsTheShape() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        func check(_ rel: String) -> Refusal? { g.check(box.home.appendingPathComponent(rel)) }
        XCTAssertNil(check("\(support)/languages"))
        for rel in [support, "\(support)/db", "\(support)/extensions", "\(support)/conversations", "\(support)/threads", "\(support)/languages/x", "\(support)/settings.json"] {
            XCTAssertNotNil(check(rel), rel)
        }
    }

    func testOneSafeItemForTheThreeFolders() throws {
        let box = try Sandbox()
        try make(box)
        let found = scanner(box).scanFixedFolders()
        let item = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(item.id, "agent.folders:zed")
        XCTAssertEqual(item.title, "Zed · caches and language servers")
        XCTAssertEqual(item.tier, .safe)
        XCTAssertEqual(item.ecosystem, .aiAgents)
        XCTAssertEqual(item.owner?.bundleIDs, ["dev.zed.Zed*"])
        XCTAssertTrue(item.bytes >= 5_000_000 && item.bytes < 5_400_000, "\(item.bytes)")
        XCTAssertTrue(item.location.contains("~/Library/Caches/Zed") && item.location.contains("~/Library/Application Support/Zed/languages"), item.location)
        XCTAssertNotNil(AgentProduct.info(forTitle: item.title))
    }

    func testOnlyTheFoldersThatExistCount() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Zed/a/x", bytes: 1_000_000)
        try box.file("\(support)/db/x", bytes: 1_000_000)
        let item = try XCTUnwrap(scanner(box).scanFixedFolders().first)
        XCTAssertFalse(item.location.contains("languages"), item.location)
        XCTAssertTrue(scanner(try Sandbox()).scanFixedFolders().isEmpty)
        let box2 = try Sandbox()
        try box2.file("\(support)/db/x", bytes: 2_000_000)
        XCTAssertTrue(scanner(box2).scanFixedFolders().isEmpty, "A database is not a cache")
    }

    func testACleanKeepsTheDatabaseExtensionsAndConversations() throws {
        let box = try Sandbox()
        try make(box)
        let item = try XCTUnwrap(scanner(box).scanFixedFolders().first)
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, item.bytes)
        for gone in ["Library/Caches/Zed", "Library/Caches/dev.zed.Zed", "\(support)/languages"] { XCTAssertFalse(exists(box, gone), gone) }
        for k in kept { XCTAssertTrue(exists(box, "\(support)/\(k)"), k) }
        XCTAssertTrue(exists(box, "Library/Caches/Zed2/x"))
        XCTAssertEqual(scanner(box).remainingBytes(of: item), 0)
    }

    func testAnOpenZedBlocksTheItem() throws {
        let box = try Sandbox()
        try make(box)
        let report = cleaner(box, running: [RunningApp(bundleID: "dev.zed.Zed", name: "Zed")]).clean(scanner(box).scanFixedFolders())
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.blockedApps, ["Zed"])
        XCTAssertTrue(exists(box, "\(support)/languages/rust-analyzer/bin"))
    }

    func testForgedFindingsRemoveNothingOfTheUserData() throws {
        let box = try Sandbox()
        try make(box)
        for rel in ["db", "extensions", "conversations", "threads", ""] {
            let f = Finding(id: rel, ecosystem: .aiAgents, title: "x", location: rel, bytes: 1, tier: .safe, rebuild: .download,
                            action: .removeContents(box.home.appendingPathComponent("\(support)/\(rel)")))
            XCTAssertEqual(cleaner(box).clean([f]).removed, 0, rel)
        }
        let unknown = Finding(id: "u", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                              action: .agent(.removeFixedFolders(appID: "../x")))
        XCTAssertEqual(cleaner(box).clean([unknown]).removed, 0)
        for k in kept { XCTAssertTrue(exists(box, "\(support)/\(k)"), k) }
    }

    func testLinksAreNeverFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/x", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches/Zed"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(support), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(support)/languages"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(scanner(box).scanFixedFolders().isEmpty)
    }

    func testAFolderThatBecameALinkAfterThePreviewIsNotFollowed() throws {
        let box = try Sandbox()
        try make(box)
        try box.file("proj/precious", bytes: 1_000)
        let item = try XCTUnwrap(scanner(box).scanFixedFolders().first)
        try FileManager.default.removeItem(at: box.home.appendingPathComponent("\(support)/languages"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(support)/languages"), withDestinationURL: box.home.appendingPathComponent("proj"))
        _ = cleaner(box).clean([item])
        XCTAssertTrue(exists(box, "proj/precious"))
        XCTAssertFalse(exists(box, "Library/Caches/Zed"), "The real folders are still removed")
    }

    func testALinkAboveTheSupportFolderIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/Zed/languages/x", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Application Support"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(scanner(box).scanFixedFolders().isEmpty)
        let f = Finding(id: "f", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download, action: .agent(.removeFixedFolders(appID: "zed")))
        XCTAssertEqual(cleaner(box).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, "elsewhere/Zed/languages/x"))
    }

    func testItIsInTheOneClickTotal() throws {
        let box = try Sandbox()
        try make(box)
        XCTAssertTrue(ScanResult(findings: scanner(box).scanFixedFolders(), disk: DiskUsage(total: 1, free: 1)).reclaimable > 0)
    }
}
