import XCTest
@testable import PandaCore

/// Scala: its caches and build folders (#29). Each row has a test, and the folders next to it must stay.
final class LangScalaTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan().filter { $0.ecosystem == .scala }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheGroupHasNames() {
        XCTAssertEqual(Ecosystem.scala.shortName, "Scala")
        XCTAssertEqual(Ecosystem.scala.name, "Scala")
    }

    func testFinds_1_target() throws {
        let box = try Sandbox()
        try box.file("Developer/app/build.sbt", bytes: 10)
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
        XCTAssertTrue(exists(box, "Developer/app/build.sbt"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_1_target() throws {
        let box = try Sandbox()
        try box.file("Developer/other/target/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testFinds_2_bloop() throws {
        let box = try Sandbox()
        try box.file("Developer/app/build.sbt", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/.bloop/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, ".bloop")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/.bloop"))
        XCTAssertTrue(exists(box, "Developer/app/build.sbt"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_2_bloop() throws {
        let box = try Sandbox()
        try box.file("Developer/other/.bloop/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testFinds_3_bsp() throws {
        let box = try Sandbox()
        try box.file("Developer/app/build.sbt", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/.bsp/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, ".bsp")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/.bsp"))
        XCTAssertTrue(exists(box, "Developer/app/build.sbt"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_3_bsp() throws {
        let box = try Sandbox()
        try box.file("Developer/other/.bsp/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testFinds_4_metals() throws {
        let box = try Sandbox()
        try box.file("Developer/app/build.sbt", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/.metals/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, ".metals")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/.metals"))
        XCTAssertTrue(exists(box, "Developer/app/build.sbt"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_4_metals() throws {
        let box = try Sandbox()
        try box.file("Developer/other/.metals/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testFinds_5_out() throws {
        let box = try Sandbox()
        try box.file("Developer/app/build.sc", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/out/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, "out")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/out"))
        XCTAssertTrue(exists(box, "Developer/app/build.sc"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_5_out() throws {
        let box = try Sandbox()
        try box.file("Developer/other/out/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testEveryMarkerWorks() throws {
        for (folder, marker) in [(".bloop", "build.sc"), (".bloop", "build.mill"), ("out", "build.mill")] {
            let box = try Sandbox()
            try box.file("Developer/app/" + marker, bytes: 10)
            try box.file("Developer/app/" + folder + "/x/y", bytes: 20_000)
            box.ageProject("Developer/app", days: 90)
            XCTAssertEqual(projects(box).count, 1, "\(marker) next to \(folder)")
        }
    }

    func testCache_scalacoursier() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Coursier/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .scala }
        XCTAssertEqual(found.map(\.id), ["scala.coursier:Library/Caches/Coursier"])
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Library/Caches/Coursier/x/data"))
    }

    func testCache_scalaivy() throws {
        let box = try Sandbox()
        try box.file(".ivy2/cache/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .scala }
        XCTAssertEqual(found.map(\.id), ["scala.ivy:.ivy2/cache"])
        XCTAssertEqual(found.first?.tier, .review)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".ivy2/cache/x/data"))
    }

    func testNothingWhenTheCachesAreMissing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanCaches().filter { $0.ecosystem == .scala }.isEmpty)
    }

    /// These folders hold installed tools, settings, or your own work. A clean of every item must leave them.
    func testNeverTouchedFolders() throws {
        let box = try Sandbox()
        for rel in [".ivy2/local/org/lib/ivy.xml", ".ivy2/.credentials"] { try box.file(rel, bytes: 5_000) }
        try box.file("Library/Caches/Coursier", bytes: 20_000)
        try box.file(".ivy2/cache", bytes: 20_000)
        let s = scanner(box)
        let all = s.scanCaches().filter { $0.ecosystem == .scala } + projects(box)
        _ = cleaner(box).clean(all)
        for rel in [".ivy2/local/org/lib/ivy.xml", ".ivy2/.credentials"] { XCTAssertTrue(exists(box, rel), rel) }
    }
}
