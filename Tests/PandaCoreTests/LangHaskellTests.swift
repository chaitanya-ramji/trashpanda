import XCTest
@testable import PandaCore

/// Haskell: its caches and build folders (#29). Each row has a test, and the folders next to it must stay.
final class LangHaskellTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan().filter { $0.ecosystem == .haskell }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheGroupHasNames() {
        XCTAssertEqual(Ecosystem.haskell.shortName, "Haskell")
        XCTAssertEqual(Ecosystem.haskell.name, "Haskell")
    }

    func testFinds_1_distnewstyle() throws {
        let box = try Sandbox()
        try box.file("Developer/app/cabal.project", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/dist-newstyle/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, "dist-newstyle")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/dist-newstyle"))
        XCTAssertTrue(exists(box, "Developer/app/cabal.project"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_1_distnewstyle() throws {
        let box = try Sandbox()
        try box.file("Developer/other/dist-newstyle/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testFinds_2_stackwork() throws {
        let box = try Sandbox()
        try box.file("Developer/app/stack.yaml", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/.stack-work/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, ".stack-work")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/.stack-work"))
        XCTAssertTrue(exists(box, "Developer/app/stack.yaml"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_2_stackwork() throws {
        let box = try Sandbox()
        try box.file("Developer/other/.stack-work/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testEveryMarkerWorks() throws {
        for (folder, marker) in [("dist-newstyle", "app.cabal")] {
            let box = try Sandbox()
            try box.file("Developer/app/" + marker, bytes: 10)
            try box.file("Developer/app/" + folder + "/x/y", bytes: 20_000)
            box.ageProject("Developer/app", days: 90)
            XCTAssertEqual(projects(box).count, 1, "\(marker) next to \(folder)")
        }
    }

    func testCache_haskellcabalpackages() throws {
        let box = try Sandbox()
        try box.file(".cabal/packages/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .haskell }
        XCTAssertEqual(found.map(\.id), ["haskell.cabal.packages:.cabal/packages"])
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".cabal/packages/x/data"))
    }

    func testCache_haskellcabalxdg() throws {
        let box = try Sandbox()
        try box.file(".cache/cabal/packages/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .haskell }
        XCTAssertEqual(found.map(\.id), ["haskell.cabal.xdg:.cache/cabal/packages"])
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".cache/cabal/packages/x/data"))
    }

    func testCache_haskellghcupcache() throws {
        let box = try Sandbox()
        try box.file(".ghcup/cache/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .haskell }
        XCTAssertEqual(found.map(\.id), ["haskell.ghcup.cache:.ghcup/cache"])
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".ghcup/cache/x/data"))
    }

    func testCache_haskellstacksnapshots() throws {
        let box = try Sandbox()
        try box.file(".stack/snapshots/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .haskell }
        XCTAssertEqual(found.map(\.id), ["haskell.stack.snapshots:.stack/snapshots"])
        XCTAssertEqual(found.first?.tier, .review)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".stack/snapshots/x/data"))
    }

    func testNothingWhenTheCachesAreMissing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanCaches().filter { $0.ecosystem == .haskell }.isEmpty)
    }

    /// These folders hold installed tools, settings, or your own work. A clean of every item must leave them.
    func testNeverTouchedFolders() throws {
        let box = try Sandbox()
        for rel in [".cabal/bin/tool", ".cabal/config", ".ghcup/ghc/9.6.6/bin/ghc", ".stack/programs/x/ghc", ".cabal/store/ghc-9.6/pkg/x"] { try box.file(rel, bytes: 5_000) }
        try box.file(".cabal/packages", bytes: 20_000)
        try box.file(".cache/cabal/packages", bytes: 20_000)
        try box.file(".ghcup/cache", bytes: 20_000)
        try box.file(".stack/snapshots", bytes: 20_000)
        let s = scanner(box)
        let all = s.scanCaches().filter { $0.ecosystem == .haskell } + projects(box)
        _ = cleaner(box).clean(all)
        for rel in [".cabal/bin/tool", ".cabal/config", ".ghcup/ghc/9.6.6/bin/ghc", ".stack/programs/x/ghc", ".cabal/store/ghc-9.6/pkg/x"] { XCTAssertTrue(exists(box, rel), rel) }
    }
}
