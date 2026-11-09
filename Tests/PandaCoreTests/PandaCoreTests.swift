import XCTest
@testable import PandaCore

final class Sandbox {
    let home: URL
    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("panda-\(UUID().uuidString)")
        let raw = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // Resolve once so /var and /private/var compare equal.
        home = raw.resolvingSymlinksInPath()
    }
    deinit { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }

    @discardableResult
    func file(_ rel: String, bytes: Int = 0, age days: Int = 0) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        if days > 0 { age(url, days: days) }
        return url
    }

    func age(_ url: URL, days: Int) {
        let date = Date().addingTimeInterval(-Double(days) * 86_400)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Makes a project folder look untouched for `days` days.
    func ageProject(_ rel: String, days: Int) {
        let dir = home.appendingPathComponent(rel)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            age(dir.appendingPathComponent(name), days: days)
        }
        age(dir, days: days)
    }
}

final class PathGuardTests: XCTestCase {
    func testRefusalsAndAllowances() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        let h = box.home

        XCTAssertEqual(g.check(h), .outsideHome)
        XCTAssertEqual(g.check(h.appendingPathComponent("Library")), .tooShallow)
        XCTAssertEqual(g.check(h.appendingPathComponent("Documents/a/b")), .protectedData("Documents"))
        XCTAssertEqual(g.check(h.appendingPathComponent(".ssh/keys")), .protectedData(".ssh"))
        XCTAssertEqual(g.check(h.appendingPathComponent(".yarn/berry/cache")), .protectedData(".yarn/berry"))
        XCTAssertEqual(g.check(URL(fileURLWithPath: "/usr/local/bin")), .outsideHome)
        XCTAssertEqual(g.check(URL(fileURLWithPath: "/")), .outsideHome)
        XCTAssertEqual(g.check(URL(fileURLWithPath: "/Users")), .outsideHome)
        XCTAssertNil(g.check(h.appendingPathComponent(".npm/_cacache")))
        XCTAssertNil(g.check(h.appendingPathComponent("Library/Developer/Xcode/DerivedData")))
    }

    func testDotDotCannotEscape() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        let sneaky = box.home.appendingPathComponent("Developer/../../../etc/passwd")
        XCTAssertNotNil(g.check(sneaky))
    }

    func testSymlinkLeafIsRefused() throws {
        let box = try Sandbox()
        try box.file("real/dir/file", bytes: 10)
        let link = box.home.appendingPathComponent("Developer/link")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: box.home.appendingPathComponent("real/dir"))
        XCTAssertEqual(PathGuard(home: box.home).check(link), .symlink)
    }

    func testKeepList() throws {
        let box = try Sandbox()
        let proj = box.home.appendingPathComponent("Developer/app")
        let g = PathGuard(home: box.home, keep: [proj.path])
        XCTAssertEqual(g.check(proj.appendingPathComponent("node_modules")), .kept)
        XCTAssertNotNil(g.check(box.home.appendingPathComponent("Developer")), "A parent of a kept path is refused")
        XCTAssertEqual(g.check(box.home.appendingPathComponent("Developer/app")), .kept)
        XCTAssertNil(g.check(box.home.appendingPathComponent("Developer/other/node_modules")))
    }
}

final class ProjectScannerTests: XCTestCase {
    private func scan(_ box: Sandbox, active: [String] = [], keep: [String] = []) -> [Finding] {
        let g = PathGuard(home: box.home, keep: keep)
        let root = box.home.appendingPathComponent("Developer")
        return ProjectScanner(home: box.home, roots: [root], guardian: g, activeDirectories: active).scan()
    }

    func testStaleNodeModulesIsSafeAndRecentIsReview() throws {
        let box = try Sandbox()
        try box.file("Developer/old/package.json", bytes: 10)
        try box.file("Developer/old/node_modules/x/index.js", bytes: 50_000)
        box.ageProject("Developer/old", days: 90)
        try box.file("Developer/fresh/package.json", bytes: 10)
        try box.file("Developer/fresh/node_modules/x/index.js", bytes: 50_000)

        let found = scan(box)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first { $0.location.contains("/old/") }?.tier, .safe)
        XCTAssertEqual(found.first { $0.location.contains("/fresh/") }?.tier, .review)
    }

    func testMarkerIsRequired() throws {
        let box = try Sandbox()
        try box.file("Developer/loose/node_modules/x/index.js", bytes: 50_000)
        try box.file("Developer/notcargo/target/debug/bin", bytes: 50_000)
        XCTAssertTrue(scan(box).isEmpty)
    }

    func testManyLanguages() throws {
        let box = try Sandbox()
        try box.file("Developer/rs/Cargo.toml", bytes: 5)
        try box.file("Developer/rs/target/debug/a.o", bytes: 20_000)
        try box.file("Developer/java/pom.xml", bytes: 5)
        try box.file("Developer/java/target/classes/A.class", bytes: 20_000)
        try box.file("Developer/cs/App.csproj", bytes: 5)
        try box.file("Developer/cs/obj/project.assets.json", bytes: 20_000)
        try box.file("Developer/cpp/CMakeLists.txt", bytes: 5)
        try box.file("Developer/cpp/build/CMakeCache.txt", bytes: 20_000)
        try box.file("Developer/php/composer.json", bytes: 5)
        try box.file("Developer/php/vendor/autoload.php", bytes: 20_000)
        try box.file("Developer/swift/Package.swift", bytes: 5)
        try box.file("Developer/swift/.build/debug/x", bytes: 20_000)
        try box.file("Developer/py/pyproject.toml", bytes: 5)
        try box.file("Developer/py/.venv/lib/x.py", bytes: 20_000)

        let ecosystems = Set(scan(box).map(\.ecosystem))
        XCTAssertEqual(ecosystems, [.rust, .jvm, .dotnet, .cpp, .php, .swift, .python])
    }

    func testCMakeBuildNeedsInnerMarker() throws {
        let box = try Sandbox()
        try box.file("Developer/cpp/CMakeLists.txt", bytes: 5)
        try box.file("Developer/cpp/build/README", bytes: 20_000)
        XCTAssertTrue(scan(box).isEmpty)
    }

    func testVenvIsAlwaysReview() throws {
        let box = try Sandbox()
        try box.file("Developer/py/pyproject.toml", bytes: 5)
        try box.file("Developer/py/.venv/lib/x.py", bytes: 20_000)
        box.ageProject("Developer/py", days: 200)
        XCTAssertEqual(scan(box).first?.tier, .review)
    }

    func testActiveProjectIsSkipped() throws {
        let box = try Sandbox()
        try box.file("Developer/busy/package.json", bytes: 10)
        try box.file("Developer/busy/node_modules/x/index.js", bytes: 50_000)
        box.ageProject("Developer/busy", days: 90)
        let busy = box.home.appendingPathComponent("Developer/busy").path
        XCTAssertTrue(scan(box, active: [busy + "/src"]).isEmpty)
    }

    func testKeepListHidesProject() throws {
        let box = try Sandbox()
        try box.file("Developer/app/package.json", bytes: 10)
        try box.file("Developer/app/node_modules/x/index.js", bytes: 50_000)
        let app = box.home.appendingPathComponent("Developer/app").path
        XCTAssertTrue(scan(box, keep: [app]).isEmpty)
    }

    func testNestedArtifactsAreNotCountedTwice() throws {
        let box = try Sandbox()
        try box.file("Developer/app/package.json", bytes: 10)
        try box.file("Developer/app/node_modules/dep/package.json", bytes: 10)
        try box.file("Developer/app/node_modules/dep/node_modules/x/i.js", bytes: 50_000)
        XCTAssertEqual(scan(box).count, 1)
    }

    func testHardLinkedFilesDoNotCount() throws {
        let box = try Sandbox()
        try box.file("Developer/app/package.json", bytes: 10)
        let store = try box.file("store/blob", bytes: 100_000)
        let link = box.home.appendingPathComponent("Developer/app/node_modules/.pnpm/blob")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: store, to: link)
        XCTAssertTrue(scan(box).isEmpty, "A shared file frees no space when one link goes away")
    }
}

final class CleanerTests: XCTestCase {
    func testRemovesArtifactButNotItsProject() throws {
        let box = try Sandbox()
        try box.file("Developer/app/package.json", bytes: 10)
        let nm = try box.file("Developer/app/node_modules/x/i.js", bytes: 50_000)
        let artifact = box.home.appendingPathComponent("Developer/app/node_modules")
        let finding = Finding(id: "a", ecosystem: .javascript, title: "t", location: artifact.path,
                              bytes: 50_000, tier: .safe, rebuild: .minutes, action: .removeArtifact(artifact))
        let report = Cleaner(guardian: PathGuard(home: box.home)).clean([finding])

        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nm.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("Developer/app/package.json").path))
    }

    func testRefusesNonArtifactNames() throws {
        let box = try Sandbox()
        let docs = try box.file("Developer/app/src/main.swift", bytes: 100)
        let dir = docs.deletingLastPathComponent()
        let finding = Finding(id: "a", ecosystem: .swift, title: "t", location: dir.path, bytes: 100,
                              tier: .safe, rebuild: .seconds, action: .removeArtifact(dir))
        let report = Cleaner(guardian: PathGuard(home: box.home)).clean([finding])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.path))
    }

    func testRefusesProtectedAndOutsidePaths() throws {
        let box = try Sandbox()
        let secret = try box.file("Documents/node_modules/thesis.txt", bytes: 100)
        let finding = Finding(id: "a", ecosystem: .javascript, title: "t",
                              location: secret.deletingLastPathComponent().path, bytes: 100, tier: .safe,
                              rebuild: .minutes, action: .removeArtifact(secret.deletingLastPathComponent()))
        let report = Cleaner(guardian: PathGuard(home: box.home)).clean([finding])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
    }

    func testRemoveContentsKeepsFolder() throws {
        let box = try Sandbox()
        try box.file(".npm/_cacache/a/b", bytes: 10_000)
        try box.file(".npm/_cacache/c", bytes: 10_000)
        let dir = box.home.appendingPathComponent(".npm/_cacache")
        let finding = Finding(id: "a", ecosystem: .javascript, title: "npm", location: dir.path, bytes: 20_000,
                              tier: .safe, rebuild: .download, action: .removeContents(dir))
        let report = Cleaner(guardian: PathGuard(home: box.home)).clean([finding])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 0)
        XCTAssertGreaterThan(report.freed, 0)
    }
}

final class MiscTests: XCTestCase {
    func testDockerSizeParsing() {
        XCTAssertEqual(DiskScanner.parseDockerSize("1.5GB (100%)"), 1_500_000_000)
        XCTAssertEqual(DiskScanner.parseDockerSize("512kB"), 512_000)
        XCTAssertEqual(DiskScanner.parseDockerSize("0B"), 0)
        XCTAssertNil(DiskScanner.parseDockerSize("lots"))
    }

    func testOwnerCommandsAreFixed() {
        for command in OwnerCommand.allCases {
            XCTAssertFalse(command.arguments.contains { $0.contains(" ") || $0.contains(";") })
        }
    }

    func testConfigParsing() throws {
        let box = try Sandbox()
        try box.file(".config/trashpanda/keep", bytes: 0)
        try "# comment\n~/Developer/keepme\n\n/abs/path\n".write(
            to: box.home.appendingPathComponent(".config/trashpanda/keep"), atomically: true, encoding: .utf8)
        let config = Config.load(home: box.home)
        XCTAssertEqual(config.keep, [box.home.path + "/Developer/keepme", "/abs/path"])
    }
}

final class BrewTests: XCTestCase {
    func testParsesWhatBrewWouldFree() {
        let out = "Would remove: /opt/homebrew/Cellar/foo/1.0 (10 files, 4.1MB)\n==> This operation would free approximately 12.3MB of disk space.\n"
        XCTAssertEqual(DiskScanner.parseBrewFreed(out), 12_300_000)
        XCTAssertEqual(DiskScanner.parseBrewFreed("==> This operation would free approximately 1.5GB of disk space."), 1_500_000_000)
        XCTAssertEqual(DiskScanner.parseBrewFreed("==> This operation would free approximately 800KB of disk space."), 800_000)
    }

    /// The bug that showed 46 MB again: brew keeps its own index and never removes it.
    func testNothingToFreeMeansNoItem() {
        XCTAssertEqual(DiskScanner.parseBrewFreed(""), 0)
        XCTAssertEqual(DiskScanner.parseBrewFreed("Warning: Skipping gh: most recent version 2.1 not installed\n"), 0)
    }
}

final class EndToEndTests: XCTestCase {
    func testScanCleanRescanAndLog() throws {
        let box = try Sandbox()
        Log.fileURL = box.home.appendingPathComponent("Library/Logs/TrashPanda/trashpanda.log")

        try box.file(".npm/_cacache/content/blob", bytes: 3_000_000)
        try box.file("Developer/old/package.json", bytes: 10)
        try box.file("Developer/old/node_modules/x/index.js", bytes: 4_000_000)
        box.ageProject("Developer/old", days: 90)
        try box.file("Documents/thesis.docx", bytes: 2_000_000)          // must never be touched
        let thesis = box.home.appendingPathComponent("Documents/thesis.docx")

        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let first = scanner.scan()
        XCTAssertEqual(Set(first.findings.map(\.id)).count, 2)
        XCTAssertGreaterThan(first.reclaimable, 6_900_000)
        XCTAssertEqual(first.reviewable, 0)

        let cleaner = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:))
        let report = cleaner.clean(first.findings.filter { $0.tier == .safe })
        XCTAssertEqual(report.removed, 2)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertGreaterThan(report.freed, 6_900_000)

        // The scan must now agree with the disk: nothing is left to reclaim.
        XCTAssertTrue(scanner.scan().findings.isEmpty, "A clean item must not come back in the next scan")
        XCTAssertTrue(FileManager.default.fileExists(atPath: thesis.path), "Personal files stay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("Developer/old/package.json").path))

        let log = try String(contentsOf: Log.fileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("scan start"))
        XCTAssertTrue(log.contains("found [safe]"))
        XCTAssertTrue(log.contains("clean start: 2 items"))
        XCTAssertTrue(log.contains("clean done"))
    }
}

// MARK: - Dart and Flutter (#1)

final class DartTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan()
    }

    func testFindsDartToolAndFlutterBuild() throws {
        let box = try Sandbox()
        try box.file("Developer/app/pubspec.yaml", bytes: 10)
        try box.file("Developer/app/.dart_tool/package_config.json", bytes: 20_000)
        try box.file("Developer/app/build/.last_build_id", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(Set(found.map { URL(fileURLWithPath: $0.location).lastPathComponent }), [".dart_tool", "build"])
        XCTAssertTrue(found.allSatisfy { $0.ecosystem == .dart && $0.tier == .safe })
    }

    func testMarkerAndBuildContentAreRequired() throws {
        let box = try Sandbox()
        try box.file("Developer/nopubspec/.dart_tool/x", bytes: 20_000)
        try box.file("Developer/plain/pubspec.yaml", bytes: 10)
        try box.file("Developer/plain/build/notes.txt", bytes: 20_000)   // a build folder with no Flutter output
        XCTAssertTrue(projects(box).isEmpty)
    }

    func testGlobalCachesAndProtectedTools() throws {
        let box = try Sandbox()
        try box.file(".pub-cache/hosted/pub.dev/a/lib.dart", bytes: 20_000)
        try box.file(".pub-cache/bin/melos", bytes: 100)
        try box.file(".pub-cache/global_packages/melos/pubspec.lock", bytes: 100)
        try box.file(".dartServer/.analysis-driver/index", bytes: 20_000)

        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let found = Dictionary(uniqueKeysWithValues: scanner.scanCaches().map { ($0.id, $0) })
        XCTAssertEqual(found["dart.pub.hosted:.pub-cache/hosted"]?.tier, .review)
        XCTAssertEqual(found["dart.analysis:.dartServer/.analysis-driver"]?.tier, .safe)

        let g = PathGuard(home: box.home)
        XCTAssertEqual(g.check(box.home.appendingPathComponent(".pub-cache/bin/melos")), .protectedData(".pub-cache/bin"))
        XCTAssertNotNil(g.check(box.home.appendingPathComponent(".pub-cache/global_packages/melos")))
    }
}

// MARK: - Elixir and Erlang (#2)

final class ElixirTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan()
    }

    func testFindsMixProjectFolders() throws {
        let box = try Sandbox()
        try box.file("Developer/api/mix.exs", bytes: 10)
        try box.file("Developer/api/_build/dev/lib/a.beam", bytes: 20_000)
        try box.file("Developer/api/deps/plug/mix.exs", bytes: 20_000)
        try box.file("Developer/api/.elixir_ls/build/x", bytes: 20_000)
        box.ageProject("Developer/api", days: 90)
        let found = projects(box)
        XCTAssertEqual(Set(found.map { URL(fileURLWithPath: $0.location).lastPathComponent }),
                       ["_build", "deps", ".elixir_ls"])
        XCTAssertTrue(found.allSatisfy { $0.ecosystem == .elixir && $0.tier == .safe })
    }

    func testErlangRebarProjectUsesBuildFolder() throws {
        let box = try Sandbox()
        try box.file("Developer/erl/rebar.config", bytes: 10)
        try box.file("Developer/erl/_build/default/x.beam", bytes: 20_000)
        XCTAssertEqual(projects(box).count, 1)
    }

    func testMarkerIsRequired() throws {
        let box = try Sandbox()
        try box.file("Developer/loose/_build/x", bytes: 20_000)
        try box.file("Developer/loose/deps/x", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty)
    }

    func testGlobalCachesAndProtectedTools() throws {
        let box = try Sandbox()
        try box.file(".hex/packages/hexpm/a.tar", bytes: 20_000)
        try box.file(".cache/rebar3/hex/x", bytes: 20_000)
        try box.file(".mix/archives/phx_new/ebin/x.beam", bytes: 100)
        try box.file(".hex/hex.config", bytes: 100)

        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let ids = Set(scanner.scanCaches().map(\.id))
        XCTAssertEqual(ids, ["hex.packages:.hex/packages", "rebar3.cache:.cache/rebar3"])

        let g = PathGuard(home: box.home)
        XCTAssertEqual(g.check(box.home.appendingPathComponent(".mix/archives/phx_new")), .protectedData(".mix"))
        XCTAssertEqual(g.check(box.home.appendingPathComponent(".hex/hex.config")), .protectedData(".hex/hex.config"))
    }
}

// MARK: - Zig (#3)

final class ZigTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan()
    }

    func testFindsCacheAndOutput() throws {
        let box = try Sandbox()
        try box.file("Developer/lib/build.zig", bytes: 10)
        try box.file("Developer/lib/.zig-cache/o/x", bytes: 20_000)
        try box.file("Developer/lib/zig-out/bin/app", bytes: 20_000)
        box.ageProject("Developer/lib", days: 90)
        let found = projects(box)
        XCTAssertEqual(Set(found.map { URL(fileURLWithPath: $0.location).lastPathComponent }), [".zig-cache", "zig-out"])
        XCTAssertTrue(found.allSatisfy { $0.ecosystem == .zig && $0.tier == .safe })
    }

    func testOldCacheNameAlsoWorks() throws {
        let box = try Sandbox()
        try box.file("Developer/old/build.zig", bytes: 10)
        try box.file("Developer/old/zig-cache/o/x", bytes: 20_000)
        XCTAssertEqual(projects(box).count, 1)
    }

    func testBuildZigIsRequired() throws {
        let box = try Sandbox()
        try box.file("Developer/other/zig-out/bin/app", bytes: 20_000)
        try box.file("Developer/other/.zig-cache/o/x", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty)
    }

    func testGlobalCache() throws {
        let box = try Sandbox()
        try box.file(".cache/zig/h/x", bytes: 20_000)
        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let found = scanner.scanCaches()
        XCTAssertEqual(found.map(\.id), ["zig.global:.cache/zig"])
        XCTAssertEqual(found.first?.tier, .safe)
    }
}
