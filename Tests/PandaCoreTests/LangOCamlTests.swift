import XCTest
@testable import PandaCore

/// OCaml: its caches and build folders (#29). Each row has a test, and the folders next to it must stay.
final class LangOCamlTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan().filter { $0.ecosystem == .ocaml }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheGroupHasNames() {
        XCTAssertEqual(Ecosystem.ocaml.shortName, "OCaml")
        XCTAssertEqual(Ecosystem.ocaml.name, "OCaml")
    }

    func testFinds_1__build() throws {
        let box = try Sandbox()
        try box.file("Developer/app/dune-project", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/_build/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, "_build")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/_build"))
        XCTAssertTrue(exists(box, "Developer/app/dune-project"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_1__build() throws {
        let box = try Sandbox()
        try box.file("Developer/other/_build/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testFinds_2__opam() throws {
        let box = try Sandbox()
        try box.file("Developer/app/app.opam", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/_opam/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .review)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, "_opam")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/_opam"))
        XCTAssertTrue(exists(box, "Developer/app/app.opam"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_2__opam() throws {
        let box = try Sandbox()
        try box.file("Developer/other/_opam/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testEveryMarkerWorks() throws {
        for (folder, marker) in [("_build", "dune-workspace"), ("_opam", "dune-project")] {
            let box = try Sandbox()
            try box.file("Developer/app/" + marker, bytes: 10)
            try box.file("Developer/app/" + folder + "/x/y", bytes: 20_000)
            box.ageProject("Developer/app", days: 90)
            XCTAssertEqual(projects(box).count, 1, "\(marker) next to \(folder)")
        }
    }

    func testCache_ocamldunecache() throws {
        let box = try Sandbox()
        try box.file(".cache/dune/db/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .ocaml }
        XCTAssertEqual(found.map(\.id), ["ocaml.dune.cache:.cache/dune/db"])
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".cache/dune/db/x/data"))
    }

    func testNothingWhenTheCachesAreMissing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanCaches().filter { $0.ecosystem == .ocaml }.isEmpty)
    }

    /// These folders hold installed tools, settings, or your own work. A clean of every item must leave them.
    func testNeverTouchedFolders() throws {
        let box = try Sandbox()
        for rel in [".opam/5.1.0/bin/ocaml", ".opam/config", ".config/dune/config"] { try box.file(rel, bytes: 5_000) }
        try box.file(".cache/dune/db", bytes: 20_000)
        let s = scanner(box)
        let all = s.scanCaches().filter { $0.ecosystem == .ocaml } + projects(box)
        _ = cleaner(box).clean(all)
        for rel in [".opam/5.1.0/bin/ocaml", ".opam/config", ".config/dune/config"] { XCTAssertTrue(exists(box, rel), rel) }
    }
}
