import XCTest
@testable import PandaCore

/// Fake `npm`, `pnpm`, `yarn`, and `bun`. They need no Node. Each keeps its state in a list file, prints the output of the real tool,
/// removes the package folder on a remove, records every call, and fails on a command that it does not know.
final class FakeManagers {
    let dir: URL
    let calls: URL
    private(set) var roots: [PackageManager: URL] = [:]

    init(box: Sandbox, noop: Set<PackageManager> = [], failing: Set<PackageManager> = [], only: Set<PackageManager> = Set(PackageManager.allCases)) throws {
        dir = box.home.appendingPathComponent("fakebin", isDirectory: true)
        calls = dir.appendingPathComponent("calls.log")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fm.createFile(atPath: calls.path, contents: Data())
        roots[.npm] = box.home.appendingPathComponent("npmroot")
        roots[.pnpm] = box.home.appendingPathComponent("pnpmroot")
        roots[.yarn] = box.home.appendingPathComponent("yarnroot/node_modules")
        roots[.bun] = box.home.appendingPathComponent(".bun/install/global/node_modules")
        for m in PackageManager.allCases {
            try fm.createDirectory(at: roots[m]!, withIntermediateDirectories: true)
            fm.createFile(atPath: dir.appendingPathComponent("\(m.rawValue).list").path, contents: Data())
            guard only.contains(m) else { continue }
            let list = dir.appendingPathComponent("\(m.rawValue).list").path
            let log = calls.path, root = roots[m]!.path
            let removeBody = failing.contains(m) ? "echo 'ERR! could not remove' >&2; exit 1" : (noop.contains(m) ? "exit 0" :
                "/usr/bin/grep -v \"^$name \" \"\(list)\" > \"\(list).tmp\"; /bin/mv \"\(list).tmp\" \"\(list)\"; /bin/rm -rf \"\(root)/$name\"; exit 0")
            let listing: String, rootLine: String, removeCheck: String
            switch m {
            case .npm:
                listing = #"printf '{\n  "name": "lib",\n  "dependencies": {\n'; f=1; while read n v; do [ $f = 1 ] || printf ',\n'; f=0; printf '    "%s": {"version": "%s", "overridden": false}' "$n" "$v"; done < "\#(list)"; printf '\n  }\n}\n'"#
                rootLine = #"[ "$1 $2" = "root -g" ] && { echo "\#(root)"; exit 0; }"#
                removeCheck = #"[ "$1 $2" = "uninstall -g" ] && [ "$#" = "3" ] && name="$3""#
            case .pnpm:
                listing = #"printf '[\n  {\n    "path": "/x",\n    "dependencies": {\n'; f=1; while read n v; do [ $f = 1 ] || printf ',\n'; f=0; printf '      "%s": {"from": "%s", "version": "%s"}' "$n" "$n" "$v"; done < "\#(list)"; printf '\n    }\n  }\n]\n'"#
                rootLine = #"[ "$1 $2" = "root -g" ] && { echo "\#(root)"; exit 0; }"#
                removeCheck = #"[ "$1 $2" = "remove -g" ] && [ "$#" = "3" ] && name="$3""#
            case .yarn:
                listing = #"echo 'yarn global v1.22.22'; while read n v; do echo "info \"$n@$v\" has binaries:"; echo "   - tool"; done < "\#(list)"; echo 'Done in 0.01s.'"#
                rootLine = #"[ "$1 $2" = "global dir" ] && { echo "\#((root as NSString).deletingLastPathComponent)"; exit 0; }"#
                removeCheck = #"[ "$1 $2" = "global remove" ] && [ "$#" = "3" ] && name="$3""#
            case .bun:
                listing = #"echo "/x node_modules (2)"; while read n v; do echo "├── $n@$v"; done < "\#(list)""#
                rootLine = "false"
                removeCheck = #"[ "$1 $2" = "remove -g" ] && [ "$#" = "3" ] && name="$3""#
            }
            let listCmd: String
            switch m {
            case .npm: listCmd = #"[ "$1 $2 $3 $4" = "ls -g --depth=0 --json" ]"#
            case .pnpm: listCmd = #"[ "$1 $2 $3" = "ls -g --json" ]"#
            case .yarn: listCmd = #"[ "$1 $2" = "global list" ]"#
            case .bun: listCmd = #"[ "$1 $2 $3" = "pm ls -g" ]"#
            }
            let script = """
            #!/bin/bash
            echo "\(m.rawValue) $@" >> "\(log)"
            \(listCmd) && { \(listing); exit 0; }
            \(m == .bun ? "" : rootLine)
            if \(removeCheck); then \(removeBody); fi
            echo "UNEXPECTED \(m.rawValue) $@" >> "\(log)"; exit 2
            """
            let path = dir.appendingPathComponent(m.rawValue)
            try script.write(to: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        Shell.searchDirsOverride = [dir.path]
    }

    func install(_ m: PackageManager, _ name: String, version: String = "1.0.0", bytes: Int = 2_000_000, daysAgo: Int = 100, listed: Bool = true) throws {
        let folder = name.split(separator: "/").reduce(roots[m]!) { $0.appendingPathComponent(String($1)) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: folder.appendingPathComponent("index.js"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(daysAgo) * 86_400)], ofItemAtPath: folder.path)
        if listed {
            let list = dir.appendingPathComponent("\(m.rawValue).list")
            try ((try? String(contentsOf: list, encoding: .utf8)) ?? "").appending("\(name) \(version)\n").write(to: list, atomically: true, encoding: .utf8)
        }
    }
    func setList(_ m: PackageManager, _ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("\(m.rawValue).list"), atomically: true, encoding: .utf8)
    }
    var log: [String] { ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func installed(_ m: PackageManager, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: name.split(separator: "/").reduce(roots[m]!) { $0.appendingPathComponent(String($1)) }.path)
    }
}

/// #51: global packages of npm, pnpm, Yarn, and Bun.
final class GlobalPackagesTests: XCTestCase {
    override func setUp() { super.setUp(); Shell.searchDirsOverride = ["/nonexistent"] }
    override func tearDown() { Shell.searchDirsOverride = nil; super.tearDown() }

    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func forged(_ m: PackageManager, _ name: String) -> Finding {
        Finding(id: "f:\(name)", ecosystem: .javascript, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .download, action: .globalPackage(manager: m, name: name))
    }

    // MARK: Reading the output

    func testNpmOutputOfARealMac() {
        let real = """
        {
          "name": "lib",
          "dependencies": {
            "corepack": { "version": "0.36.0", "overridden": false },
            "example-mcp": { "version": "1.5.0", "overridden": false },
            "npm": { "version": "11.20.0", "overridden": false }
          }
        }
        """
        let p = GlobalPackages.parse(.npm, real)
        XCTAssertEqual(p.map(\.name), ["corepack", "example-mcp", "npm"])
        XCTAssertEqual(p.map(\.version), ["0.36.0", "1.5.0", "11.20.0"])
        XCTAssertTrue(GlobalPackages.parse(.npm, "not json").isEmpty)
        XCTAssertTrue(GlobalPackages.parse(.npm, "{}").isEmpty)
    }

    func testOtherManagersOutput() {
        XCTAssertEqual(GlobalPackages.parse(.pnpm, #"[{"path": "/x", "dependencies": {"typescript": {"version": "5.4.0"}, "@scope/tool": {"version": "2.0.0"}}}]"#).map(\.name),
                       ["@scope/tool", "typescript"])
        XCTAssertTrue(GlobalPackages.parse(.pnpm, #"[{"path": "/x", "private": true, "dependencies": {}}]"#).isEmpty)
        let yarn = "yarn global v1.22.22\ninfo \"ruff-cli@1.2.3\" has binaries:\n   - ruff\ninfo \"@angular/cli@17.0.0\" has binaries:\n   - ng\nDone in 0.02s.\n"
        XCTAssertEqual(GlobalPackages.parse(.yarn, yarn).map { "\($0.name)@\($0.version)" }, ["ruff-cli@1.2.3", "@angular/cli@17.0.0"])
        XCTAssertTrue(GlobalPackages.parse(.yarn, "yarn global v1.22.22\nDone in 0.01s.\n").isEmpty)
        let bun = "/Users/x/.bun/install/global node_modules (2)\n├── typescript@5.4.0\n└── @scope/tool@2.0.0\n"
        XCTAssertEqual(GlobalPackages.parse(.bun, bun).map { "\($0.name)@\($0.version)" }, ["typescript@5.4.0", "@scope/tool@2.0.0"])
    }

    func testOddNamesInTheOutputAreDropped() {
        let json = #"{"dependencies": {"-rf": {"version": "1"}, "../x": {"version": "1"}, "a b": {"version": "1"}, "ok": {"version": "1"}, ".hidden": {"version": "1"}, "x;rm": {"version": "1"}}}"#
        XCTAssertEqual(GlobalPackages.parse(.npm, json).map(\.name), ["ok"])
    }

    func testNameRules() {
        for good in ["typescript", "@scope/tool", "left-pad", "a.b_c~d", "Foo", "@a/b-c", "x1"] { XCTAssertTrue(GlobalPackages.isPackageName(good), good) }
        for bad in ["", "-rf", "--force", ".x", "_x", "@scope", "@scope/", "@/x", "a/b", "@a/b/c", "a b", "x;rm", "$(x)", "../x", "x\n", "@a/-b", String(repeating: "a", count: 215)] {
            XCTAssertFalse(GlobalPackages.isPackageName(bad), "\"\(bad)\"")
        }
    }

    func testTheCommandsHaveOneFixedShape() {
        XCTAssertEqual(PackageManager.npm.removeArguments("ts"), ["uninstall", "-g", "ts"])
        XCTAssertEqual(PackageManager.pnpm.removeArguments("ts"), ["remove", "-g", "ts"])
        XCTAssertEqual(PackageManager.yarn.removeArguments("ts"), ["global", "remove", "ts"])
        XCTAssertEqual(PackageManager.bun.removeArguments("ts"), ["remove", "-g", "ts"])
        for m in PackageManager.allCases {
            XCTAssertNil(m.removeArguments("-rf"))
            XCTAssertNil(m.removeArguments("--force"))
            XCTAssertFalse((m.removeArguments("ts") ?? []).contains { $0.hasPrefix("--") || $0 == "-f" }, "No force and no other option")
        }
    }

    // MARK: The list and the items

    func testEveryManagerIsListedAndTheManagersThemselvesAreNot() throws {
        let box = try Sandbox(), fake = try FakeManagers(box: box)
        try fake.install(.npm, "example-mcp", version: "1.5.0", bytes: 3_000_000, daysAgo: 200)
        try fake.install(.npm, "npm"); try fake.install(.npm, "corepack")
        try fake.install(.pnpm, "typescript", version: "5.4.0")
        try fake.install(.pnpm, "pnpm")
        try fake.install(.yarn, "@angular/cli", version: "17.0.0")
        try fake.install(.bun, "bunx-tool")
        let found = scanner(box).scanGlobalPackages()
        XCTAssertEqual(Set(found.map(\.title)), ["Global package · example-mcp (npm)", "Global package · typescript (pnpm)", "Global package · @angular/cli (yarn)",
                                                 "Global package · bunx-tool (bun)"])
        let g = try XCTUnwrap(found.first { $0.id == "pkg.npm:example-mcp" })
        XCTAssertEqual(g.tier, .review)
        XCTAssertEqual(g.ecosystem, .javascript)
        XCTAssertTrue(g.location.contains("example-mcp@1.5.0") && g.location.contains("200 days ago"), g.location)
        XCTAssertTrue(g.note?.contains("MCP") == true)
        XCTAssertNil(g.owner)
        XCTAssertTrue(g.bytes >= 3_000_000 && g.bytes < 3_500_000, "\(g.bytes)")
        XCTAssertEqual(ScanResult(findings: found, disk: DiskUsage(total: 1, free: 1)).reclaimable, 0)
        XCTAssertFalse(found.contains { $0.title.lowercased().contains("unused") }, "No manager knows if a tool is used")
    }

    func testNothingWhenAManagerIsMissingOrFails() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanGlobalPackages().isEmpty, "No manager is installed")
        let fake = try FakeManagers(box: box, only: [.npm])
        try fake.install(.pnpm, "x", listed: true)
        XCTAssertTrue(scanner(box).scanGlobalPackages().isEmpty, "Only the folder exists, and pnpm is not installed")
    }

    func testAPackageWithoutAFolderOrWithALinkIsLeftOut() throws {
        let box = try Sandbox(), fake = try FakeManagers(box: box)
        try fake.install(.npm, "ghost", listed: true)
        try FileManager.default.removeItem(at: fake.roots[.npm]!.appendingPathComponent("ghost"))
        try box.file("elsewhere/x", bytes: 3_000_000)
        try fake.setList(.npm, ["ghost 1.0.0", "linked 1.0.0"])
        try FileManager.default.createSymbolicLink(at: fake.roots[.npm]!.appendingPathComponent("linked"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(scanner(box).scanGlobalPackages().isEmpty)
    }

    // MARK: The clean

    func testACleanRunsOnlyTheRemoveOfTheChosenPackage() throws {
        let box = try Sandbox(), fake = try FakeManagers(box: box)
        try fake.install(.npm, "example-mcp", bytes: 3_000_000)
        try fake.install(.npm, "other", bytes: 2_000_000)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanGlobalPackages().first { $0.id == "pkg.npm:example-mcp" })
        let before = fake.log.count
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(report.freed >= 3_000_000 && report.freed < 3_500_000, "\(report.freed)")
        XCTAssertFalse(fake.installed(.npm, "example-mcp"))
        XCTAssertTrue(fake.installed(.npm, "other"))
        XCTAssertEqual(fake.log.dropFirst(before).filter { $0.contains("uninstall") }, ["npm uninstall -g example-mcp"], "Exactly one remove")
        XCTAssertFalse(fake.log.dropFirst(before).contains { $0.hasPrefix("npm UNEXPECTED") || $0.contains("UNEXPECTED") })
        XCTAssertEqual(s.remainingBytes(of: item), 0)
    }

    func testEveryManagerCanRemoveAScopedPackage() throws {
        for m in PackageManager.allCases {
            let box = try Sandbox(), fake = try FakeManagers(box: box)
            try fake.install(m, "@scope/tool", bytes: 2_000_000)
            let item = try XCTUnwrap(scanner(box).scanGlobalPackages().first, m.rawValue)
            let report = cleaner(box).clean([item])
            XCTAssertEqual(report.removed, 1, m.rawValue)
            XCTAssertFalse(fake.installed(m, "@scope/tool"), m.rawValue)
            XCTAssertTrue(fake.log.contains("\(m.rawValue) \(m.removeArguments("@scope/tool")!.joined(separator: " "))"), "\(m.rawValue): \(fake.log)")
        }
    }

    func testAPackageThatIsNotListedAnyMoreIsSkipped() throws {
        let box = try Sandbox(), fake = try FakeManagers(box: box)
        try fake.install(.npm, "gone-tool")
        let item = try XCTUnwrap(scanner(box).scanGlobalPackages().first)
        try fake.setList(.npm, [])
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertFalse(fake.log.contains { $0.contains("uninstall") })
    }

    func testAToolThatSaysYesButKeepsThePackageIsAFailure() throws {
        let box = try Sandbox(), fake = try FakeManagers(box: box, noop: [.npm])
        try fake.install(.npm, "tool")
        let report = cleaner(box).clean([try XCTUnwrap(scanner(box).scanGlobalPackages().first)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertTrue(report.failed[0].contains("still installed"), report.failed[0])
    }

    func testAFailedRemoveIsNotTriedAgain() throws {
        let box = try Sandbox(), fake = try FakeManagers(box: box, failing: [.npm])
        try fake.install(.npm, "tool")
        let report = cleaner(box).clean([try XCTUnwrap(scanner(box).scanGlobalPackages().first)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(fake.log.filter { $0.contains("uninstall") }.count, 1)
        XCTAssertTrue(fake.installed(.npm, "tool"))
    }

    func testBadNamesAndManagersNeverReachATool() throws {
        let box = try Sandbox(), fake = try FakeManagers(box: box)
        try fake.install(.npm, "tool")
        let before = fake.log.count
        let report = cleaner(box).clean(["-rf", "--force", "../x", "a b", "", "npm", "corepack", "pnpm", "yarn", "node"].map { forged(.npm, $0) })
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 10)
        XCTAssertEqual(fake.log.count, before, "No tool was called")
        XCTAssertTrue(fake.installed(.npm, "tool"))
    }

    func testAMissingManagerIsSkipped() throws {
        let box = try Sandbox()
        XCTAssertEqual(cleaner(box).clean([forged(.bun, "tool")]).skipped.count, 1)
    }

    func testTheDialogWarnsAboutProgramsThatCallTheTool() throws {
        let box = try Sandbox(), fake = try FakeManagers(box: box)
        try fake.install(.npm, "tool")
        let f = try XCTUnwrap(scanner(box).scanGlobalPackages().first)
        XCTAssertEqual(Confirmation.kind(of: f), .globalPackage)
        let c = Confirmation.forOne(f, staleDays: 30)
        XCTAssertEqual(c.title, "Uninstall this global package?")
        XCTAssertEqual(c.confirmTitle, "Uninstall")
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertTrue(c.footer?.contains("MCP server") == true && c.footer?.contains("stops working") == true)
    }
}
