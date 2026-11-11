import XCTest
@testable import PandaCore

/// While a folder is measured, a folder above it becomes a link (or a program starts). The handler must delete nothing,
/// count no byte, and report a skip. The folder is moved to `<name>-moved`, and a link takes its place.
final class CleanerLinkWhileMeasuringTests: XCTestCase {
    /// A cleaner with no running apps, no running programs, and no running Claude processes.
    private func plainCleaner(_ box: Sandbox, programs: @escaping () -> [String] = { [] }) -> Cleaner {
        Cleaner(guardian: PathGuard(home: box.home), runningApps: FakeRunning(apps: []).provider, programPaths: programs,
                openClaudeBinaries: { _ in [] })
    }

    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    /// The first measuring swaps the folder `swap` for a link. Returns the number of deletes that were called.
    private func linkWhileMeasuring(_ box: Sandbox, _ cleaner: Cleaner, swap rel: String) -> () -> Int {
        let parent = box.home.appendingPathComponent(rel)
        let moved = box.home.appendingPathComponent(rel + "-moved")
        var swapped = false
        var deletes = 0
        cleaner.sizeOf = { url in
            if !swapped {
                swapped = true
                try? FileManager.default.moveItem(at: parent, to: moved)
                try? FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
            }
            return Sizer.size(of: url)
        }
        cleaner.deleteItem = { url in deletes += 1; try FileManager.default.removeItem(at: url) }
        return { deletes }
    }

    /// `stays` is a path inside the moved folder that must still be there.
    private func assertRefused(_ box: Sandbox, _ finding: Finding, swap: String, stays: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let c = plainCleaner(box)
        let deletes = linkWhileMeasuring(box, c, swap: swap)
        let report = c.clean([finding])
        XCTAssertEqual(deletes(), 0, file: file, line: line)
        XCTAssertEqual(report.freed, 0, file: file, line: line)
        XCTAssertEqual(report.removed, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(report.skipped.count, 1, "a skip is reported: \(report.skipped)", file: file, line: line)
        XCTAssertTrue(report.failed.isEmpty, file: file, line: line)
        XCTAssertTrue(exists(box, "\(swap)-moved/\(stays)"), "the data is still there", file: file, line: line)
    }

    private func finding(_ action: Action, _ tier: Tier = .safe) -> Finding {
        Finding(id: "x", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: tier, rebuild: .download, action: action)
    }

    // MARK: Q-04 handlers

    func testArchive() throws {
        let box = try Sandbox()
        let dated = "Library/Developer/Xcode/Archives/2026-05-01"
        let folder = try box.file("\(dated)/Real.xcarchive/Info.plist", bytes: 1_000_000).deletingLastPathComponent()
        assertRefused(box, finding(.removeArchive(folder), .review), swap: dated, stays: "Real.xcarchive/Info.plist")
    }

    func testDeviceSupport() throws {
        let box = try Sandbox()
        let platform = "Library/Developer/Xcode/iOS DeviceSupport"
        let folder = try box.file("\(platform)/iPhone15,2 17.5 (21F79)/Symbols/a", bytes: 1_000_000)
            .deletingLastPathComponent().deletingLastPathComponent()
        assertRefused(box, finding(.removeDeviceSupport(folder), .review), swap: platform, stays: "iPhone15,2 17.5 (21F79)/Symbols/a")
    }

    func testBuildFolder() throws {
        let box = try Sandbox()
        try box.file("Developer/app/package.json", bytes: 10)
        let folder = try box.file("Developer/app/node_modules/x/i.js", bytes: 1_000_000).deletingLastPathComponent().deletingLastPathComponent()
        assertRefused(box, finding(.removeArtifact(folder)), swap: "Developer/app", stays: "node_modules/x/i.js")
    }

    /// A program starts in the project while the build folder is measured. The check after the measuring sees it.
    func testABuildFolderStaysWhenItsProjectBecomesActiveWhileMeasuring() throws {
        let box = try Sandbox()
        try box.file("Developer/app/package.json", bytes: 10)
        let folder = try box.file("Developer/app/node_modules/x/i.js", bytes: 1_000_000).deletingLastPathComponent().deletingLastPathComponent()
        let c = plainCleaner(box)
        var started = false
        var deletes = 0
        let project = box.home.appendingPathComponent("Developer/app").path
        c.activeDirectories = { started ? [project] : [] }
        c.sizeOf = { _ in started = true; return 1 }
        c.deleteItem = { _ in deletes += 1 }
        let report = c.clean([finding(.removeArtifact(folder))])
        XCTAssertEqual(deletes, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.skipped.count, 1, "\(report.skipped)")
        XCTAssertTrue((report.skipped.first ?? "").contains("project is in use"), "\(report.skipped)")
    }

    /// The second project becomes active only while the second folder is measured. The list that was read for the first folder is too old.
    func testTwoBuildFoldersTheSecondProjectBecomesActiveWhileItsOwnMeasuring() throws {
        let box = try Sandbox()
        var folders: [URL] = []
        for name in ["a", "b"] {
            try box.file("Developer/\(name)/package.json", bytes: 10)
            folders.append(try box.file("Developer/\(name)/node_modules/x/i.js", bytes: 1_000_000)
                .deletingLastPathComponent().deletingLastPathComponent())
        }
        let c = plainCleaner(box)
        var measured = 0
        var deleted: [String] = []
        let second = box.home.appendingPathComponent("Developer/b").path
        c.activeDirectories = { measured >= 2 ? [second] : [] }
        c.sizeOf = { _ in measured += 1; return 1 }
        c.deleteItem = { url in deleted.append(url.path); try FileManager.default.removeItem(at: url) }
        let report = c.clean(folders.map { finding(.removeArtifact($0)) })
        XCTAssertEqual(deleted, [folders[0].path])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(exists(box, "Developer/b/node_modules/x/i.js"), "the project that runs keeps its folder")
        XCTAssertTrue((report.skipped.first ?? "").contains("project is in use"), "\(report.skipped)")
    }

    func testABuildFolderUnderALinkedProjectFolderSaysThatAFolderInThePathIsALink() throws {
        let box = try Sandbox()
        try box.file("Developer/real/package.json", bytes: 10)
        try box.file("Developer/real/node_modules/x/i.js", bytes: 1_000_000)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Developer/app"),
                                                   withDestinationURL: box.home.appendingPathComponent("Developer/real"))
        let url = box.home.appendingPathComponent("Developer/app/node_modules")
        let report = plainCleaner(box).clean([finding(.removeArtifact(url))])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue((report.skipped.first ?? "").contains("a folder in the path is a link"), "\(report.skipped)")
        XCTAssertTrue(exists(box, "Developer/real/node_modules/x/i.js"))
    }

    // MARK: A program starts while measuring

    /// A program starts from the second version only while the second version is measured. The list that was read for the first is too old.
    func testTwoTestBrowserVersionsAProgramStartsFromTheSecondWhileItIsMeasured() throws {
        let box = try Sandbox()
        let pw = "Library/Caches/ms-playwright"
        for v in ["1100", "1200", "1300"] { try box.file("\(pw)/chromium-\(v)/chrome", bytes: 3_000_000) }
        var measured = 0
        var secondPath: String?
        var deleted: [String] = []
        let c = plainCleaner(box, programs: { secondPath.map { [$0 + "/chrome"] } ?? [] })
        c.sizeOf = { url in
            measured += 1
            if measured == 2 { secondPath = url.path }
            return 1
        }
        c.deleteItem = { url in deleted.append(url.path) }
        let scan = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let report = c.clean(scan.scanTestBrowsers())
        XCTAssertEqual(measured, 2)
        XCTAssertEqual(deleted.count, 1, "only the first version goes: \(deleted)")
        XCTAssertNotEqual(deleted.first, secondPath)
        XCTAssertTrue((report.skipped.first ?? "").contains("a program runs from it"), "\(report.skipped)")
    }

    func testATestBrowserVersionStaysWhenAProgramStartsFromItWhileMeasuring() throws {
        let box = try Sandbox()
        let pw = "Library/Caches/ms-playwright"
        for v in ["1200", "1300"] { try box.file("\(pw)/chromium-\(v)/chrome", bytes: 3_000_000) }
        let running = box.home.appendingPathComponent("\(pw)/chromium-1200/chrome").path
        var measured = false
        var deletes = 0
        let c = plainCleaner(box, programs: { measured ? [running] : [] })
        c.sizeOf = { _ in measured = true; return 1 }
        c.deleteItem = { _ in deletes += 1 }
        let scan = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let report = c.clean(scan.scanTestBrowsers())
        XCTAssertEqual(deletes, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertTrue((report.skipped.first ?? "").contains("a program runs from it"), "\(report.skipped)")
    }

    // MARK: The other handlers

    func testOldLogs() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/App/nested/old.log", bytes: 2_000_000, age: 90)
        assertRefused(box, finding(.removeOldLogs(.logs), .review), swap: "Library/Logs/App", stays: "nested/old.log")
    }

    func testOldSessions() throws {
        let box = try Sandbox()
        try box.file(".codex/sessions/a.jsonl", bytes: 2_000_000, age: 60)
        let action = Action.agent(.removeOldSessions(kind: .codex, olderThan: Date().addingTimeInterval(-30 * 86_400), minimumAgeDays: 30))
        assertRefused(box, finding(action, .review), swap: ".codex/sessions", stays: "a.jsonl")
    }

    func testFixedFolders() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/Zed/languages/rust-analyzer/bin", bytes: 3_000_000)
        assertRefused(box, finding(.agent(.removeFixedFolders(appID: "zed"))), swap: "Library/Application Support/Zed",
                      stays: "languages/rust-analyzer/bin")
    }

    func testEditorCaches() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/Code/CachedData/f", bytes: 3_000_000)
        assertRefused(box, finding(.agent(.removeEditorCaches(appID: "vscode"))), swap: "Library/Application Support/Code",
                      stays: "CachedData/f")
    }

    func testObsoleteExtensions() throws {
        let box = try Sandbox()
        let ext = ".vscode/extensions"
        try box.file("\(ext)/pub.old-1.0.0/package.json", bytes: 400_000)
        try #"{"pub.old-1.0.0": true}"#.write(to: box.home.appendingPathComponent("\(ext)/.obsolete"), atomically: true, encoding: .utf8)
        try "[]".write(to: box.home.appendingPathComponent("\(ext)/extensions.json"), atomically: true, encoding: .utf8)
        assertRefused(box, finding(.agent(.removeObsoleteExtensions(appID: "vscode"))), swap: ext, stays: "pub.old-1.0.0/package.json")
    }

    func testAgentCaches() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/Claude/Cache/f", bytes: 3_000_000)
        assertRefused(box, finding(.agent(.removeAgentCaches(appID: "claude"))), swap: "Library/Application Support/Claude",
                      stays: "Cache/f")
    }

    func testOldClaudeVersions() throws {
        let box = try Sandbox()
        let dir = ".local/share/claude/versions"
        for n in ["2.1.314", "2.1.319", "2.1.321"] { try box.file("\(dir)/\(n)", bytes: 2_000_000) }
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".local/bin/claude"),
                                                   withDestinationURL: box.home.appendingPathComponent("\(dir)/2.1.321"))
        assertRefused(box, finding(.agent(.removeOldClaudeVersions(names: ["2.1.314", "2.1.319"]))), swap: dir, stays: "2.1.314")
    }
}
