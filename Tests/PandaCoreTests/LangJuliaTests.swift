import XCTest
@testable import PandaCore

/// Julia: its caches and build folders (#29). Each row has a test, and the folders next to it must stay.
final class LangJuliaTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan().filter { $0.ecosystem == .julia }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheGroupHasNames() {
        XCTAssertEqual(Ecosystem.julia.shortName, "Julia")
        XCTAssertEqual(Ecosystem.julia.name, "Julia")
    }

    func testCache_juliacompiled() throws {
        let box = try Sandbox()
        try box.file(".julia/compiled/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .julia }
        XCTAssertEqual(found.map(\.id), ["julia.compiled:.julia/compiled"])
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".julia/compiled/x/data"))
    }

    func testCache_juliaartifacts() throws {
        let box = try Sandbox()
        try box.file(".julia/artifacts/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .julia }
        XCTAssertEqual(found.map(\.id), ["julia.artifacts:.julia/artifacts"])
        XCTAssertEqual(found.first?.tier, .review)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".julia/artifacts/x/data"))
    }

    func testCache_juliapackages() throws {
        let box = try Sandbox()
        try box.file(".julia/packages/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .julia }
        XCTAssertEqual(found.map(\.id), ["julia.packages:.julia/packages"])
        XCTAssertEqual(found.first?.tier, .review)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".julia/packages/x/data"))
    }

    func testNothingWhenTheCachesAreMissing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanCaches().filter { $0.ecosystem == .julia }.isEmpty)
    }

    /// These folders hold installed tools, settings, or your own work. A clean of every item must leave them.
    func testNeverTouchedFolders() throws {
        let box = try Sandbox()
        for rel in [".julia/dev/MyPkg/src/x.jl", ".julia/config/startup.jl", ".julia/environments/v1.10/Project.toml", ".julia/registries/General/Registry.toml"] { try box.file(rel, bytes: 5_000) }
        try box.file(".julia/compiled", bytes: 20_000)
        try box.file(".julia/artifacts", bytes: 20_000)
        try box.file(".julia/packages", bytes: 20_000)
        let s = scanner(box)
        let all = s.scanCaches().filter { $0.ecosystem == .julia } + projects(box)
        _ = cleaner(box).clean(all)
        for rel in [".julia/dev/MyPkg/src/x.jl", ".julia/config/startup.jl", ".julia/environments/v1.10/Project.toml", ".julia/registries/General/Registry.toml"] { XCTAssertTrue(exists(box, rel), rel) }
    }
}
