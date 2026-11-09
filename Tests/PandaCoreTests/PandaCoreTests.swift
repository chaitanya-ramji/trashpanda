import XCTest
@testable import PandaCore

enum TestLog {
    static let url = FileManager.default.temporaryDirectory.appendingPathComponent("trashpanda-tests.log")
    static let configure: Void = { Log.fileURL = url }()
}

final class Sandbox {
    let home: URL
    init() throws {
        _ = TestLog.configure
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
        defer { Log.fileURL = TestLog.url }

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

// MARK: - Docker: act only on a local engine (#6)

/// A fake docker tool. It records every call, so a test can prove what ran.
/// It can serve one inventory before a prune and another one after it.
final class FakeDocker {
    let path: String
    private let logPath: String

    init(box: Sandbox, contextName: String, host: String,
         inventory: String = "{}", inventoryAfter: String? = nil) throws {
        path = box.home.appendingPathComponent("bin/docker").path
        logPath = box.home.appendingPathComponent("docker-calls.log").path
        let dir = (path as NSString).deletingLastPathComponent
        let before = dir + "/inventory-before.json", after = dir + "/inventory-after.json"
        let marker = dir + "/pruned"
        let script = """
        #!/bin/bash
        echo "$*" >> "\(logPath)"
        echo "ENV DOCKER_HOST=${DOCKER_HOST:-} DOCKER_CONTEXT=${DOCKER_CONTEXT:-}" >> "\(logPath)"
        if [ "$1" = "context" ] && [ "$2" = "inspect" ]; then
          echo '[{"Name":"\(contextName)","Endpoints":{"docker":{"Host":"\(host)"}}}]'
          exit 0
        fi
        case "$*" in
          *"system df -v"*)
            if [ -f "\(marker)" ]; then cat "\(after)"; else cat "\(before)"; fi
            exit 0;;
          *"system df"*) echo '{"Type":"Build Cache","Reclaimable":"2.5GB (100%)"}'; exit 0;;
          *"builder prune"*|*"image prune"*|*" rm "*|*"volume rm"*) touch "\(marker)"; exit 0;;
        esac
        exit 1
        """
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try inventory.write(toFile: before, atomically: true, encoding: .utf8)
        try (inventoryAfter ?? inventory).write(toFile: after, atomically: true, encoding: .utf8)
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    var calls: [String] {
        ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("ENV ") }
    }
    var environments: [String] {
        ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { $0.hasPrefix("ENV ") }
    }
}

final class DockerEngineTests: XCTestCase {
    private func scanner(_ box: Sandbox, _ fake: FakeDocker, socketExists: Bool = true) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false,
                    dockerPath: fake.path, isSocket: { _ in socketExists })
    }

    func testLocalOrbStackEngineIsUsedWithExplicitHost() throws {
        let box = try Sandbox()
        let socket = box.home.appendingPathComponent(".orbstack/run/docker.sock").path
        let fake = try FakeDocker(box: box, contextName: "orbstack", host: "unix://\(socket)")
        let found = scanner(box, fake).scanDocker()

        XCTAssertEqual(found.map(\.id), ["docker.buildcache"])
        XCTAssertEqual(found.first?.bytes, 2_500_000_000)
        XCTAssertEqual(found.first?.location, "Docker engine: OrbStack")
        XCTAssertTrue(fake.calls.contains("--host unix://\(socket) system df --format {{json .}}"),
                      "Every command names the engine: \(fake.calls)")
    }

    func testRemoteEnginesGetNoCommandsAtAll() throws {
        for host in ["tcp://prod.example.com:2375", "ssh://deploy@prod.example.com", "npipe:////./pipe/docker_engine"] {
            let box = try Sandbox()
            let fake = try FakeDocker(box: box, contextName: "prod", host: host)
            let s = scanner(box, fake)

            XCTAssertTrue(s.scanDocker().isEmpty, "Nothing is listed for \(host)")
            XCTAssertEqual(fake.calls, ["context inspect"], "Only the context is read for \(host)")

            // The cleaner must refuse too, even with a finding that the scan never made.
            let item = Finding(id: "docker.buildcache", ecosystem: .docker, title: "Build cache",
                               location: "Docker engine: x", bytes: 1_000_000_000, tier: .safe, rebuild: .minutes,
                               action: .owner(.dockerBuilderPrune))
            let cleaner = Cleaner(guardian: PathGuard(home: box.home), dockerEngine: { s.dockerEngine() })
            let report = cleaner.clean([item])
            XCTAssertEqual(report.removed, 0)
            XCTAssertEqual(report.freed, 0)
            XCTAssertFalse(fake.calls.contains { $0.contains("prune") }, "Nothing is deleted on \(host)")
        }
    }

    func testEnvironmentCannotRedirectTheEngine() throws {
        let box = try Sandbox()
        let socket = box.home.appendingPathComponent(".orbstack/run/docker.sock").path
        let fake = try FakeDocker(box: box, contextName: "orbstack", host: "unix://\(socket)")
        setenv("DOCKER_HOST", "tcp://prod.example.com:2375", 1)
        setenv("DOCKER_CONTEXT", "prod", 1)
        defer { unsetenv("DOCKER_HOST"); unsetenv("DOCKER_CONTEXT") }

        _ = scanner(box, fake).scanDocker()

        XCTAssertFalse(fake.environments.isEmpty)
        XCTAssertTrue(fake.environments.allSatisfy { $0 == "ENV DOCKER_HOST= DOCKER_CONTEXT=" },
                      "The tool never sees the variables: \(fake.environments)")
    }

    func testUnknownAndForeignSocketsAreRefused() throws {
        let box = try Sandbox()
        let other = "/Users/someone-else/.orbstack/run/docker.sock"
        for socket in ["/tmp/ssh-tunnel.sock", other, "\(box.home.path)/.orbstack/run/../../x.sock",
                       "\(box.home.path)/.colima/a/b/docker.sock", "relative/docker.sock"] {
            let fake = try FakeDocker(box: box, contextName: "x", host: "unix://\(socket)")
            let result = DockerEngine.detect(dockerPath: fake.path, home: box.home, isSocket: { _ in true })
            if case .success = result { XCTFail("Accepted \(socket)") }
        }
    }

    func testKnownLocalEnginesAreAccepted() throws {
        let box = try Sandbox()
        let h = box.home.path
        let cases: [(String, String)] = [
            ("\(h)/.orbstack/run/docker.sock", "OrbStack"),
            ("\(h)/.docker/run/docker.sock", "Docker Desktop"),
            ("\(h)/.colima/default/docker.sock", "Colima"),
            ("\(h)/.rd/docker.sock", "Rancher Desktop"),
            ("/var/run/docker.sock", "Docker"),
        ]
        for (socket, kind) in cases {
            let fake = try FakeDocker(box: box, contextName: "ctx", host: "unix://\(socket)")
            let result = DockerEngine.detect(dockerPath: fake.path, home: box.home, isSocket: { _ in true })
            guard case .success(let engine) = result else { return XCTFail("Refused \(socket)") }
            XCTAssertEqual(engine.kind, kind)
        }
    }

    func testStoppedEngineRunsNothingMore() throws {
        let box = try Sandbox()
        let socket = box.home.appendingPathComponent(".orbstack/run/docker.sock").path
        let fake = try FakeDocker(box: box, contextName: "orbstack", host: "unix://\(socket)")
        XCTAssertTrue(scanner(box, fake, socketExists: false).scanDocker().isEmpty)
        XCTAssertEqual(fake.calls, ["context inspect"])
    }

    func testNoDockerInstalled() throws {
        let box = try Sandbox()
        XCTAssertEqual(DockerEngine.detect(dockerPath: nil, home: box.home).failureReason, .noDocker)
    }

    func testCleanRunsPruneOnTheCheckedEngineOnly() throws {
        let box = try Sandbox()
        let socket = box.home.appendingPathComponent(".orbstack/run/docker.sock").path
        let fake = try FakeDocker(box: box, contextName: "orbstack", host: "unix://\(socket)")
        let s = scanner(box, fake)
        let finding = try XCTUnwrap(s.scanDocker().first)

        let cleaner = Cleaner(guardian: PathGuard(home: box.home), remaining: { _ in 0 },
                              dockerEngine: { s.dockerEngine() })
        let report = cleaner.clean([finding])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(fake.calls.contains("--host unix://\(socket) builder prune -f"))
    }
}

private extension Result where Failure == DockerRefusal {
    var failureReason: DockerRefusal? { if case .failure(let e) = self { return e } else { return nil } }
}

// MARK: - Stale limit setting (#4)

final class StaleLimitTests: XCTestCase {
    func testValidValuesAreRead() {
        XCTAssertEqual(Config.parseSettings("stale_days = 7").staleDays, 7)
        XCTAssertEqual(Config.parseSettings("stale_days=90\n").staleDays, 90)
        XCTAssertEqual(Config.parseSettings("# comment\n\n  stale_days =  365  \n").staleDays, 365)
        let parsed = Config.parseSettings("stale_days = 7")
        XCTAssertTrue(parsed.fromFile)
        XCTAssertTrue(parsed.warnings.isEmpty)
    }

    func testBadValuesFallBackToThirtyWithAWarning() {
        for bad in ["abc", "0", "-5", "7.5", "99999", "", "7 days"] {
            let parsed = Config.parseSettings("stale_days = \(bad)")
            XCTAssertEqual(parsed.staleDays, 30, "\"\(bad)\" falls back")
            XCTAssertFalse(parsed.fromFile)
            XCTAssertEqual(parsed.warnings.count, 1, "\"\(bad)\" warns once")
        }
        XCTAssertEqual(Config.parseSettings("").staleDays, 30)
        XCTAssertEqual(Config.parseSettings("unknown = 1").warnings.count, 1)
        XCTAssertEqual(Config.parseSettings("no equals sign").warnings.count, 1)
    }

    func testLimitChangesTheTierOfAProject() throws {
        let box = try Sandbox()
        try box.file("Developer/app/package.json", bytes: 10)
        try box.file("Developer/app/node_modules/x/i.js", bytes: 50_000)
        box.ageProject("Developer/app", days: 20)           // changed 20 days ago

        func tier(staleDays: Int) -> Tier? {
            DiskScanner(home: box.home, config: Config(staleDays: staleDays), useOwnerTools: false)
                .scanProjects().first?.tier
        }
        XCTAssertEqual(tier(staleDays: 30), .review, "20 days is recent when the limit is 30")
        XCTAssertEqual(tier(staleDays: 15), .safe, "20 days is stale when the limit is 15")
        XCTAssertEqual(tier(staleDays: 90), .review)
    }

    func testFileIsLoadedAndTheLogShowsTheValue() throws {
        let box = try Sandbox()
        Log.fileURL = box.home.appendingPathComponent("log.txt")
        defer { Log.fileURL = TestLog.url }

        try box.file(".config/trashpanda/settings", bytes: 0)
        try "stale_days = 12\n".write(to: box.home.appendingPathComponent(".config/trashpanda/settings"),
                                      atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.load(home: box.home).staleDays, 12)

        try "stale_days = banana\n".write(to: box.home.appendingPathComponent(".config/trashpanda/settings"),
                                          atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.load(home: box.home).staleDays, 30)

        let log = try String(contentsOf: Log.fileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("stale limit: 12 days (from settings file)"))
        XCTAssertTrue(log.contains("WARN  settings: stale_days \"banana\""))
        XCTAssertTrue(log.contains("stale limit: 30 days (default)"))
    }

    func testMissingFileUsesTheDefault() throws {
        let box = try Sandbox()
        XCTAssertEqual(Config.load(home: box.home).staleDays, 30)
    }
}

// MARK: - Docker: dangling images (#7)

/// Builds a `docker system df -v --format json` document for tests.
enum DockerJSON {
    static func image(_ repo: String, _ tag: String, containers: Int, unique: String, size: String = "100MB") -> String {
        """
        {"Repository":"\(repo)","Tag":"\(tag)","ID":"sha256:\(UUID().uuidString)","Size":"\(size)","SharedSize":"0B",\
        "UniqueSize":"\(unique)","Containers":"\(containers)","CreatedSince":"2 weeks ago","CreatedAt":"2026-10-23 14:21:40 +0530 IST"}
        """
    }

    static func inventory(images: [String]) -> String {
        "{\"Images\":[\(images.joined(separator: ","))],\"Containers\":[],\"Volumes\":[],\"BuildCache\":[]}"
    }
}

final class DanglingImageTests: XCTestCase {
    private let socketPath = { (box: Sandbox) in box.home.appendingPathComponent(".orbstack/run/docker.sock").path }

    private func fixture(_ box: Sandbox, before: [String], after: [String]? = nil) throws -> (FakeDocker, DiskScanner) {
        let fake = try FakeDocker(box: box, contextName: "orbstack", host: "unix://\(socketPath(box))",
                                  inventory: DockerJSON.inventory(images: before),
                                  inventoryAfter: after.map { DockerJSON.inventory(images: $0) })
        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false,
                                  dockerPath: fake.path, isSocket: { _ in true })
        return (fake, scanner)
    }

    func testOnlyUntaggedUnusedImagesCount() throws {
        let box = try Sandbox()
        let (_, scanner) = try fixture(box, before: [
            DockerJSON.image("<none>", "<none>", containers: 0, unique: "120MB"),      // counts
            DockerJSON.image("<none>", "<none>", containers: 0, unique: "30.5MB"),     // counts
            DockerJSON.image("<none>", "<none>", containers: 1, unique: "900MB"),      // a container uses it
            DockerJSON.image("app", "latest", containers: 0, unique: "500MB"),         // tagged: not dangling
            DockerJSON.image("postgres", "17", containers: 1, unique: "400MB"),        // in use
            DockerJSON.image("<none>", "latest", containers: 0, unique: "70MB"),       // has a tag
        ])
        let found = try XCTUnwrap(scanner.scanDocker().first { $0.id == "docker.images.dangling" })
        XCTAssertEqual(found.bytes, 150_500_000, "Only the two untagged, unused images, by unique size")
        XCTAssertEqual(found.tier, .safe)
        XCTAssertEqual(found.location, "Docker engine: OrbStack")
        if case .owner(.dockerImagePrune) = found.action {} else { XCTFail("Uses the owner command") }
    }

    func testNoItemWhenThereAreNone() throws {
        let box = try Sandbox()
        let (_, scanner) = try fixture(box, before: [DockerJSON.image("app", "latest", containers: 0, unique: "500MB")])
        XCTAssertNil(scanner.scanDocker().first { $0.id == "docker.images.dangling" })
    }

    func testBadOrOldOutputGivesNothingAndDoesNotCrash() throws {
        let box = try Sandbox()
        for bad in ["", "not json", "[]", "{\"Images\":\"oops\"}"] {
            let fake = try FakeDocker(box: box, contextName: "orbstack", host: "unix://\(socketPath(box))", inventory: bad)
            let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false,
                                      dockerPath: fake.path, isSocket: { _ in true })
            XCTAssertNil(scanner.scanDocker().first { $0.id == "docker.images.dangling" }, "input: \(bad)")
        }
    }

    func testCleanReportsTheMeasuredResult() throws {
        let box = try Sandbox()
        let (fake, scanner) = try fixture(box, before: [
            DockerJSON.image("<none>", "<none>", containers: 0, unique: "120MB"),
            DockerJSON.image("<none>", "<none>", containers: 0, unique: "30MB"),
            DockerJSON.image("app", "latest", containers: 0, unique: "500MB"),
        ], after: [DockerJSON.image("app", "latest", containers: 0, unique: "500MB")])

        let finding = try XCTUnwrap(scanner.scanDocker().first { $0.id == "docker.images.dangling" })
        let cleaner = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:),
                              dockerEngine: { scanner.dockerEngine() })
        let report = cleaner.clean([finding])

        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, 150_000_000)
        XCTAssertTrue(fake.calls.contains("--host unix://\(socketPath(box)) image prune -f"))
        XCTAssertFalse(fake.calls.contains { $0.contains("prune -a") || $0.contains("--all") },
                       "The tagged image stays. The app never prunes all images.")
        XCTAssertNil(scanner.scanDocker().first { $0.id == "docker.images.dangling" }, "Not listed again")
    }

    func testNewDanglingImagesAfterTheScanAreNotCountedAsFreed() throws {
        let box = try Sandbox()
        // A build makes a new untagged image after the clean. It stays, and it is not counted as freed.
        let (_, scanner) = try fixture(box, before: [
            DockerJSON.image("<none>", "<none>", containers: 0, unique: "100MB"),
        ], after: [
            DockerJSON.image("<none>", "<none>", containers: 0, unique: "40MB"),
        ])
        let finding = try XCTUnwrap(scanner.scanDocker().first { $0.id == "docker.images.dangling" })
        let report = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:),
                             dockerEngine: { scanner.dockerEngine() }).clean([finding])
        XCTAssertEqual(report.freed, 60_000_000)
    }

    func testRemoteEngineLeavesImagesAlone() throws {
        let box = try Sandbox()
        let fake = try FakeDocker(box: box, contextName: "prod", host: "tcp://prod.example.com:2375",
                                  inventory: DockerJSON.inventory(images: [
                                    DockerJSON.image("<none>", "<none>", containers: 0, unique: "120MB")]))
        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false,
                                  dockerPath: fake.path, isSocket: { _ in true })
        XCTAssertTrue(scanner.scanDocker().isEmpty)
        XCTAssertEqual(fake.calls, ["context inspect"])
    }
}
