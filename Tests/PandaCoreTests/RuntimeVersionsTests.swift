import XCTest
@testable import PandaCore

/// #25: old runtimes of version managers. The default, any requested version, the newest, and a running one always stay.
final class RuntimeVersionsTests: XCTestCase {
    private let mb = 1_500_000

    private func dir(_ box: Sandbox, _ rel: String) throws { try box.file("\(rel)/bin/tool", bytes: mb) }
    private func scanner(_ box: Sandbox, programs: [String] = []) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false, programPaths: { programs })
    }
    private func cleaner(_ box: Sandbox, programs: [String] = [], requests: Bool = true) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider,
                       programPaths: { programs }, runtimeRequests: requests ? { s.runtimeRequests() } : nil)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func decide(_ box: Sandbox, requests: [RuntimeVersions.Request] = [], running: [String] = []) -> RuntimeVersions.Decision {
        RuntimeVersions.decide(home: box.home, requests: requests, running: running)
    }
    private func names(_ d: RuntimeVersions.Decision, _ store: String? = nil) -> [String] {
        d.removable.filter { store == nil || $0.store.id == store }.map { "\($0.store.id):\($0.tool)/\($0.name)" }.sorted()
    }
    private func write(_ box: Sandbox, _ rel: String, _ text: String) throws {
        let url = box.home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func link(_ box: Sandbox, _ rel: String, to target: String) throws {
        let url = box.home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    // MARK: Names and files

    func testNamesAndTheMatchRules() {
        for ok in ["v20.11.0", "3.12.1", "pypy3.10-7.3.15", "stable-aarch64-apple-darwin", "17.0.9-tem", "miniconda3-latest"] { XCTAssertTrue(RuntimeVersions.isPart(ok), ok) }
        for bad in ["", ".hidden", "..", "a/b", "a b", "x\n", "-x", String(repeating: "a", count: 121)] { XCTAssertFalse(RuntimeVersions.isPart(bad), bad) }
        XCTAssertTrue(RuntimeVersions.matches(spec: "20", version: "v20.11.0"))
        XCTAssertTrue(RuntimeVersions.matches(spec: "v20.11.0", version: "20.11.0"))
        XCTAssertTrue(RuntimeVersions.matches(spec: "3.12", version: "3.12.1"))
        XCTAssertTrue(RuntimeVersions.matches(spec: "stable", version: "stable-aarch64-apple-darwin"))
        XCTAssertTrue(RuntimeVersions.matches(spec: "17.0.9-tem", version: "17.0.9-tem"))
        XCTAssertFalse(RuntimeVersions.matches(spec: "2", version: "v20.11.0"), "2 is not 20")
        XCTAssertFalse(RuntimeVersions.matches(spec: "3.1", version: "3.12.1"), "3.1 is not 3.12")
        XCTAssertFalse(RuntimeVersions.matches(spec: "", version: "3.12.1"))
    }

    func testRequestsThatWeCannotReadKeepEveryVersion() {
        for spec in ["lts/*", "lts/iron", "latest", "system", "node", "*", "20.x", "3.10.*", "^18", ">=3.9", "~1.2", "18 || 20", "<complex>", "", "current"] {
            XCTAssertTrue(RuntimeVersions.keepsAll(spec: spec, tool: "node"), spec)
        }
        for spec in ["20", "v20.11.0", "3.12.1", "17.0.9-tem", "stable-aarch64-apple-darwin"] { XCTAssertFalse(RuntimeVersions.keepsAll(spec: spec, tool: "node"), spec) }
        XCTAssertFalse(RuntimeVersions.keepsAll(spec: "stable", tool: "rust"), "A Rust channel is a folder prefix")
        XCTAssertTrue(RuntimeVersions.keepsAll(spec: "stable", tool: "node"), "For Node it is a moving alias")
    }

    func testTheFilesOfProjects() {
        func r(_ file: String, _ text: String) -> [String] { RuntimeVersions.requests(inFile: file, text: text).map { "\($0.tool):\($0.spec)" } }
        XCTAssertEqual(r(".nvmrc", "v18.19.0\n"), ["node:v18.19.0"])
        XCTAssertEqual(r(".node-version", "20\n"), ["node:20"])
        XCTAssertEqual(r(".python-version", "3.11.7\n3.12.1\n# comment\n"), ["python:3.11.7", "python:3.12.1"])
        XCTAssertEqual(r("rust-toolchain", "nightly-2024-01-01\n"), ["rust:nightly-2024-01-01"])
        XCTAssertEqual(r("rust-toolchain", "[toolchain]\nchannel = \"1.75.0\"\n"), ["rust:1.75.0"])
        XCTAssertEqual(r("rust-toolchain.toml", "[toolchain]\nchannel = \"1.70.0\"\ncomponents = [\"rustfmt\"]\n"), ["rust:1.70.0"])
        XCTAssertEqual(r("rust-toolchain.toml", "[toolchain]\nprofile = \"minimal\"\n"), ["rust:*"], "No channel: keep all")
        XCTAssertEqual(r(".tool-versions", "nodejs 18.19.0 20.11.0 # x\npython 3.12.1\n\n"), ["node:18.19.0", "node:20.11.0", "python:3.12.1"])
        XCTAssertEqual(r(".sdkmanrc", "java=17.0.9-tem\n# c\ngradle=8.5\n"), ["java:17.0.9-tem", "gradle:8.5"])
        XCTAssertEqual(r("mise.toml", "[tools]\nnode = \"20\"\npython = [\"3.11\", \"3.12\"]\ngo = { version = \"1.21\" }\n"),
                       ["node:20", "python:<complex>", "go:<complex>"])
        XCTAssertTrue(r("package.json", "{}").isEmpty)
        XCTAssertTrue(r(".nvmrc", "").isEmpty)
    }

    func testTheProjectWalkSkipsPackagesAndHiddenFolders() throws {
        let box = try Sandbox()
        try write(box, "Developer/app/.nvmrc", "18\n")
        try write(box, "Developer/app/sub/deeper/.python-version", "3.9.18\n")
        try write(box, "Developer/app/node_modules/pkg/.nvmrc", "12\n")
        try write(box, "Developer/app/.git/.nvmrc", "10\n")
        try write(box, "Developer/app/build/.nvmrc", "8\n")
        let found = RuntimeVersions.projectRequests(roots: [box.home.appendingPathComponent("Developer")]).map { "\($0.tool):\($0.spec)" }
        XCTAssertEqual(Set(found), ["node:18", "python:3.9.18"])
    }

    // MARK: The stores

    func testOnlyRealVersionFoldersAreListed() throws {
        let box = try Sandbox()
        try dir(box, ".nvm/versions/node/v18.19.0")
        try dir(box, ".nvm/versions/node/v20.11.0")
        try box.file(".nvm/versions/node/notes.txt", bytes: mb)
        try dir(box, ".nvm/versions/node/.cache")
        try link(box, ".nvm/versions/node/v99.0.0", to: box.home.appendingPathComponent(".nvm/versions/node/v18.19.0").path)
        try dir(box, ".sdkman/candidates/java/17.0.9-tem")
        try link(box, ".sdkman/candidates/java/current", to: "17.0.9-tem")
        try dir(box, ".local/share/mise/installs/python/3.12.1")
        try link(box, ".local/share/mise/installs/python/3.12", to: "3.12.1")
        let all = RuntimeVersions.stores.flatMap { RuntimeVersions.versions(in: $0, home: box.home) }.map { "\($0.store.id):\($0.tool)/\($0.name)" }.sorted()
        XCTAssertEqual(all, ["mise:python/3.12.1", "nvm:node/v18.19.0", "nvm:node/v20.11.0", "sdkman:java/17.0.9-tem"])
    }

    func testAStoreThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try dir(box, "elsewhere/v18.0.0")
        try dir(box, "elsewhere/v20.0.0")
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".nvm/versions"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".nvm/versions/node"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(decide(box).removable.isEmpty)
    }

    // MARK: Which versions stay

    func testNvmKeepsTheDefaultTheRequestedTheNewest() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v16.20.0", "v18.19.0", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v18.19.0\n")
        XCTAssertEqual(names(decide(box), "nvm"), ["nvm:node/v14.21.3", "nvm:node/v16.20.0"], "18 is the default, 20 is the newest")
        let d = decide(box, requests: [RuntimeVersions.Request(tool: "node", spec: "16")])
        XCTAssertEqual(names(d, "nvm"), ["nvm:node/v14.21.3"], "A project asks for 16")
        XCTAssertEqual(d.kept["nvm/node/v16.20.0"], "a project asks for it")
        XCTAssertEqual(d.kept["nvm/node/v18.19.0"], "default")
        XCTAssertEqual(d.kept["nvm/node/v20.11.0"], "newest")
    }

    func testAnAliasKeepsEveryVersion() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v16.20.0", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        for alias in ["lts/iron", "node", "stable", "20.x"] {
            try write(box, ".nvm/alias/default", alias)
            XCTAssertTrue(decide(box).removable.isEmpty, alias)
        }
        try write(box, ".nvm/alias/default", "v16.20.0")
        XCTAssertFalse(decide(box).removable.isEmpty)
        XCTAssertTrue(decide(box, requests: [RuntimeVersions.Request(tool: "node", spec: "lts/*")]).removable.isEmpty, "A project with an alias")
    }

    func testFnmDefaultIsTheLinkInAliases() throws {
        let box = try Sandbox()
        for v in ["v16.20.0", "v18.19.0", "v20.11.0"] { try dir(box, ".local/share/fnm/node-versions/\(v)/installation") }
        try link(box, ".local/share/fnm/aliases/default", to: "../node-versions/v16.20.0/installation")
        XCTAssertEqual(names(decide(box), "fnm"), ["fnm:node/v18.19.0"], "16 is the default, 20 is the newest")
    }

    func testPyenvKeepsTheGlobalVersionsAndIgnoresVirtualenvLinks() throws {
        let box = try Sandbox()
        for v in ["3.8.18", "3.9.18", "3.11.7", "3.12.1"] { try dir(box, ".pyenv/versions/\(v)") }
        try link(box, ".pyenv/versions/myenv", to: "3.9.18")
        try write(box, ".pyenv/version", "3.11.7\n3.9.18\n")
        XCTAssertEqual(names(decide(box), "pyenv"), ["pyenv:python/3.8.18"])
        try write(box, ".pyenv/version", "system\n")
        XCTAssertTrue(decide(box).removable.isEmpty, "system keeps everything")
    }

    func testRustupKeepsTheDefaultAndEveryOverride() throws {
        let box = try Sandbox()
        for t in ["stable-aarch64-apple-darwin", "nightly-2024-01-01-aarch64-apple-darwin", "1.70.0-aarch64-apple-darwin", "beta-aarch64-apple-darwin"] {
            try dir(box, ".rustup/toolchains/\(t)")
        }
        try write(box, ".rustup/settings.toml", "version = \"12\"\ndefault_host_triple = \"aarch64-apple-darwin\"\ndefault_toolchain = \"stable-aarch64-apple-darwin\"\n\n[overrides]\n\"/Users/x/proj\" = \"nightly-2024-01-01-aarch64-apple-darwin\"\n")
        XCTAssertEqual(names(decide(box), "rustup"), ["rustup:rust/1.70.0-aarch64-apple-darwin", "rustup:rust/beta-aarch64-apple-darwin"])
        let d = decide(box, requests: [RuntimeVersions.Request(tool: "rust", spec: "1.70.0")])
        XCTAssertEqual(names(d, "rustup"), ["rustup:rust/beta-aarch64-apple-darwin"])
        try write(box, ".rustup/settings.toml", "")
        XCTAssertEqual(decide(box).removable.count, 4, "Without a default file, nothing is known, but the cleaner still checks programs and projects")
    }

    func testSdkmanKeepsTheCurrentVersionOfEachCandidate() throws {
        let box = try Sandbox()
        for v in ["11.0.21-tem", "17.0.9-tem", "21.0.1-tem"] { try dir(box, ".sdkman/candidates/java/\(v)") }
        try link(box, ".sdkman/candidates/java/current", to: "17.0.9-tem")
        for v in ["7.6.3", "8.5"] { try dir(box, ".sdkman/candidates/gradle/\(v)") }
        try link(box, ".sdkman/candidates/gradle/current", to: "7.6.3")
        XCTAssertEqual(names(decide(box), "sdkman"), ["sdkman:java/11.0.21-tem"], "java: 17 is current and 21 is newest. gradle: 7.6.3 is current and 8.5 is newest")
    }

    func testAsdfAndMiseReadToolVersions() throws {
        let box = try Sandbox()
        for v in ["16.20.0", "18.19.0", "20.11.0"] { try dir(box, ".asdf/installs/nodejs/\(v)") }
        try write(box, ".tool-versions", "nodejs 18.19.0\n")
        XCTAssertEqual(names(decide(box), "asdf"), ["asdf:node/16.20.0"], "nodejs and node are the same tool")
        for v in ["3.9.18", "3.11.7", "3.12.1"] { try dir(box, ".local/share/mise/installs/python/\(v)") }
        try write(box, ".config/mise/config.toml", "[tools]\npython = \"3.9\"\n")
        XCTAssertEqual(names(decide(box), "mise"), ["mise:python/3.11.7"], "3.9 is read as a prefix, and 3.12.1 is the newest")
        try write(box, ".config/mise/config.toml", "[tools]\npython = [\"3.9\", \"3.11\"]\n")
        XCTAssertTrue(names(decide(box), "mise").isEmpty, "An array is not read, so every Python stays")
    }

    func testARunningProgramKeepsItsVersion() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v16.20.0", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v20.11.0")
        let node = box.home.appendingPathComponent(".nvm/versions/node/v14.21.3/bin/node").path
        XCTAssertEqual(names(decide(box), "nvm"), ["nvm:node/v14.21.3", "nvm:node/v16.20.0"])
        XCTAssertEqual(names(decide(box, running: [node]), "nvm"), ["nvm:node/v16.20.0"])
    }

    func testTheNewestIsComparedByNumber() throws {
        let box = try Sandbox()
        for v in ["v9.11.2", "v10.24.1", "v8.17.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v8.17.0")
        XCTAssertEqual(names(decide(box), "nvm"), ["nvm:node/v9.11.2"], "10 is newer than 9")
    }

    // MARK: The items

    func testEachRemovableVersionIsAReviewItem() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v16.20.0", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v20.11.0")
        let found = scanner(box).scanRuntimes()
        XCTAssertEqual(Set(found.map(\.title)), ["Node v14.21.3 (nvm)", "Node v16.20.0 (nvm)"])
        let f = try XCTUnwrap(found.first)
        XCTAssertEqual(f.tier, .review)
        XCTAssertEqual(f.ecosystem, .runtimes)
        XCTAssertNil(f.owner)
        XCTAssertTrue(f.location.contains("not the default") && f.location.contains("no scanned project asks for it") && f.location.contains("1 other version stays"), f.location)
        XCTAssertFalse(found.contains { $0.title.lowercased().contains("unused") || $0.location.lowercased().contains(" unused") })
        XCTAssertEqual(ScanResult(findings: found, disk: DiskUsage(total: 1, free: 1)).reclaimable, 0)
        XCTAssertEqual(Ecosystem.runtimes.name, "Old language runtimes")
    }

    func testAProjectInTheScannedFoldersKeepsAVersion() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v16.20.0", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v20.11.0")
        try write(box, "Developer/old-app/.nvmrc", "14\n")
        XCTAssertEqual(scanner(box).scanRuntimes().map(\.title), ["Node v16.20.0 (nvm)"])
    }

    func testNothingWhenNoManagerIsInstalled() throws {
        XCTAssertTrue(scanner(try Sandbox()).scanRuntimes().isEmpty)
    }

    // MARK: The clean

    func testACleanRemovesOnlyTheChosenVersion() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v16.20.0", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v20.11.0")
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanRuntimes().first { $0.title.contains("v14") })
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, item.bytes)
        XCTAssertFalse(exists(box, ".nvm/versions/node/v14.21.3"))
        XCTAssertTrue(exists(box, ".nvm/versions/node/v16.20.0/bin/tool") && exists(box, ".nvm/versions/node/v20.11.0/bin/tool"))
        XCTAssertTrue(exists(box, ".nvm/alias/default"))
        XCTAssertEqual(s.remainingBytes(of: item), 0)
    }

    func testTheDefaultThatChangedAfterThePreviewKeepsTheVersion() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v16.20.0", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v20.11.0")
        let item = try XCTUnwrap(scanner(box).scanRuntimes().first { $0.title.contains("v14") })
        try write(box, ".nvm/alias/default", "v14.21.3")          // the user chose it as the default meanwhile
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.skipped[0].contains("default"), report.skipped[0])
        XCTAssertTrue(exists(box, ".nvm/versions/node/v14.21.3/bin/tool"))
    }

    func testAProjectThatAppearedAfterThePreviewKeepsTheVersion() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v16.20.0", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v20.11.0")
        let item = try XCTUnwrap(scanner(box).scanRuntimes().first { $0.title.contains("v14") })
        try write(box, "Developer/new/.nvmrc", "14.21.3\n")
        XCTAssertEqual(cleaner(box).clean([item]).removed, 0)
        XCTAssertTrue(exists(box, ".nvm/versions/node/v14.21.3/bin/tool"))
    }

    func testAProgramThatStartedAfterThePreviewKeepsTheVersion() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v20.11.0")
        let item = try XCTUnwrap(scanner(box).scanRuntimes().first)
        let node = box.home.appendingPathComponent(".nvm/versions/node/v14.21.3/bin/node").path
        XCTAssertEqual(cleaner(box, programs: [node]).clean([item]).removed, 0)
        XCTAssertTrue(exists(box, ".nvm/versions/node/v14.21.3/bin/tool"))
    }

    func testWithoutAWayToReadTheProjectsNothingIsRemoved() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v20.11.0")
        let item = try XCTUnwrap(scanner(box).scanRuntimes().first)
        let report = cleaner(box, requests: false).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.skipped[0].contains("projects"), report.skipped[0])
        XCTAssertTrue(exists(box, ".nvm/versions/node/v14.21.3/bin/tool"))
    }

    func testForgedFindingsRemoveNothing() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v20.11.0")
        try box.file("Documents/keep.txt", bytes: 100)
        func forged(_ store: String, _ tool: String, _ name: String) -> Finding {
            Finding(id: name, ecosystem: .runtimes, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .download, action: .removeRuntime(storeID: store, tool: tool, name: name))
        }
        let report = cleaner(box).clean([forged("nvm", "node", "v20.11.0"), forged("nvm", "node", "../../Documents"), forged("nvm", "node", ".."), forged("nvm", "node", ""),
                                         forged("nvm", "python", "v14.21.3"), forged("nope", "node", "v14.21.3"), forged("../x", "node", "v14.21.3"), forged("nvm", "node", "a/b")])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 8)
        XCTAssertTrue(exists(box, ".nvm/versions/node/v20.11.0/bin/tool") && exists(box, ".nvm/versions/node/v14.21.3/bin/tool") && exists(box, "Documents/keep.txt"))
    }

    func testAVersionThatBecameALinkAfterThePreviewIsNotFollowed() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v20.11.0")
        try box.file("proj/precious", bytes: 100)
        let item = try XCTUnwrap(scanner(box).scanRuntimes().first)
        try FileManager.default.removeItem(at: box.home.appendingPathComponent(".nvm/versions/node/v14.21.3"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".nvm/versions/node/v14.21.3"), withDestinationURL: box.home.appendingPathComponent("proj"))
        _ = cleaner(box).clean([item])
        XCTAssertTrue(exists(box, "proj/precious"))
    }

    func testTheGuardAllowsOnlyOneVersionFolderOfFnmInApplicationSupport() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        let root = "Library/Application Support/fnm/node-versions"
        func check(_ rel: String) -> Refusal? { g.check(box.home.appendingPathComponent(rel)) }
        XCTAssertNil(check("\(root)/v20.11.0"))
        for rel in [root, "\(root)/v20.11.0/installation", "\(root)/current", "\(root)/.hidden", "Library/Application Support/fnm", "Library/Application Support/fnm/aliases",
                    "Library/Application Support/fnm/aliases/default"] { XCTAssertNotNil(check(rel), rel) }
    }

    func testFnmInApplicationSupportCanBeCleaned() throws {
        let box = try Sandbox()
        let root = "Library/Application Support/fnm"
        for v in ["v16.20.0", "v20.11.0"] { try dir(box, "\(root)/node-versions/\(v)/installation") }
        try link(box, "\(root)/aliases/default", to: "../node-versions/v20.11.0/installation")
        let item = try XCTUnwrap(scanner(box).scanRuntimes().first)
        XCTAssertEqual(cleaner(box).clean([item]).removed, 1)
        XCTAssertFalse(exists(box, "\(root)/node-versions/v16.20.0"))
        XCTAssertTrue(exists(box, "\(root)/node-versions/v20.11.0/installation/bin/tool") && exists(box, "\(root)/aliases"))
    }

    func testTheDialogKeepsTheVersionByDefault() throws {
        let box = try Sandbox()
        for v in ["v14.21.3", "v20.11.0"] { try dir(box, ".nvm/versions/node/\(v)") }
        try write(box, ".nvm/alias/default", "v20.11.0")
        let f = try XCTUnwrap(scanner(box).scanRuntimes().first)
        XCTAssertEqual(Confirmation.kind(of: f), .runtime)
        let c = Confirmation.forOne(f, staleDays: 30)
        XCTAssertEqual(c.title, "Remove this runtime version?")
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertTrue(c.footer?.contains("can still use it") == true)
    }
}
