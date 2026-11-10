import XCTest
@testable import PandaCore

/// Clojure: its caches and build folders (#29). Each row has a test, and the folders next to it must stay.
final class LangClojureTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan().filter { $0.ecosystem == .clojure }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheGroupHasNames() {
        XCTAssertEqual(Ecosystem.clojure.shortName, "Clojure")
        XCTAssertEqual(Ecosystem.clojure.name, "Clojure")
    }

    func testFinds_1_target() throws {
        let box = try Sandbox()
        try box.file("Developer/app/project.clj", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/target/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, "target")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/target"))
        XCTAssertTrue(exists(box, "Developer/app/project.clj"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_1_target() throws {
        let box = try Sandbox()
        try box.file("Developer/other/target/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testFinds_2_cpcache() throws {
        let box = try Sandbox()
        try box.file("Developer/app/deps.edn", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/.cpcache/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, ".cpcache")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/.cpcache"))
        XCTAssertTrue(exists(box, "Developer/app/deps.edn"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_2_cpcache() throws {
        let box = try Sandbox()
        try box.file("Developer/other/.cpcache/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testFinds_3_shadowcljs() throws {
        let box = try Sandbox()
        try box.file("Developer/app/shadow-cljs.edn", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/.shadow-cljs/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, ".shadow-cljs")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/.shadow-cljs"))
        XCTAssertTrue(exists(box, "Developer/app/shadow-cljs.edn"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_3_shadowcljs() throws {
        let box = try Sandbox()
        try box.file("Developer/other/.shadow-cljs/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testCache_clojuregitlibslibs() throws {
        let box = try Sandbox()
        try box.file(".gitlibs/libs/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .clojure }
        XCTAssertEqual(found.map(\.id), ["clojure.gitlibs.libs:.gitlibs/libs"])
        XCTAssertEqual(found.first?.tier, .review)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".gitlibs/libs/x/data"))
    }

    func testCache_clojuregitlibsrepos() throws {
        let box = try Sandbox()
        try box.file(".gitlibs/_repos/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .clojure }
        XCTAssertEqual(found.map(\.id), ["clojure.gitlibs.repos:.gitlibs/_repos"])
        XCTAssertEqual(found.first?.tier, .review)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".gitlibs/_repos/x/data"))
    }

    func testNothingWhenTheCachesAreMissing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanCaches().filter { $0.ecosystem == .clojure }.isEmpty)
    }

    /// These folders hold installed tools, settings, or your own work. A clean of every item must leave them.
    func testNeverTouchedFolders() throws {
        let box = try Sandbox()
        for rel in [".clojure/deps.edn", ".lein/profiles.clj"] { try box.file(rel, bytes: 5_000) }
        try box.file(".gitlibs/libs", bytes: 20_000)
        try box.file(".gitlibs/_repos", bytes: 20_000)
        let s = scanner(box)
        let all = s.scanCaches().filter { $0.ecosystem == .clojure } + projects(box)
        _ = cleaner(box).clean(all)
        for rel in [".clojure/deps.edn", ".lein/profiles.clj"] { XCTAssertTrue(exists(box, rel), rel) }
    }
}
