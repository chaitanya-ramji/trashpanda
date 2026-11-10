import XCTest
@testable import PandaCore

/// Nim: its caches and build folders (#29). Each row has a test, and the folders next to it must stay.
final class LangNimTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan().filter { $0.ecosystem == .nim }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheGroupHasNames() {
        XCTAssertEqual(Ecosystem.nim.shortName, "Nim")
        XCTAssertEqual(Ecosystem.nim.name, "Nim")
    }

    func testFinds_1_nimcache() throws {
        let box = try Sandbox()
        try box.file("Developer/app/app.nimble", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/nimcache/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, "nimcache")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/nimcache"))
        XCTAssertTrue(exists(box, "Developer/app/app.nimble"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_1_nimcache() throws {
        let box = try Sandbox()
        try box.file("Developer/other/nimcache/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testEveryMarkerWorks() throws {
        for (folder, marker) in [("nimcache", "nim.cfg"), ("nimcache", "config.nims")] {
            let box = try Sandbox()
            try box.file("Developer/app/" + marker, bytes: 10)
            try box.file("Developer/app/" + folder + "/x/y", bytes: 20_000)
            box.ageProject("Developer/app", days: 90)
            XCTAssertEqual(projects(box).count, 1, "\(marker) next to \(folder)")
        }
    }

    func testCache_nimcache() throws {
        let box = try Sandbox()
        try box.file(".cache/nim/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .nim }
        XCTAssertEqual(found.map(\.id), ["nim.cache:.cache/nim"])
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".cache/nim/x/data"))
    }

    func testNothingWhenTheCachesAreMissing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanCaches().filter { $0.ecosystem == .nim }.isEmpty)
    }

    /// These folders hold installed tools, settings, or your own work. A clean of every item must leave them.
    func testNeverTouchedFolders() throws {
        let box = try Sandbox()
        for rel in [".nimble/bin/tool", ".nimble/pkgs2/pkg-1.0/x.nim"] { try box.file(rel, bytes: 5_000) }
        try box.file(".cache/nim", bytes: 20_000)
        let s = scanner(box)
        let all = s.scanCaches().filter { $0.ecosystem == .nim } + projects(box)
        _ = cleaner(box).clean(all)
        for rel in [".nimble/bin/tool", ".nimble/pkgs2/pkg-1.0/x.nim"] { XCTAssertTrue(exists(box, rel), rel) }
    }
}
