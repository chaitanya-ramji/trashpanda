import XCTest
@testable import PandaCore

/// #62: VS Code and its forks. The chats of Copilot and Cursor, the logins, and the unsaved files live in the same folder.
final class EditorCachesTests: XCTestCase {
    private let code = "Library/Application Support/Code"
    private let log = "20260213T210548"
    /// What must never be removed.
    private let data = ["User/settings.json", "User/workspaceStorage/abc/chatSessions/s1.json", "User/globalStorage/state.vscdb",
                        "User/globalStorage/state.vscdb.backup", "User/globalStorage/github.copilot/x", "Backups/w/untitled-1",
                        "Local Storage/leveldb/x", "Session Storage/x", "Cookies", "Preferences", "languagepacks.json", "machineid",
                        "CachedConfigurations/x", "CachedProfilesData/x", "Network Persistent State", "logs/not-a-timestamp/x"]

    private func make(_ box: Sandbox, root: String = "Library/Application Support/Code", logAge: Int = 30) throws {
        for n in EditorCaches.apps.first { $0.supportRoot == root }!.names { try box.file("\(root)/\(n)/f", bytes: 150_000) }
        try box.file("\(root)/logs/\(log)/main.log", bytes: 150_000)
        box.age(box.home.appendingPathComponent("\(root)/logs/\(log)"), days: logAge)
        try box.file("\(root)/logs/20261108T090000/main.log", bytes: 150_000)                  // today: a window may write here
        for d in data { try box.file("\(root)/\(d)", bytes: 500) }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox, running: [RunningApp] = []) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func items(_ box: Sandbox) -> [Finding] { scanner(box).scanEditorCaches() }
    private var app: EditorApp { EditorCaches.app(id: "vscode")! }

    // MARK: The shape rules

    func testTheAllowedShapes() {
        for a in EditorCaches.apps {
            for n in a.names { XCTAssertTrue(AgentCaches.isCleanableShape(relative: "\(a.supportRoot)/\(n)"), "\(a.id) \(n)") }
            XCTAssertTrue(AgentCaches.isCleanableShape(relative: "\(a.supportRoot)/logs/20260213T210548"), a.id)
        }
    }

    func testTheShapeRefusesEverythingElse() {
        for a in EditorCaches.apps {
            let r = a.supportRoot
            var bad = ["\(r)", "\(r)/logs", "\(r)/logs/x", "\(r)/logs/2026-02-13", "\(r)/logs/20260213T210548/main.log",
                       "\(r)/logs/20260213T21054", "\(r)/logs/20260213T2105480", "\(r)/logs/20260213 210548", "\(r)/logs/../User",
                       "\(r)/logs//20260213T210548", "\(r)/logs/./20260213T210548", "\(r)/logs/20260213T210548/", "\(r)/LOGS/20260213T210548",
                       "\(r)/cacheddata", "\(r)/CachedData/x", "\(r)/CachedData/", "\(r)/User", "\(r)/User/workspaceStorage",
                       "\(r)/User/globalStorage", "\(r)/Backups", "\(r)\n/CachedData", "Library/Application Support/CachedData",
                       "Library/Application Support/Other/CachedData", "\(r)2/CachedData"]
            for d in data { bad.append("\(r)/\(d)") }
            for p in bad { XCTAssertFalse(EditorCaches.isShape(relative: p), "\(a.id) \"\(p)\"") }
        }
    }

    func testAntigravityHasTheEditorNamesAndNotTheChromiumNamesHere() {
        let ag = EditorCaches.app(id: "antigravity")!
        XCTAssertEqual(ag.names, ["CachedData", "CachedExtensionVSIXs"])
        XCTAssertFalse(EditorCaches.isShape(relative: "\(ag.supportRoot)/Code Cache"), "Those belong to the Electron table")
        XCTAssertTrue(AgentCaches.isCleanableShape(relative: "\(ag.supportRoot)/Code Cache"), "and the guard still allows them there")
    }

    func testTheGuardFollowsTheShapes() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        func check(_ rel: String) -> Refusal? { g.check(box.home.appendingPathComponent(rel)) }
        XCTAssertNil(check("\(code)/CachedData"))
        XCTAssertNil(check("\(code)/logs/\(log)"))
        for d in data { XCTAssertNotNil(check("\(code)/\(d)"), d) }
        XCTAssertNotNil(check(code))
        XCTAssertNotNil(check("\(code)/logs"))
    }

    func testTheTableMatchesTheProductTable() {
        for a in EditorCaches.apps {
            XCTAssertNotNil(AgentProduct.info(forTitle: a.title), a.title)
            XCTAssertNotNil(AgentProduct.info(forTitle: a.extensionsTitle), a.extensionsTitle)
            XCTAssertFalse(a.owner.bundleIDs.isEmpty)
        }
        XCTAssertEqual(Set(EditorCaches.apps.map(\.id)).count, EditorCaches.apps.count)
        // No folder may be offered by both tables, or it would be counted twice.
        for e in AgentCaches.electronApps {
            for a in EditorCaches.apps where a.supportRoot == e.supportRoot {
                XCTAssertTrue(Set(e.names).isDisjoint(with: a.names), a.id)
            }
        }
    }

    // MARK: The items

    func testOneSafeItemAndOnlyOldLogsCount() throws {
        let box = try Sandbox()
        try make(box)
        let item = try XCTUnwrap(items(box).first)
        XCTAssertEqual(items(box).count, 1)
        XCTAssertEqual(item.id, "agent.editor:vscode")
        XCTAssertEqual(item.title, "VS Code · editor caches")
        XCTAssertEqual(item.tier, .safe)
        XCTAssertEqual(item.owner?.bundleIDs, ["com.microsoft.VSCode*"])
        XCTAssertTrue(item.location.contains("9 cache folders, 1 old log"), item.location)
        let targets = EditorCaches.targets(of: app, home: box.home, now: Date()).map(\.lastPathComponent)
        XCTAssertTrue(targets.contains(log) && !targets.contains("20261108T090000"))
    }

    func testTheLogLimitIsSevenDays() throws {
        let box = try Sandbox()
        try make(box, logAge: 0)
        let dir = box.home.appendingPathComponent("\(code)/logs/\(log)")
        let now = Date()
        func set(_ days: Double) { try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86_400)], ofItemAtPath: dir.path) }
        set(7)
        XCTAssertTrue(EditorCaches.targets(of: app, home: box.home, now: now).contains { $0.lastPathComponent == log })
        set(6.99)
        XCTAssertFalse(EditorCaches.targets(of: app, home: box.home, now: now).contains { $0.lastPathComponent == log })
    }

    func testOneItemForEachEditorThatIsInstalled() throws {
        let box = try Sandbox()
        try make(box, root: "Library/Application Support/Code")
        try make(box, root: "Library/Application Support/Cursor")
        try make(box, root: "Library/Application Support/Antigravity IDE")
        XCTAssertEqual(Set(items(box).map(\.title)), ["VS Code · editor caches", "Cursor · editor caches", "Antigravity · IDE editor caches"])
    }

    func testNothingWhenThereIsNothing() throws {
        let box = try Sandbox()
        XCTAssertTrue(items(box).isEmpty)
        try box.file("\(code)/User/settings.json", bytes: 2_000_000)
        XCTAssertTrue(items(box).isEmpty)
    }

    func testLinksAreNeverFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/f", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(code), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(code)/CachedData"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("\(code)/logs"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(code)/logs/\(log)"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(items(box).isEmpty)
    }

    func testALinkAboveTheEditorFolderIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/Code/CachedData/f", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Application Support"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(items(box).isEmpty)
        let forged = Finding(id: "f", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                             action: .agent(.removeEditorCaches(appID: "vscode")))
        XCTAssertEqual(cleaner(box).clean([forged]).removed, 0)
        XCTAssertTrue(exists(box, "elsewhere/Code/CachedData/f"))
    }

    // MARK: The clean

    func testACleanKeepsEveryChatLoginAndUnsavedFile() throws {
        let box = try Sandbox()
        try make(box)
        let item = try XCTUnwrap(items(box).first)
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, item.bytes)
        for n in app.names { XCTAssertFalse(exists(box, "\(code)/\(n)"), n) }
        XCTAssertFalse(exists(box, "\(code)/logs/\(log)"))
        XCTAssertTrue(exists(box, "\(code)/logs/20261108T090000/main.log"), "A new log stays")
        for d in data { XCTAssertTrue(exists(box, "\(code)/\(d)"), d) }
        XCTAssertEqual(scanner(box).remainingBytes(of: item), 0)
    }

    func testAnOpenEditorBlocksItsItem() throws {
        let box = try Sandbox()
        try make(box)
        let report = cleaner(box, running: [RunningApp(bundleID: "com.microsoft.VSCode", name: "Code")]).clean(items(box))
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.blockedApps, ["Code"])
        XCTAssertTrue(exists(box, "\(code)/CachedData/f"))
    }

    func testForgedFindingsForUserDataRemoveNothing() throws {
        let box = try Sandbox()
        try make(box)
        func forged(_ rel: String) -> Finding {
            Finding(id: rel, ecosystem: .aiAgents, title: "x", location: rel, bytes: 5_000_000, tier: .safe, rebuild: .download,
                    action: .removeContents(box.home.appendingPathComponent("\(code)/\(rel)")))
        }
        let top = Set(data.map { String($0.split(separator: "/")[0]) })
        let report = cleaner(box).clean((Array(top) + ["", "logs"]).map(forged))
        XCTAssertEqual(report.removed, 0)
        for d in data { XCTAssertTrue(exists(box, "\(code)/\(d)"), d) }
    }

    func testAnUnknownEditorIdRemovesNothing() throws {
        let box = try Sandbox()
        try make(box)
        for action in [AgentAction.removeEditorCaches(appID: "../Documents"), .removeObsoleteExtensions(appID: "x")] {
            let f = Finding(id: "x", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download, action: .agent(action))
            XCTAssertEqual(cleaner(box).clean([f]).removed, 0)
        }
        XCTAssertTrue(exists(box, "\(code)/CachedData/f"))
    }

    // MARK: Obsolete extensions

    private let ext = ".vscode/extensions"
    private func makeExtensions(_ box: Sandbox) throws {
        for n in ["pub.old-1.0.0", "pub.stale-2.0.0", "pub.current-3.0.0", "pub.unlisted-1.0.0", "pub.false-1.0.0"] {
            try box.file("\(ext)/\(n)/package.json", bytes: 400_000)
        }
        try #"{"pub.old-1.0.0": true, "pub.stale-2.0.0": true, "pub.false-1.0.0": false, "../escape": true, ".hidden": true, "a/b": true, "pub.missing-1.0.0": true}"#
            .write(to: box.home.appendingPathComponent("\(ext)/.obsolete"), atomically: true, encoding: .utf8)
        try #"[{"identifier": {"id": "pub.stale"}, "version": "2.0.0", "relativeLocation": "pub.stale-2.0.0"}]"#
            .write(to: box.home.appendingPathComponent("\(ext)/extensions.json"), atomically: true, encoding: .utf8)
    }

    func testOnlyFoldersThatTheEditorMarksObsoleteAndDoesNotListAreOffered() throws {
        let box = try Sandbox()
        try makeExtensions(box)
        XCTAssertEqual(EditorCaches.obsoleteExtensions(of: app, home: box.home).map(\.lastPathComponent), ["pub.old-1.0.0"],
                       "stale is listed as installed, false is not obsolete, the odd names are invalid, missing has no folder")
        let item = try XCTUnwrap(items(box).first { $0.id == "agent.extensions:vscode" })
        XCTAssertEqual(item.title, "VS Code · obsolete extensions")
        XCTAssertEqual(item.tier, .safe)
        XCTAssertTrue(item.location.contains("1 old version"), item.location)
    }

    func testACleanRemovesOnlyThatFolder() throws {
        let box = try Sandbox()
        try makeExtensions(box)
        let item = try XCTUnwrap(items(box).first { $0.id == "agent.extensions:vscode" })
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, item.bytes)
        XCTAssertFalse(exists(box, "\(ext)/pub.old-1.0.0"))
        for keep in ["pub.stale-2.0.0", "pub.current-3.0.0", "pub.unlisted-1.0.0", "pub.false-1.0.0", ".obsolete", "extensions.json"] {
            XCTAssertTrue(exists(box, "\(ext)/\(keep)"), keep)
        }
    }

    func testAnExtensionThatBecameInstalledAfterThePreviewStays() throws {
        let box = try Sandbox()
        try makeExtensions(box)
        let item = try XCTUnwrap(items(box).first { $0.id == "agent.extensions:vscode" })
        try #"[{"relativeLocation": "pub.old-1.0.0"}, {"relativeLocation": "pub.stale-2.0.0"}]"#
            .write(to: box.home.appendingPathComponent("\(ext)/extensions.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(cleaner(box).clean([item]).removed, 0)
        XCTAssertTrue(exists(box, "\(ext)/pub.old-1.0.0"))
    }

    func testAChangedFormatOfTheRegistryKeepsMore() throws {
        let box = try Sandbox()
        try makeExtensions(box)
        // The name is nested somewhere unexpected. Every string counts, so it is still found.
        try #"{"v2": {"items": [["x", {"path": "/Users/u/.vscode/extensions/pub.old-1.0.0/bin"}, "pub.stale-2.0.0"]]}}"#
            .write(to: box.home.appendingPathComponent("\(ext)/extensions.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(EditorCaches.obsoleteExtensions(of: app, home: box.home).isEmpty)
    }

    func testBrokenOrMissingFilesGiveNothing() throws {
        let box = try Sandbox()
        try box.file("\(ext)/pub.old-1.0.0/x", bytes: 400_000)
        XCTAssertTrue(EditorCaches.obsoleteExtensions(of: app, home: box.home).isEmpty, "No .obsolete")
        for junk in ["", "not json", "[]", #"{"pub.old-1.0.0": "yes"}"#, #"{"pub.old-1.0.0": 1}"#, #"{"pub.old-1.0.0": null}"#] {
            try junk.write(to: box.home.appendingPathComponent("\(ext)/.obsolete"), atomically: true, encoding: .utf8)
            XCTAssertTrue(EditorCaches.obsoleteExtensions(of: app, home: box.home).isEmpty, junk)
        }
    }

    func testWithoutTheRegistryNothingIsRemoved() throws {
        let box = try Sandbox()
        try makeExtensions(box)
        let registry = box.home.appendingPathComponent("\(ext)/extensions.json")
        XCTAssertEqual(EditorCaches.obsoleteExtensions(of: app, home: box.home).count, 1)
        try FileManager.default.removeItem(at: registry)
        XCTAssertTrue(EditorCaches.obsoleteExtensions(of: app, home: box.home).isEmpty, "We cannot tell what is installed")
        try "this is not json".write(to: registry, atomically: true, encoding: .utf8)
        XCTAssertTrue(EditorCaches.obsoleteExtensions(of: app, home: box.home).isEmpty)
        try "".write(to: registry, atomically: true, encoding: .utf8)
        XCTAssertTrue(EditorCaches.obsoleteExtensions(of: app, home: box.home).isEmpty)
        XCTAssertTrue(items(box).filter { $0.id.hasPrefix("agent.extensions") }.isEmpty)
        let f = Finding(id: "x", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                        action: .agent(.removeObsoleteExtensions(appID: "vscode")))
        XCTAssertEqual(cleaner(box).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, "\(ext)/pub.old-1.0.0/package.json"))
    }

    func testAnExtensionFolderThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("proj/precious", bytes: 400_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(ext), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(ext)/pub.old-1.0.0"),
                                                   withDestinationURL: box.home.appendingPathComponent("proj"))
        try #"{"pub.old-1.0.0": true}"#.write(to: box.home.appendingPathComponent("\(ext)/.obsolete"), atomically: true, encoding: .utf8)
        XCTAssertTrue(EditorCaches.obsoleteExtensions(of: app, home: box.home).isEmpty)
    }

    func testAnExtensionsFolderThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/pub.old-1.0.0/x", bytes: 400_000)
        try #"{"pub.old-1.0.0": true}"#.write(to: box.home.appendingPathComponent("elsewhere/.obsolete"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".vscode"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(ext), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(EditorCaches.obsoleteExtensions(of: app, home: box.home).isEmpty)
    }

    func testAnEditorWithoutAnExtensionsFolderHasNoExtensionsItem() throws {
        XCTAssertNil(EditorCaches.app(id: "antigravity")!.extensionsRoot)
        XCTAssertTrue(EditorCaches.obsoleteExtensions(of: EditorCaches.app(id: "antigravity")!, home: try Sandbox().home).isEmpty)
    }

    func testNameRules() {
        for good in ["ms-python.python-2025.1.0-darwin-arm64", "pub.name-1.0.0", "a+b.c-1"] { XCTAssertTrue(EditorCaches.isExtensionFolderName(good), good) }
        for bad in ["", ".hidden", "../x", "a/b", "a b", "-x", "a..b", "x\n", ".obsolete"] { XCTAssertFalse(EditorCaches.isExtensionFolderName(bad), bad) }
    }

    func testBothItemsAreInTheOneClickTotal() throws {
        let box = try Sandbox()
        try make(box)
        try makeExtensions(box)
        XCTAssertTrue(ScanResult(findings: items(box), disk: DiskUsage(total: 1, free: 1)).reclaimable >= 1_000_000)
    }
}
