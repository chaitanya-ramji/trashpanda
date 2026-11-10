import XCTest
@testable import PandaCore

/// R: its caches and build folders (#29). Each row has a test, and the folders next to it must stay.
final class LangRTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan().filter { $0.ecosystem == .r }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheGroupHasNames() {
        XCTAssertEqual(Ecosystem.r.shortName, "R")
        XCTAssertEqual(Ecosystem.r.name, "R")
    }

    func testCache_rrenvcache() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/org.R-project.R/R/renv/cache/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .r }
        XCTAssertEqual(found.map(\.id), ["r.renv.cache:Library/Caches/org.R-project.R/R/renv/cache"])
        XCTAssertEqual(found.first?.tier, .review)
        XCTAssertEqual(found.first?.owner, nil)
        XCTAssertEqual(found.first?.note, "Every renv project that links to it needs renv::restore() to rebuild its library.")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Library/Caches/org.R-project.R/R/renv/cache/x/data"))
    }

    func testNothingWhenTheCachesAreMissing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanCaches().filter { $0.ecosystem == .r }.isEmpty)
    }

    /// These folders hold installed tools, settings, or your own work. A clean of every item must leave them.
    func testNeverTouchedFolders() throws {
        let box = try Sandbox()
        for rel in ["Library/R/arm64/4.4/library/pkg/DESCRIPTION", "Library/Caches/org.R-project.R/R/renv/sandbox/x"] { try box.file(rel, bytes: 5_000) }
        try box.file("Library/Caches/org.R-project.R/R/renv/cache", bytes: 20_000)
        let s = scanner(box)
        let all = s.scanCaches().filter { $0.ecosystem == .r } + projects(box)
        _ = cleaner(box).clean(all)
        for rel in ["Library/R/arm64/4.4/library/pkg/DESCRIPTION", "Library/Caches/org.R-project.R/R/renv/sandbox/x"] { XCTAssertTrue(exists(box, rel), rel) }
    }
}
