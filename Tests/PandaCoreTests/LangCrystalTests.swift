import XCTest
@testable import PandaCore

/// Crystal: its caches and build folders (#29). Each row has a test, and the folders next to it must stay.
final class LangCrystalTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan().filter { $0.ecosystem == .crystal }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheGroupHasNames() {
        XCTAssertEqual(Ecosystem.crystal.shortName, "Crystal")
        XCTAssertEqual(Ecosystem.crystal.name, "Crystal")
    }

    func testCache_crystalcache() throws {
        let box = try Sandbox()
        try box.file(".cache/crystal/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .crystal }
        XCTAssertEqual(found.map(\.id), ["crystal.cache:.cache/crystal"])
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".cache/crystal/x/data"))
    }

    func testNothingWhenTheCachesAreMissing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanCaches().filter { $0.ecosystem == .crystal }.isEmpty)
    }

    /// These folders hold installed tools, settings, or your own work. A clean of every item must leave them.
    func testNeverTouchedFolders() throws {
        let box = try Sandbox()
        for rel in [".config/crystal/x"] { try box.file(rel, bytes: 5_000) }
        try box.file(".cache/crystal", bytes: 20_000)
        let s = scanner(box)
        let all = s.scanCaches().filter { $0.ecosystem == .crystal } + projects(box)
        _ = cleaner(box).clean(all)
        for rel in [".config/crystal/x"] { XCTAssertTrue(exists(box, rel), rel) }
    }
}
