import XCTest
@testable import PandaCore

/// #68: the uv cache for agents, and the uv installs that must never be deleted.
final class UvCacheTests: XCTestCase {
    private var fakeDir: String?
    override func setUp() { super.setUp(); Shell.searchDirsOverride = ["/nonexistent"] }
    override func tearDown() { Shell.searchDirsOverride = nil; super.tearDown() }

    /// A fake `uv`. It answers `cache dir`, `cache prune` (removes the files named unused-*), and `cache clean` (removes every file),
    /// records every call, and fails on anything else. It is found through the search path of the app.
    private func installFakeUV(_ box: Sandbox, cache: String) throws -> (calls: () -> [String], dir: String) {
        let dir = box.home.appendingPathComponent("fakeuv", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let script = """
        #!/bin/bash
        echo "$@" >> "\(log.path)"
        if [ "$1 $2" = "cache dir" ] && [ "$#" = "2" ]; then echo "\(cache)"; exit 0; fi
        if [ "$1 $2" = "cache prune" ] && [ "$#" = "2" ]; then /usr/bin/find "\(cache)" -type f -name 'unused-*' -delete; exit 0; fi
        if [ "$1 $2" = "cache clean" ] && [ "$#" = "2" ]; then /usr/bin/find "\(cache)" -type f -delete; exit 0; fi
        echo "UNEXPECTED $@" >> "\(log.path)"; exit 2
        """
        let path = dir.appendingPathComponent("uv")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        Shell.searchDirsOverride = [dir.path]
        return ({ ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }, dir.path)
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func makeCache(_ box: Sandbox) throws -> String {
        try box.file(".cache/uv/wheels-v5/unused-a", bytes: 2_000_000)
        try box.file(".cache/uv/wheels-v5/used-b", bytes: 1_000_000)
        return box.home.appendingPathComponent(".cache/uv").path
    }

    // MARK: The items

    func testWithUvThereAreTwoItemsAndOnlyThePruneIsSafe() throws {
        let box = try Sandbox()
        let cache = try makeCache(box)
        _ = try installFakeUV(box, cache: cache)
        let found = scanner(box).scanUv()
        XCTAssertEqual(Set(found.map(\.id)), ["uv.cache", "uv.prune"])
        let prune = try XCTUnwrap(found.first { $0.id == "uv.prune" })
        XCTAssertEqual(prune.title, "uv · unused cache entries")
        XCTAssertEqual(prune.ecosystem, .aiAgents)
        XCTAssertEqual(prune.tier, .safe)
        XCTAssertTrue(prune.note?.contains("Up to") == true && prune.note?.contains("Claude Code") == true)
        XCTAssertNotNil(AgentProduct.info(forTitle: prune.title))
        let all = try XCTUnwrap(found.first { $0.id == "uv.cache" })
        XCTAssertEqual(all.tier, .review, "Removing everything is a deliberate choice")
        XCTAssertEqual(all.ecosystem, .python)
        let result = ScanResult(findings: found, disk: DiskUsage(total: 1, free: 1))
        XCTAssertEqual(result.reclaimable, prune.bytes, "The cache is not counted twice")
        XCTAssertEqual(result.reviewable, all.bytes)
    }

    func testWithoutUvThereIsOnlyTheFolderItem() throws {
        let box = try Sandbox()
        _ = try makeCache(box)
        let found = scanner(box).scanUv()
        XCTAssertEqual(found.map(\.id), ["uv.cache"])
        if case .removeContents = found[0].action {} else { XCTFail("Without uv the folder is cleared") }
    }

    func testNothingWhenThereIsNoCache() throws {
        let box = try Sandbox()
        _ = try installFakeUV(box, cache: box.home.appendingPathComponent(".cache/uv").path)
        XCTAssertTrue(scanner(box).scanUv().isEmpty)
    }

    // MARK: The clean

    func testPruneRunsOnlyPruneAndTheReportIsMeasured() throws {
        let box = try Sandbox()
        let cache = try makeCache(box)
        let fake = try installFakeUV(box, cache: cache)
        let prune = try XCTUnwrap(scanner(box).scanUv().first { $0.id == "uv.prune" })
        let before = fake.calls().count
        let report = cleaner(box).clean([prune])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(report.freed >= 2_000_000 && report.freed < 2_500_000, "Only the unused file is freed: \(report.freed)")
        XCTAssertEqual(Array(fake.calls().dropFirst(before)), ["cache prune"], "No clean, no force")
        XCTAssertFalse(exists(box, ".cache/uv/wheels-v5/unused-a"))
        XCTAssertTrue(exists(box, ".cache/uv/wheels-v5/used-b"))
    }

    func testCleanRunsOnlyWhenChosen() throws {
        let box = try Sandbox()
        let cache = try makeCache(box)
        let fake = try installFakeUV(box, cache: cache)
        let all = try XCTUnwrap(scanner(box).scanUv().first { $0.id == "uv.cache" })
        let before = fake.calls().count
        let report = cleaner(box).clean([all])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(Array(fake.calls().dropFirst(before)), ["cache clean"])
        XCTAssertFalse(exists(box, ".cache/uv/wheels-v5/used-b"))
    }

    func testABulkCleanOfTheSafeItemsNeverRunsClean() throws {
        let box = try Sandbox()
        let cache = try makeCache(box)
        let fake = try installFakeUV(box, cache: cache)
        let safe = scanner(box).scanUv().filter { $0.tier == .safe }
        let before = fake.calls().count
        _ = cleaner(box).clean(safe)
        XCTAssertFalse(fake.calls().dropFirst(before).contains { $0.contains("clean") })
        XCTAssertTrue(exists(box, ".cache/uv/wheels-v5/used-b"))
    }

    // MARK: The guard and the source

    func testInstalledPythonsAndToolsAreProtected() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        func check(_ rel: String) -> Refusal? { g.check(box.home.appendingPathComponent(rel)) }
        for rel in [".local/share/uv/python", ".local/share/uv/python/cpython-3.12/bin/python", ".local/share/uv/tools", ".local/share/uv/tools/ruff/bin/ruff"] {
            XCTAssertNotNil(check(rel), rel)
        }
        XCTAssertNil(check(".cache/uv/wheels-v5"))
    }

    func testAForgedFindingForTheInstalledPythonsRemovesNothing() throws {
        let box = try Sandbox()
        try box.file(".local/share/uv/python/cpython-3.12/bin/python", bytes: 2_000_000)
        try box.file(".local/share/uv/tools/ruff/bin/ruff", bytes: 2_000_000)
        for rel in [".local/share/uv/python", ".local/share/uv/tools", ".local/share/uv"] {
            let f = Finding(id: rel, ecosystem: .python, title: "x", location: rel, bytes: 1, tier: .safe, rebuild: .download,
                            action: .removeContents(box.home.appendingPathComponent(rel)))
            _ = cleaner(box).clean([f])
        }
        XCTAssertTrue(exists(box, ".local/share/uv/python/cpython-3.12/bin/python"))
        XCTAssertTrue(exists(box, ".local/share/uv/tools/ruff/bin/ruff"))
    }

    func testTheSourceNeverForcesUv() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)) where url.pathExtension == "swift" {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                XCTAssertFalse(t.contains("\"uv\"") && (t.contains("--force") || t.contains("\"-f\"")), "\(url.lastPathComponent): \(t)")
                XCTAssertFalse(t.contains("\"cache\", \"prune\"") && t.contains("--force"), "\(url.lastPathComponent): \(t)")
            }
        }
        XCTAssertEqual(OwnerCommand.uvCachePrune.arguments, ["cache", "prune"])
        XCTAssertEqual(OwnerCommand.uvCachePrune.toolName, "uv")
    }
}
