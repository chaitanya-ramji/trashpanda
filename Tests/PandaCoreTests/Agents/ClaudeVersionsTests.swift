import XCTest
@testable import PandaCore

/// #59: old versions of the Claude Code command line tool.
final class ClaudeVersionsTests: XCTestCase {
    private let dir = ".local/share/claude/versions"

    private func makeVersions(_ box: Sandbox, _ names: [String] = ["2.1.314", "2.1.319", "2.1.321"], link: String? = "2.1.321") throws {
        for n in names { try box.file("\(dir)/\(n)", bytes: 2_000_000) }
        if let link {
            try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".local/bin/claude"),
                                                       withDestinationURL: box.home.appendingPathComponent("\(dir)/\(link)"))
        }
    }
    private func path(_ box: Sandbox, _ name: String) -> String { box.home.appendingPathComponent("\(dir)/\(name)").path }
    private func scanner(_ box: Sandbox, running: [String]? = []) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false, openClaudeBinaries: { _ in running })
    }
    private func cleaner(_ box: Sandbox, running: [String]? = []) -> Cleaner {
        let s = scanner(box, running: running)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider,
                       openClaudeBinaries: { _ in running })
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func names(_ r: (old: [ClaudeVersions.Entry], kept: [String])) -> [String] { r.old.map(\.name) }

    // MARK: Which versions stay

    func testTheNewestAndTheLinkedVersionStay() throws {
        let box = try Sandbox()
        try makeVersions(box)
        let r = ClaudeVersions.old(home: box.home, running: [])
        XCTAssertEqual(names(r), ["2.1.319", "2.1.314"])
        XCTAssertEqual(r.kept, ["2.1.321"])
    }

    func testAnOlderLinkedVersionStaysToo() throws {
        let box = try Sandbox()
        try makeVersions(box, link: "2.1.314")
        let r = ClaudeVersions.old(home: box.home, running: [])
        XCTAssertEqual(names(r), ["2.1.319"])
        XCTAssertEqual(r.kept, ["2.1.321", "2.1.314"])
    }

    func testAVersionThatRunsStays() throws {
        let box = try Sandbox()
        try makeVersions(box)
        let r = ClaudeVersions.old(home: box.home, running: [path(box, "2.1.319")])
        XCTAssertEqual(names(r), ["2.1.314"])
        XCTAssertEqual(r.kept, ["2.1.321", "2.1.319"])
    }

    func testARunningProgramStartedThroughTheLinkIsResolved() throws {
        let box = try Sandbox()
        try makeVersions(box, link: "2.1.314")
        let link = box.home.appendingPathComponent(".local/bin/claude").path
        XCTAssertEqual(names(ClaudeVersions.old(home: box.home, running: [link])), ["2.1.319"])
    }

    func testAProgramOutsideTheFolderKeepsNothing() throws {
        let box = try Sandbox()
        try makeVersions(box)
        let r = ClaudeVersions.old(home: box.home, running: ["/usr/bin/claude", "/tmp/versions/2.1.319", "\(box.home.path)/other/2.1.314"])
        XCTAssertEqual(names(r), ["2.1.319", "2.1.314"])
    }

    func testOneVersionIsNeverOld() throws {
        let box = try Sandbox()
        try makeVersions(box, ["2.1.321"])
        XCTAssertTrue(ClaudeVersions.old(home: box.home, running: []).old.isEmpty)
        XCTAssertTrue(scanner(box).scanClaudeVersions().isEmpty)
    }

    // MARK: The names

    func testVersionsAreComparedByNumber() {
        XCTAssertTrue(ClaudeVersions.isNewer("2.1.10", than: "2.1.9"))
        XCTAssertTrue(ClaudeVersions.isNewer("2.10.0", than: "2.9.99"))
        XCTAssertTrue(ClaudeVersions.isNewer("3.0.0", than: "2.99.99"))
        XCTAssertFalse(ClaudeVersions.isNewer("2.1.9", than: "2.1.10"))
        XCTAssertTrue(ClaudeVersions.isNewer("2.1.0", than: "2.1.0-beta.1"), "A plain version is newer than its beta")
        XCTAssertFalse(ClaudeVersions.isNewer("2.1.0", than: "2.1.0"))
    }

    func testOnlyVersionNamesCount() {
        for good in ["2.1.321", "10.0.1", "2.2.0-beta.1", "2.1.3.4"] { XCTAssertTrue(ClaudeVersions.isVersionName(good), good) }
        for bad in ["latest", ".tmp", "2.1", "2.1.x", "../2.1.3", "2.1.3/x", "v2.1.3", "", "2.1.3 ", "current"] {
            XCTAssertFalse(ClaudeVersions.isVersionName(bad), bad)
        }
    }

    func testOnlyPlainFilesAreVersions() throws {
        let box = try Sandbox()
        try makeVersions(box, ["2.1.321"])
        try box.file("\(dir)/latest", bytes: 2_000_000)
        try box.file("\(dir)/2.1.300/inside", bytes: 2_000_000)                  // a folder
        try box.file("elsewhere/real", bytes: 2_000_000)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(dir)/2.1.400"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere/real"))
        XCTAssertEqual(ClaudeVersions.entries(home: box.home).map(\.name), ["2.1.321"])
    }

    func testAFolderThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/2.1.300", bytes: 2_000_000)
        try box.file("elsewhere/2.1.301", bytes: 2_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".local/share/claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(dir),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(ClaudeVersions.entries(home: box.home).isEmpty)
        XCTAssertTrue(scanner(box).scanClaudeVersions().isEmpty)
    }

    func testNothingWhenThereIsNoFolder() throws {
        XCTAssertTrue(scanner(try Sandbox()).scanClaudeVersions().isEmpty)
    }

    // MARK: The item

    func testOneSafeItemThatNamesWhatStays() throws {
        let box = try Sandbox()
        try makeVersions(box)
        let items = scanner(box).scanClaudeVersions()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.id, "agent.claude.versions")
        XCTAssertEqual(item.title, "Claude · old Code versions")
        XCTAssertEqual(item.tier, .safe)
        XCTAssertEqual(item.ecosystem, .aiAgents)
        XCTAssertTrue(item.bytes >= 4_000_000 && item.bytes < 5_000_000, "\(item.bytes)")
        XCTAssertTrue(item.location.contains("2 older versions") && item.location.contains("2.1.321 stays"), item.location)
        XCTAssertNotNil(AgentProduct.info(forTitle: item.title))
    }

    func testWeCannotTellWhatRunsSoThereIsNoItemAndNoRemoval() throws {
        let box = try Sandbox()
        try makeVersions(box)
        XCTAssertTrue(scanner(box, running: nil).scanClaudeVersions().isEmpty)
        let forged = Finding(id: "f", ecosystem: .aiAgents, title: "Claude · old Code versions", location: "x", bytes: 4_000_000,
                             tier: .safe, rebuild: .download, action: .agent(.removeOldClaudeVersions))
        let report = cleaner(box, running: nil).clean([forged])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        for n in ["2.1.314", "2.1.319", "2.1.321"] { XCTAssertTrue(exists(box, "\(dir)/\(n)"), n) }
    }

    // MARK: The clean

    func testACleanRemovesOnlyTheOldVersions() throws {
        let box = try Sandbox()
        try makeVersions(box)
        try box.file(".local/share/claude/settings.json", bytes: 100)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanClaudeVersions().first)
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, item.bytes)
        XCTAssertFalse(exists(box, "\(dir)/2.1.314") || exists(box, "\(dir)/2.1.319"))
        XCTAssertTrue(exists(box, "\(dir)/2.1.321"))
        XCTAssertTrue(exists(box, ".local/share/claude/settings.json"))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: box.home.appendingPathComponent(".local/bin/claude").path),
                        "The link stays")
        XCTAssertEqual(s.remainingBytes(of: item), 0)
    }

    func testAVersionThatStartedAfterTheScanStays() throws {
        let box = try Sandbox()
        try makeVersions(box)
        let item = try XCTUnwrap(scanner(box).scanClaudeVersions().first)
        let report = cleaner(box, running: [path(box, "2.1.319")]).clean([item])      // the user started 2.1.319 meanwhile
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(exists(box, "\(dir)/2.1.319"))
        XCTAssertFalse(exists(box, "\(dir)/2.1.314"))
    }

    func testTheItemIsInTheOneClickTotal() throws {
        let box = try Sandbox()
        try makeVersions(box)
        let result = ScanResult(findings: scanner(box).scanClaudeVersions(), disk: DiskUsage(total: 1, free: 1))
        XCTAssertTrue(result.reclaimable >= 4_000_000)
    }

    func testTheRealLsofSeesAnOpenFile() throws {
        // This runs the real lsof on the test Mac. A file that this test holds open must be reported, and a closed one must not.
        let box = try Sandbox()
        try makeVersions(box, ["2.1.314", "2.1.321"], link: nil)
        let open = try FileHandle(forReadingFrom: URL(fileURLWithPath: path(box, "2.1.314")))
        defer { try? open.close() }
        let seen = try XCTUnwrap(ClaudeVersions.openBinaryPaths(among: [path(box, "2.1.314"), path(box, "2.1.321")]))
        XCTAssertEqual(seen.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().lastPathComponent }, ["2.1.314"])
        XCTAssertEqual(ClaudeVersions.openBinaryPaths(among: []), [])
    }
}
