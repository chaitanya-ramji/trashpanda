import XCTest
@testable import PandaCore

/// Perl: its caches and build folders (#29). Each row has a test, and the folders next to it must stay.
final class LangPerlTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan().filter { $0.ecosystem == .perl }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheGroupHasNames() {
        XCTAssertEqual(Ecosystem.perl.shortName, "Perl")
        XCTAssertEqual(Ecosystem.perl.name, "Perl")
    }

    func testFinds_1_blib() throws {
        let box = try Sandbox()
        try box.file("Developer/app/Makefile.PL", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/blib/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, "blib")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/blib"))
        XCTAssertTrue(exists(box, "Developer/app/Makefile.PL"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_1_blib() throws {
        let box = try Sandbox()
        try box.file("Developer/other/blib/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    func testEveryMarkerWorks() throws {
        for (folder, marker) in [("blib", "Build.PL"), ("blib", "dist.ini")] {
            let box = try Sandbox()
            try box.file("Developer/app/" + marker, bytes: 10)
            try box.file("Developer/app/" + folder + "/x/y", bytes: 20_000)
            box.ageProject("Developer/app", days: 90)
            XCTAssertEqual(projects(box).count, 1, "\(marker) next to \(folder)")
        }
    }

    func testCache_perlcpanmwork() throws {
        let box = try Sandbox()
        try box.file(".cpanm/work/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .perl }
        XCTAssertEqual(found.map(\.id), ["perl.cpanm.work:.cpanm/work"])
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".cpanm/work/x/data"))
    }

    func testCache_perlcpanbuild() throws {
        let box = try Sandbox()
        try box.file(".cpan/build/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .perl }
        XCTAssertEqual(found.map(\.id), ["perl.cpan.build:.cpan/build"])
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".cpan/build/x/data"))
    }

    func testCache_perlcpansources() throws {
        let box = try Sandbox()
        try box.file(".cpan/sources/x/data", bytes: 20_000)
        let found = scanner(box).scanCaches().filter { $0.ecosystem == .perl }
        XCTAssertEqual(found.map(\.id), ["perl.cpan.sources:.cpan/sources"])
        XCTAssertEqual(found.first?.tier, .safe)
        XCTAssertEqual(found.first?.owner, nil)
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".cpan/sources/x/data"))
    }

    func testNothingWhenTheCachesAreMissing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanCaches().filter { $0.ecosystem == .perl }.isEmpty)
    }

    /// These folders hold installed tools, settings, or your own work. A clean of every item must leave them.
    func testNeverTouchedFolders() throws {
        let box = try Sandbox()
        for rel in [".perlbrew/perls/perl-5.38/bin/perl", ".cpan/CPAN/MyConfig.pm"] { try box.file(rel, bytes: 5_000) }
        try box.file(".cpanm/work", bytes: 20_000)
        try box.file(".cpan/build", bytes: 20_000)
        try box.file(".cpan/sources", bytes: 20_000)
        let s = scanner(box)
        let all = s.scanCaches().filter { $0.ecosystem == .perl } + projects(box)
        _ = cleaner(box).clean(all)
        for rel in [".perlbrew/perls/perl-5.38/bin/perl", ".cpan/CPAN/MyConfig.pm"] { XCTAssertTrue(exists(box, rel), rel) }
    }
}
