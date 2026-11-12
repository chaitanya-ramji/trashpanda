import XCTest
@testable import PandaCore

/// Generic folder names (`lib`, `local`): the walk enters them, and lists one only when its marker file is next to it (#88).
final class MarkerOnlyNamesTests: XCTestCase {
    private func scan(_ box: Sandbox, active: [String] = []) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: active).scan()
    }
    private func names(_ found: [Finding]) -> Set<String> { Set(found.map { URL(fileURLWithPath: $0.location).lastPathComponent }) }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }

    func testProjectInsideLibIsStillFound() throws {
        let box = try Sandbox()
        try box.file("Developer/lib/app/package.json", bytes: 10)
        try box.file("Developer/lib/app/node_modules/x/y", bytes: 20_000)
        let found = scan(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.location.hasSuffix("Developer/lib/app/node_modules"), true)
    }

    func testProjectInsideLocalIsStillFound() throws {
        let box = try Sandbox()
        try box.file("Developer/local/app/package.json", bytes: 10)
        try box.file("Developer/local/app/node_modules/x/y", bytes: 20_000)
        XCTAssertEqual(scan(box).count, 1)
    }

    func testLibWithShardYmlIsListed() throws {
        let box = try Sandbox()
        try box.file("Developer/app/shard.yml", bytes: 10)
        try box.file("Developer/app/src/main.cr", bytes: 10)
        try box.file("Developer/app/lib/dep/x", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = scan(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.ecosystem, .crystal)
        XCTAssertEqual(found.first?.tier, .review, "A review item, even when the project is old")
        XCTAssertEqual(names(found), ["lib"])
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/lib"))
        XCTAssertTrue(exists(box, "Developer/app/shard.yml"))
        XCTAssertTrue(exists(box, "Developer/app/src/main.cr"))
    }

    func testLibWithoutMarkerIsNotListed() throws {
        let box = try Sandbox()
        try box.file("Developer/app/lib/dep/x", bytes: 20_000)
        XCTAssertTrue(scan(box).isEmpty)
    }

    func testLocalWithCpanfileIsListed() throws {
        let box = try Sandbox()
        try box.file("Developer/app/cpanfile", bytes: 10)
        try box.file("Developer/app/local/lib/perl5/x", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = scan(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.ecosystem, .perl)
        XCTAssertEqual(found.first?.tier, .review)
        XCTAssertEqual(names(found), ["local"])
    }

    func testLocalWithoutMarkerIsNotListed() throws {
        let box = try Sandbox()
        try box.file("Developer/app/local/lib/perl5/x", bytes: 20_000)
        XCTAssertTrue(scan(box).isEmpty)
    }

    func testMarkerOfAnotherLanguageDoesNotMatch() throws {
        let box = try Sandbox()
        try box.file("Developer/app/cpanfile", bytes: 10)
        try box.file("Developer/app/lib/x", bytes: 20_000)
        try box.file("Developer/other/shard.yml", bytes: 10)
        try box.file("Developer/other/local/x", bytes: 20_000)
        XCTAssertTrue(scan(box).isEmpty)
    }

    func testProjectInUseIsNotListed() throws {
        let box = try Sandbox()
        try box.file("Developer/app/shard.yml", bytes: 10)
        try box.file("Developer/app/lib/dep/x", bytes: 20_000)
        XCTAssertEqual(scan(box).count, 1)
        XCTAssertTrue(scan(box, active: [box.home.appendingPathComponent("Developer/app").path]).isEmpty)
    }

    func testLinkNamedLibIsNeverFollowed() throws {
        let box = try Sandbox()
        // The target holds a project, but it is outside the scan root.
        try box.file("elsewhere/proj/package.json", bytes: 10)
        try box.file("elsewhere/proj/node_modules/x/y", bytes: 20_000)
        try box.file("Developer/app/shard.yml", bytes: 10)
        try box.file("Developer/plain/readme", bytes: 10)
        let dev = box.home.appendingPathComponent("Developer")
        try FileManager.default.createSymbolicLink(at: dev.appendingPathComponent("app/lib"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        try FileManager.default.createSymbolicLink(at: dev.appendingPathComponent("plain/local"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(scan(box).isEmpty, "A link is not listed, and the walk does not enter it")
    }

    func testNestedLibInsideFoundLibIsNotListedTwice() throws {
        let box = try Sandbox()
        try box.file("Developer/app/shard.yml", bytes: 10)
        try box.file("Developer/app/lib/dep/shard.yml", bytes: 10)
        try box.file("Developer/app/lib/dep/lib/sub/x", bytes: 20_000)
        try box.file("Developer/app/lib/dep/src/y", bytes: 20_000)
        let found = scan(box)
        XCTAssertEqual(found.map { $0.location.replacingOccurrences(of: box.home.path + "/", with: "") }, ["Developer/app/lib"])
    }

    func testGenericNamesStayKnownToTheCleaner() {
        XCTAssertTrue(Catalog.isArtifactName("lib"))
        XCTAssertTrue(Catalog.isArtifactName("local"))
        XCTAssertFalse(Catalog.isSpecificArtifactName("lib"))
        XCTAssertTrue(Catalog.isSpecificArtifactName("node_modules"))
    }

    // MARK: Delete time: the marker is checked again

    private func fm() -> FileManager { FileManager.default }
    private func remove(_ box: Sandbox, _ rel: String) { try? fm().removeItem(at: box.home.appendingPathComponent(rel)) }

    private func previewed(_ box: Sandbox, project: String = "Developer/app", marker: String, folder: String) throws -> Finding {
        try box.file("\(project)/\(marker)", bytes: 10)
        try box.file("\(project)/\(folder)/dep/x", bytes: 20_000)
        box.ageProject(project, days: 90)
        let found = scan(box)
        XCTAssertEqual(found.count, 1)
        return found[0]
    }

    private func assertKept(_ report: CleanReport, _ box: Sandbox, _ rel: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(report.removed, 0, file: file, line: line)
        XCTAssertEqual(report.freed, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(report.skipped.count, 1, file: file, line: line)
        XCTAssertTrue(exists(box, rel), "the folder stays", file: file, line: line)
    }

    func testLibIsKeptWhenTheMarkerIsGone() throws {
        let box = try Sandbox()
        let f = try previewed(box, marker: "shard.yml", folder: "lib")
        remove(box, "Developer/app/shard.yml")
        assertKept(cleaner(box).clean([f]), box, "Developer/app/lib/dep/x")
    }

    func testLocalIsKeptWhenTheMarkerIsGone() throws {
        let box = try Sandbox()
        let f = try previewed(box, marker: "cpanfile", folder: "local")
        remove(box, "Developer/app/cpanfile")
        assertKept(cleaner(box).clean([f]), box, "Developer/app/local/dep/x")
    }

    func testLibIsKeptWhenTheMarkerIsOfAnotherLanguage() throws {
        let box = try Sandbox()
        let f = try previewed(box, marker: "shard.yml", folder: "lib")
        remove(box, "Developer/app/shard.yml")
        try box.file("Developer/app/cpanfile", bytes: 10)
        assertKept(cleaner(box).clean([f]), box, "Developer/app/lib/dep/x")
    }

    func testMarkerGoneBetweenMeasureAndDelete() throws {
        for (marker, folder) in [("shard.yml", "lib"), ("cpanfile", "local")] {
            let box = try Sandbox()
            let f = try previewed(box, marker: marker, folder: folder)
            let c = cleaner(box)
            var deletes = 0
            c.sizeOf = { url in
                self.remove(box, "Developer/app/\(marker)")
                return Sizer.size(of: url)
            }
            c.deleteItem = { url in deletes += 1; try FileManager.default.removeItem(at: url) }
            let report = c.clean([f])
            XCTAssertEqual(deletes, 0, folder)
            assertKept(report, box, "Developer/app/\(folder)/dep/x")
        }
    }

    func testFolderBecameALinkAfterThePreview() throws {
        for (marker, folder) in [("shard.yml", "lib"), ("cpanfile", "local")] {
            let box = try Sandbox()
            let f = try previewed(box, marker: marker, folder: folder)
            let dir = box.home.appendingPathComponent("Developer/app/\(folder)")
            let moved = box.home.appendingPathComponent("moved-\(folder)")
            try fm().moveItem(at: dir, to: moved)
            try fm().createSymbolicLink(at: dir, withDestinationURL: moved)
            assertKept(cleaner(box).clean([f]), box, "moved-\(folder)/dep/x")
        }
    }

    func testNonGenericRuleIsUnchanged() throws {
        let box = try Sandbox()
        try box.file("Developer/app/Cargo.toml", bytes: 10)
        try box.file("Developer/app/target/x", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = scan(box)
        XCTAssertEqual(found.count, 1)
        // Name-only check, as before: the marker is not read again for a specific name.
        remove(box, "Developer/app/Cargo.toml")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/target"))
    }
}
