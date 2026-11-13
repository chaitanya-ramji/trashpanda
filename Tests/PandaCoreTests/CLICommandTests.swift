import XCTest
@testable import PandaCore

/// Step 2b of #197: the commands that only read are a pure function in PandaCore (`CLICommand.run`).
/// These tests run it end to end on a fixture home with real files, and compare every file before and after.
///
/// They call `CLICommand.run` in this process and never start the binary. A test that starts the binary (or any program that
/// uses a home folder) must build its environment with `FakeHomeEnvironment.environment(for:)`. `HOME=<temp folder>` alone does
/// NOT isolate a program on this macOS: `NSHomeDirectory()` and `homeDirectoryForCurrentUser` still return the real home folder.
/// Only `CFFIXED_USER_HOME` moves them. Set BOTH. (A source test below fails when a test file starts a program without the helper.)
final class CLICommandTests: XCTestCase {
    private let mb = 1_500_000

    // MARK: Fixture

    /// A home with safe caches, a review item, a kept item, and data that no scan may touch.
    private func makeHome() throws -> Sandbox {
        let box = try Sandbox()
        try box.file("Library/Caches/pip/data.bin", bytes: mb)                  // safe
        try box.file("Library/Caches/pip/sub/more.bin", bytes: 100)
        try box.file("Library/Caches/Yarn/data.bin", bytes: mb)                 // safe
        try box.file("Library/pnpm/store/data.bin", bytes: mb)                  // review
        try box.file("Library/Caches/node-gyp/data.bin", bytes: mb)             // on the keep list
        try box.file("Developer/app/package.json", bytes: 10)
        try box.file("Developer/app/node_modules/x/data.bin", bytes: mb)        // a build folder of a project
        try box.file("Documents/letter.txt", bytes: 100)                         // personal data
        try box.file(".ssh/id_test", bytes: 100)                                 // a secret
        // A link inside the home folder, so that the snapshot sees links too.
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches/linked"),
                                                   withDestinationURL: box.home.appendingPathComponent("Documents"))
        // Old times, so that any touch would show.
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        for case let url as URL in FileManager.default.enumerator(at: box.home, includingPropertiesForKeys: nil)! {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        return box
    }

    private func scanner(_ box: Sandbox, mode: DeleteMode = .permanent) -> DiskScanner {
        // useOwnerTools is false, so no Docker, Homebrew, simctl, and similar tool runs.
        DiskScanner(home: box.home, config: Config(keep: [box.home.path + "/Library/Caches/node-gyp"], deleteMode: mode),
                    useOwnerTools: false, programPaths: { [] }, openClaudeBinaries: { _ in [] }, appName: { _ in nil },
                    activeDirectories: { [] })
    }

    /// path -> kind, size, modification time, link target, for every file and folder below `root` (and `root`).
    private func snapshot(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        func describe(_ url: URL) -> String {
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let type = (attrs[.type] as? FileAttributeType)?.rawValue ?? "?"
            let time = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return "\(type) \(size) \(time) \(target)"
        }
        out[root.path] = describe(root)
        for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [])! {
            out[url.path] = describe(url)
        }
        return out
    }

    private struct Run {
        var result: CLIResult?
        var logs: [String]
        var scannersBuilt: Int
        var appsRead: Int
    }

    private func run(_ args: [String], _ box: Sandbox, mode: DeleteMode = .permanent,
                     apps: RunningSnapshot = RunningSnapshot(apps: [])) -> Run {
        var built = 0, read = 0
        var logs: [String] = []
        let running = RunningApps { read += 1; return apps }
        let result = CLICommand.run(arguments: ["trashpanda"] + args, scanner: { built += 1; return self.scanner(box, mode: mode) }(),
                                    runningApps: running, version: "9.9.9", log: { _, text in logs.append(text) })
        return Run(result: result, logs: logs, scannersBuilt: built, appsRead: read)
    }

    // MARK: End to end: nothing changes

    func testScanChangesNothing() throws {
        let box = try makeHome()
        let before = snapshot(box.home)
        XCTAssertGreaterThan(before.count, 15)

        let text = run(["--scan"], box)
        XCTAssertEqual(text.result?.exitCode, 0)
        XCTAssertEqual(text.result?.stderr, "")
        let out = try XCTUnwrap(text.result?.stdout)
        XCTAssertTrue(out.contains("Library/Caches/pip") || out.contains("pip"), out)
        XCTAssertTrue(out.contains("Scanned in"))
        XCTAssertFalse(out.contains("node-gyp"), "an item on the keep list is not shown")

        let json = run(["--scan", "--json"], box)
        XCTAssertEqual(json.result?.exitCode, 0)
        let jsonText = try XCTUnwrap(json.result?.stdout)
        XCTAssertEqual(jsonText.filter { $0 == "\n" }.count, 1)
        let report = try JSONDecoder().decode(ScanReport.self, from: Data(jsonText.utf8))
        XCTAssertEqual(report.schema, 1)
        XCTAssertTrue(report.findings.contains { $0.tier == "safe" })
        XCTAssertTrue(report.findings.contains { $0.tier == "review" })
        XCTAssertTrue(report.findings.allSatisfy { !$0.id.contains(box.home.path) }, "the ids hold ~, not the home folder")

        XCTAssertEqual(snapshot(box.home), before, "the scan must not add, remove, or touch any file")
    }

    func testDryRunChangesNothing() throws {
        let box = try makeHome()
        let before = snapshot(box.home)
        for args in [["--clean-safe", "--dry-run"], ["--clean-safe", "--dry-run", "--verbose"], ["--clean-safe", "--dry-run", "--json"],
                     ["--dry-run", "--clean-safe", "--json"]] {
            let r = run(args, box)
            XCTAssertEqual(r.result?.exitCode, 0, "\(args)")
            XCTAssertEqual(r.result?.stderr, "", "\(args)")
            XCTAssertEqual(r.appsRead, 1, "the dry run reads the running apps once")
            XCTAssertTrue(r.logs.last?.hasPrefix("cli end dry-run") == true)
            XCTAssertEqual(snapshot(box.home), before, "\(args) must not add, remove, or touch any file")
        }
    }

    func testDryRunContentOnTheFixtureHome() throws {
        let box = try makeHome()
        let json = try XCTUnwrap(run(["--clean-safe", "--dry-run", "--json"], box).result?.stdout)
        let report = try JSONDecoder().decode(DryRunReport.self, from: Data(json.utf8))
        func entry(_ suffix: String) -> DryRunReport.Entry? { report.findings.first { $0.base.location.hasSuffix(suffix) } }
        let pip = try XCTUnwrap(entry("Library/Caches/pip"))
        XCTAssertTrue(pip.wouldClean)
        XCTAssertTrue(pip.checkedNow)
        XCTAssertEqual(pip.skipReason, "")
        let pnpm = try XCTUnwrap(report.findings.first { $0.base.tier == "review" })
        XCTAssertFalse(pnpm.wouldClean)
        XCTAssertEqual(pnpm.skipReason, "review item")
        XCTAssertNil(entry("Library/Caches/node-gyp"), "an item on the keep list is dropped by the scan")
        XCTAssertGreaterThan(report.totals.wouldFree, 0)
        // Every item that would be cleaned is a safe item that is not blocked.
        for e in report.findings where e.wouldClean { XCTAssertEqual(e.base.tier, "safe"); XCTAssertFalse(e.base.blocked) }
        // Project use is not read by the command line (it starts no program), so a build folder says that it is read again.
        if let artifact = report.findings.first(where: { $0.base.location.hasSuffix("node_modules") }), artifact.wouldClean {
            XCTAssertTrue(artifact.checkedAtCleanTime.contains("project use is read again"))
        }
        // The text form says how many items can change at clean time.
        let text = try XCTUnwrap(run(["--clean-safe", "--dry-run"], box).result?.stdout)
        XCTAssertTrue(text.contains("can change at clean time"), text)
        XCTAssertTrue(text.hasSuffix("Nothing was deleted.\n"))
        // Trash mode shows in the output, and nothing else changes.
        let trash = try XCTUnwrap(run(["--clean-safe", "--dry-run", "--json"], box, mode: .trash).result?.stdout)
        XCTAssertTrue(trash.contains("\"deleteMode\":\"trash\""))
    }

    func testOpenOwnerAppSkipsTheItemEndToEnd() throws {
        let box = try makeHome()
        let before = snapshot(box.home)
        let open = RunningSnapshot(apps: [RunningApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")], processes: ["xcodebuild"])
        let json = try XCTUnwrap(run(["--clean-safe", "--dry-run", "--json"], box, apps: open).result?.stdout)
        let report = try JSONDecoder().decode(DryRunReport.self, from: Data(json.utf8))
        // The fixture has no Xcode item, so nothing changes in the result of the other items.
        XCTAssertTrue(report.findings.contains { $0.wouldClean })
        XCTAssertEqual(snapshot(box.home), before)
    }

    // MARK: Wrong options: exit 64, nothing runs

    func testEveryWrongOptionExits64AndRunsNothing() throws {
        let box = try makeHome()
        let before = snapshot(box.home)
        let wrong: [[String]] = [
            ["--clean-safe"], ["--clean-safe", "--json"], ["--clean-safe", "--verbose"], ["--yes", "--json"], ["--yes", "--verbose"],
            ["--clean-safe", "--yes", "--json", "--verbose"], ["--clean-safe", "--yes", "--scan"], ["--clean-safe", "--yes", "--demo"],
            ["--demo", "--clean-safe", "--yes"], ["--clean-safe", "--yes", "--write-icons", "out"], ["--clean-safe", "--yes", "--dialog"],
            ["--clean-safe", "--yes", "--submenu"], ["--clean-safe", "--yes", "--hover"], ["--clean-safe", "--yes", "--click"],
            ["--clean-safe", "--yes", "--backdrop"], ["--clean-safe", "--yes", "--version"], ["--clean-safe", "--yes", "--help"],
            ["--clean-safe", "--yes", "--nope"], ["--clean-safe", "--yes", "--dry-run", "--json"],
            ["--clean-safe", "--dry-run", "--yes"], ["--clean-safe", "--dry-run", "--yes", "--json"], ["--yes"],
            ["--yes", "--dry-run", "--clean-safe"], ["--dry-run"], ["--dry-run", "--json"], ["--dry-run", "--scan"],
            ["--dry-run", "--verbose"], ["--scan", "--clean-safe"], ["--scan", "--clean-safe", "--dry-run"],
            ["--scan", "--yes"], ["--scan", "--verbose"], ["--scan", "--json", "--verbose"], ["--json"], ["--json", "--demo"],
            ["--verbose"], ["--verbose", "--json"], ["--clean-safe", "--dry-run", "--json", "--verbose"],
            ["--clean-safe", "--dry-run", "--nope"], ["--delete"], ["--clean"], ["--scan", "--nope"], ["--demo", "--verbose"],
            ["--write-icons"], ["--write-icons", "--scan"], ["--scan", "--write-icons"], ["--write-icons", "--demo"],
            ["--demo", "--scan"], ["--demo", "dark", "--clean-safe", "--dry-run"], ["--demo", "--dry-run"],
            ["--clean-safe", "--dry-run", "--demo"], ["--demo", "--scan", "--json"],
            ["-x"], ["--clean-safe", "--dry-run", "--yes", "--verbose"],
        ]
        for args in wrong {
            let r = run(args, box)
            let result = try XCTUnwrap(r.result, "\(args) must be a command line error, not a start of the app")
            XCTAssertEqual(result.exitCode, 64, "\(args)")
            XCTAssertEqual(result.stdout, "", "\(args)")
            XCTAssertTrue(result.stderr.contains("Usage: trashpanda"), "\(args)")
            XCTAssertEqual(r.scannersBuilt, 0, "\(args) must not scan")
            XCTAssertEqual(r.appsRead, 0, "\(args) must not read the running apps")
            XCTAssertEqual(r.logs.count, 1, "\(args)")
            XCTAssertTrue(r.logs[0].hasPrefix("cli: wrong option, exit 64"), "\(args)")
        }
        XCTAssertEqual(snapshot(box.home), before)
        // The messages are clear.
        XCTAssertTrue(run(["--clean-safe"], box).result!.stderr.hasPrefix("--clean-safe needs --dry-run (a preview) or --yes (a real clean)\n"))
        XCTAssertTrue(run(["--clean-safe", "--dry-run", "--json", "--verbose"], box).result!.stderr.hasPrefix("--verbose cannot be used with --json\n"))
        XCTAssertTrue(run(["--verbose"], box).result!.stderr.hasPrefix("--verbose works only with --clean-safe --dry-run or --clean-safe --yes\n"))
        XCTAssertTrue(run(["--clean-safe", "--dry-run", "--yes"], box).result!.stderr.hasPrefix("--yes cannot be used with --dry-run\n"))
        XCTAssertTrue(run(["--yes"], box).result!.stderr.hasPrefix("--yes works only with --clean-safe\n"))
    }

    func testArgumentsThatAreNotCommandsStartTheAppAndRunNothing() throws {
        let box = try makeHome()
        for args in [[], ["--demo"], ["--demo", "dark"], ["--write-icons", "out"], ["-psn_0_1234"]] {
            let r = run(args, box)
            XCTAssertNil(r.result, "\(args)")
            XCTAssertEqual(r.scannersBuilt, 0, "\(args)")
            XCTAssertEqual(r.appsRead, 0, "\(args)")
        }
    }

    func testHelpAndVersion() throws {
        let box = try makeHome()
        let help = run(["--help"], box)
        XCTAssertEqual(help.result?.exitCode, 0)
        XCTAssertEqual(help.result?.stdout, CLICommand.usage)
        XCTAssertEqual(help.scannersBuilt, 0)
        let version = run(["--version"], box)
        XCTAssertEqual(version.result, CLIResult(stdout: "9.9.9\n", stderr: "", exitCode: 0))
        XCTAssertEqual(version.scannersBuilt, 0)
        XCTAssertTrue(CLICommand.usage.contains("--clean-safe --yes"))
        XCTAssertTrue(CLICommand.usage.contains("--verbose and --json cannot be used together"))
    }

    // MARK: Source: the read-only code has no way to delete

    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(relative), encoding: .utf8)
    }

    /// The code of a file without comments and without the text of string literals. The code inside a string interpolation
    /// `\( ... )` stays, because it runs. The reader is the one of the spawn scan (`ShellHardeningTests.codeOnly`). It knows
    /// escapes (`"\"//"`), raw strings with any number of `#` (`#"x"y"#`), multi-line strings, nested strings inside an
    /// interpolation, nested block comments, and regex literals. The earlier line-based reader did not.
    private func code(_ text: String) -> String { ShellHardeningTests.codeOnly(text) }

    /// The code of a file without comments. The text of string literals stays, between two marks (the scan for delete
    /// selectors needs it). Same reader as `code`.
    private func stripComments(_ text: String) -> String { ShellHardeningTests.codeOnly(text, keepStrings: true) }

    /// True when the code declares `name` as a whole word: `func name`, `struct name`, `enum name`, or `class name`.
    /// `func truncateText` does not declare `truncate`.
    static func declares(_ code: String, _ name: String) -> Bool {
        let pattern = #"\b(?:func|struct|enum|class)\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
        return code.range(of: pattern, options: .regularExpression) != nil
    }

    /// The files that make the plan of the read-only commands.
    private let readOnlyFiles = ["Sources/PandaCore/CLICommand.swift", "Sources/PandaCore/CleanPlan.swift",
                                 "Sources/PandaCore/CleanRules.swift", "Sources/PandaCore/ScanReport.swift"]

    /// Every name that the read-only files may call, and why it is read-only. A name that is not here fails the test.
    /// A new call needs a person to look at it and to add it with a reason.
    static let allowedCalls: [String: String] = [
        // Swift and Foundation: values and text
        "init": "a constructor of a value type", "map": "pure", "filter": "pure", "reduce": "pure", "sorted": "pure",
        "contains": "pure", "joined": "pure", "append": "adds to a local array", "split": "pure", "dropFirst": "pure",
        "hasPrefix": "pure", "hasSuffix": "pure", "padding": "pure", "max": "pure", "first": "pure", "prefix": "pure",
        "lowercased": "pure", "precomposedStringWithCanonicalMapping": "pure", "count": "pure", "isEmpty": "pure",
        "String": "builds a string", "Int": "converts a number", "Date": "reads the clock", "Data": "builds bytes in memory",
        "String.init": "builds a string", "format": "formats a string", "zip": "pure", "decode": "reads from memory",
        "encode": "writes to memory", "decoding": "reads from memory", "sortedKeys": "an option", "dropLast": "pure",
        "components": "pure", "range": "pure", "replacingOccurrences": "pure", "timeIntervalSince": "pure",
        "appendingPathComponent": "builds a path value", "deletingLastPathComponent": "builds a path value",
        "standardizedFileURL": "builds a path value", "resolvingSymlinksInPath": "reads the links of a path",
        "URL": "builds a path value", "fileURLWithPath": "builds a path value", "lastIndex": "pure", "firstIndex": "pure",
        "index": "pure", "stop": "local helper of the plan", "encodeIfPresent": "writes to memory",
        "container": "reads from memory", "nestedContainer": "reads from memory", "min": "pure", "abs": "pure",
        // Foundation: reads of the disk (no write)
        "attributesOfItem": "FileManager read", "contentsOfDirectory": "FileManager read",
        // The types and the functions of PandaCore that these files call. Each one only reads.
        "DiskScanner": "a type; the scan only reads", "scan": "the scan only reads (it never calls the Cleaner)",
        "scanner": "the scanner value", "take": "reads which apps run (the caller gives the function)", "log": "the log function of the caller",
        "ScanReport": "builds a report in memory", "DryRunReport": "builds a report in memory", "CleanPlan": "builds a plan in memory",
        "CLIResult": "a value", "CleanRules": "the shape checks that the Cleaner also calls; they only read",
        "decide": "the plan decision", "inspect": "the plan reads", "skipReason": "the plan decision", "note": "text",
        "text": "text", "json": "text", "summary": "text", "logLine": "text", "isOneClickSafe": "pure rule", "tierName": "pure",
        "id": "pure text", "currentSchema": "a number", "mode": "text of options", "isDryRun": "pure", "error": "pure", "logOptions": "pure",
        "running": "reads a snapshot in memory", "check": "PathGuard.check only reads", "string": "ByteText: text", "ByteText": "text",
        "run": "the command function itself", "usage": "text", "handles": "pure",
        "isArtifactTarget": "shape check", "isArchiveTarget": "shape check", "isDeviceSupportTarget": "shape check",
        "isSparkleTarget": "shape check", "isUpdateItemTarget": "shape check", "isBrowserCacheTarget": "shape check",
        "isOldLogTarget": "shape check", "isTestBrowserTarget": "shape check", "cacheFolder": "shape check",
        "systemCacheName": "pure", "projectInUse": "pure", "exists": "FileManager read", "isReadableFolder": "FileManager read (lists a folder)", "isPlain": "reads the links of a path",
        "isPlainPath": "reads the links of a path", "isArtifactFolder": "Catalog: reads a folder list",
        "isArchive": "pure path shape", "isDeviceSupport": "pure path shape", "isSparkleFolder": "pure path shape",
        "isInstallerPath": "pure path shape", "read": "Installers.read: reads file attributes", "staleItems": "reads folder lists",
        "targets": "BrowserCaches: reads folder lists", "browser": "table lookup", "tool": "table lookup",
        "oldVersions": "TestBrowsers: reads folder lists", "entries": "OldLogs: reads folder lists", "isTarget": "pure path shape",
        "isVersionFolder": "pure path shape", "kind": "pure path shape", "isFolderName": "pure", "catalogNames": "pure table",
        "keepReason": "pure table", "cleanedFolders": "a table", "isOneClick": "pure", "sizeText": "text", "countedBytes": "a number",
        "wouldClean": "a list", "skipped": "a list", "skipCounts": "a list",
        "isClean": "pure", "needsAPerson": "pure: reads the one list of DeleteMode", "movesFiles": "DeleteMode: a pure table of actions",
        "CLICleanEnvironment": "a value type with the options of the real clean; it does nothing by itself",
        "CLIClean": "the file of the real clean (CLIClean.swift). It has its own source tests; this file only hands the run over",
        // Log lines
        "info": "writes a log line (the log function of the caller)", "warn": "writes a log line (the log function of the caller)",
        // Types, enum cases, and properties that the regular expression sees as calls. None of them runs anything.
        "Bool": "a type", "Int64": "a type", "Equatable": "a type", "Sendable": "a type", "CodingKey": "a type", "Array": "a type",
        "Rebuild": "a type", "Entry": "a type of the report (ScanReport.Entry)", "JSONEncoder": "encodes to memory", "NSHomeDirectory": "reads the path of the home folder",
        "autoclosure": "an attribute", "self": "keyword", "nil": "keyword", "true": "keyword",
        "now": "the clock function of the caller", "findings": "a property", "base": "a property", "shape": "a closure of the plan that only reads",
        "resolvedShape": "a closure of the plan that only reads", "resolved": "a list", "shapeProblem": "a flag", "blockedReason": "a property",
        "isActionable": "a property", "would": "a local name", "verbose": "a flag", "safe": "an enum case", "trash": "an enum case",
        "action": "a property", "worktree": "an Action case that is matched, never run",
        "agent": "an Action case that is matched, never run", "removeContents": "an Action case that is matched, never run",
        "removeArtifact": "an Action case that is matched, never run", "removeArchive": "an Action case that is matched, never run",
        "removeInstaller": "an Action case that is matched, never run", "removeDeviceSupport": "an Action case that is matched, never run",
        "removeUpdateDownloads": "an Action case that is matched, never run", "removeBrowserCaches": "an Action case that is matched, never run",
        "removeOldLogs": "an Action case that is matched, never run", "removeOldTestBrowsers": "an Action case that is matched, never run",
        "removeCacheFolderContents": "an Action case that is matched, never run",
        // Control flow words that look like calls
        "if": "keyword", "guard": "keyword", "switch": "keyword", "for": "keyword", "while": "keyword", "return": "keyword",
        "case": "keyword", "let": "keyword", "var": "keyword", "func": "keyword", "in": "keyword", "where": "keyword", "else": "keyword",
        "defer": "keyword", "catch": "keyword", "try": "keyword", "get": "keyword", "set": "keyword", "enum": "keyword", "struct": "keyword",
        "public": "keyword", "static": "keyword", "private": "keyword", "extension": "keyword", "throws": "keyword",
    ]

    /// The names of the low-level modules. A call like `Darwin.remove(` goes around every Foundation check, so the read-only files
    /// may not call anything through these names, and they may not import them.
    private static let lowLevelModules: Set<String> = ["Darwin", "Glibc", "Foundation", "Swift", "System", "SystemPackage"]

    /// All the problems of one read-only file, as text. Empty means that the file is fine. The source is a parameter so that a test can
    /// give a made-up source. A made-up source is never compiled into the product and never touches a disk.
    func readOnlyProblems(_ source: String) throws -> [String] {
        var problems: [String] = []
        // `.worktree(.remove(` is an enum case that the plan matches, never calls. The one pattern is removed before the checks.
        let source = source.replacingOccurrences(of: ".worktree(.remove(", with: ".worktree(.matched")
        let text = code(source)
        let raw = stripComments(source)
        // 1. Every call name is in the allow-list. A qualified call is also read with its qualifier.
        let regex = try NSRegularExpression(pattern: #"\b((?:[A-Za-z_][A-Za-z0-9_]*\s*\.\s*)*)([A-Za-z_][A-Za-z0-9_]*)\s*[(\{]"#)
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let qualifier = String(text[Range(m.range(at: 1), in: text)!]).replacingOccurrences(of: " ", with: "")
            let name = String(text[Range(m.range(at: 2), in: text)!])
            let first = qualifier.split(separator: ".").first.map(String.init) ?? ""
            if Self.lowLevelModules.contains(first) { problems.append("low-level call \(qualifier)\(name)"); continue }
            // A name that the file declares itself is the code of that file, but only for a call without a qualifier. A declared
            // overload (for example `exists`) must not hide a qualified call.
            // The name must be declared as a WHOLE word: `func truncateText` must not hide a call to `truncate`.
            let declared = Self.declares(text, name) || name == "init"
            if qualifier.isEmpty && declared { continue }
            if Self.allowedCalls[name] == nil { problems.append("call not in the allow-list: \(qualifier)\(name)") }
        }
        // 2. No import of a low-level module.
        if text.range(of: #"\bimport\s+(Darwin|Glibc|System|SystemPackage)\b"#, options: .regularExpression) != nil {
            problems.append("imports a low-level module")
        }
        // 3. No forbidden word at all (there is no allow-list for the read-only files), in the code and in the raw text.
        for word in Self.forbiddenReadOnlyWords where text.contains(word) { problems.append("contains \(word)") }
        problems += Self.dangerHits(source, words: Self.dangers).map { "contains \($0)" }
        problems += Self.rawHits(raw).map { "contains the selector \($0)" }
        // 4. The FileManager is used only through read methods.
        let fm = try NSRegularExpression(pattern: #"FileManager\.default\.([A-Za-z]+)"#)
        let readMethods: Set<String> = ["attributesOfItem", "contentsOfDirectory", "fileExists"]
        for m in fm.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(m.range(at: 1), in: text)!])
            if !readMethods.contains(name) { problems.append("calls FileManager.\(name)") }
        }
        return problems
    }

    static let forbiddenReadOnlyWords = ["Cleaner", "Shell", "Process", "removeItem", "trashItem", "unlink", "moveItem", "copyItem", "replaceItem",
                                         "createFile", "createDirectory", "createSymbolicLink", "createLink", "setAttributes", "linkItem",
                                         "FileHandle", "NSWorkspace", "recycle", "TrashMover", "TrashBin", "deleteItem", "dispose", "Docker",
                                         "Simctl", "Brew", "write(to", "write(", "performDelete", "OwnerCommand", "ownerRunner"]

    func testReadOnlyFilesCallOnlyAllowedFunctions() throws {
        var found: [String: [String]] = [:]
        for file in readOnlyFiles {
            let problems = try readOnlyProblems(try source(file)).filter { $0.hasPrefix("call not") || $0.hasPrefix("low-level") || $0.hasPrefix("imports") }
            if !problems.isEmpty { found[file] = problems }
        }
        XCTAssertTrue(found.isEmpty, "These calls are not in the allow-list. Check that each one is read-only, then add it with a reason: \(found)")
    }

    func testReadOnlyFilesDoNotReferenceTheCleanerOrAToolRunner() throws {
        for file in readOnlyFiles {
            let problems = try readOnlyProblems(try source(file))
            XCTAssertEqual(problems, [], "\(file)")
        }
        // main.swift is thin: it calls the command, writes the result, and exits. It has no scan, plan, or delete code.
        let main = code(try source("Sources/TrashPanda/main.swift"))
        XCTAssertTrue(main.contains("CLICommand.run("))
        for word in ["Cleaner", "CleanPlan", "DryRunReport", "ScanReport", "removeItem", "trashItem", "Shell", "\"--yes\"", "\"--dry-run\""] {
            XCTAssertFalse(main.contains(word), "main.swift must not contain \(word)")
        }
    }

    // MARK: Source: the words that delete, move, or start a program

    /// A word that only a few files of PandaCore may contain. `pattern` is a regular expression for the code (comments and the text of
    /// string literals are removed). A word that stands for a call with a name is matched even when another function has the same name.
    struct Danger: Equatable {
        let name: String
        let pattern: String
    }

    static let dangers: [Danger] = [
        // Delete, move, and link calls of Foundation and of libc
        Danger(name: "removeItem", pattern: #"removeItem"#), Danger(name: "trashItem", pattern: #"trashItem"#),
        Danger(name: "moveItem", pattern: #"(?<![A-Za-z0-9_])moveItem"#), Danger(name: "replaceItem", pattern: #"replaceItem"#),
        Danger(name: "copyItem", pattern: #"copyItem"#), Danger(name: "createSymbolicLink", pattern: #"createSymbolicLink"#),
        Danger(name: "setAttributes", pattern: #"setAttributes"#), Danger(name: "write(to", pattern: #"\bwrite\s*\(\s*to\b"#),
        Danger(name: "unlink", pattern: #"\bunlink\w*"#), Danger(name: "unlinkat", pattern: #"\bunlinkat\b"#),
        Danger(name: "removefile", pattern: #"(?i)\bremovefile"#), Danger(name: "remove(", pattern: #"\bremove\s*\("#),
        Danger(name: "rmdir", pattern: #"\brmdir\b"#), Danger(name: "rename", pattern: #"\brename\s*\("#),
        Danger(name: "renamex", pattern: #"\brenamex\w*"#), Danger(name: "renameat", pattern: #"\brenameat\w*"#),
        // More ways to write, copy, clone, or cut a file (added after the review of step 2c)
        Danger(name: "write(toFile", pattern: #"\bwrite\s*\(\s*toFile\b"#), Danger(name: "createFile", pattern: #"\bcreateFile\b"#),
        Danger(name: "clonefile", pattern: #"\bf?clonefile\w*"#), Danger(name: "copyfile", pattern: #"\bf?copyfile\w*"#),
        Danger(name: "exchangedata", pattern: #"\bexchangedata\b"#), Danger(name: "truncate", pattern: #"\bf?truncate\s*\("#),
        Danger(name: "fopen", pattern: #"\bf(?:re)?open\s*\("#), Danger(name: "forWritingTo", pattern: #"\bforWritingTo\b"#),
        Danger(name: "NSFileCoordinator", pattern: #"NSFileCoordinator"#), Danger(name: "dlsym", pattern: #"\bdlsym\b"#),
        // A call to libc through its module name goes around every check of Foundation
        Danger(name: "Darwin./Glibc.", pattern: #"\b(Darwin|Glibc)\s*\."#),
        Danger(name: "Foundation.<call>", pattern: #"\bFoundation\s*\.\s*\w+\s*\("#),
        // A call by a name that is made at run time
        Danger(name: "NSSelectorFromString", pattern: #"NSSelectorFromString"#), Danger(name: "perform(", pattern: #"\bperform\s*\("#),
        // Start of a program
        Danger(name: "Process(", pattern: #"\bProcess\s*\("#), Danger(name: "Process.init", pattern: #"\bProcess\s*\.\s*init\b"#),
        Danger(name: "posix_spawn", pattern: #"posix_spawn"#), Danger(name: "system(", pattern: #"\bsystem\s*\("#),
        Danger(name: "popen", pattern: #"\bpopen\b"#), Danger(name: "exec", pattern: #"\bexec\w*\s*\("#),
        Danger(name: "NSTask", pattern: #"NSTask"#),
    ]

    /// Delete selectors that are searched in the raw text, WITH the text of string literals (`perform(NSSelectorFromString("..."))`
    /// hides the name in a string). A match is a problem in every file: no file of PandaCore needs one.
    static let rawSelectors = ["removeItemAtPath", "removeItemAtURL", "trashItemAtURL", "unlink"]

    /// The names of the dangers that a source contains. `source` is raw: comments and string literals are handled here.
    static func dangerHits(_ source: String, words: [Danger]) -> Set<String> {
        let text = CLICommandTests.codeOnly(source)
        var hits: Set<String> = []
        for word in words where text.range(of: word.pattern, options: .regularExpression) != nil { hits.insert(word.name) }
        return hits
    }

    /// The delete selectors in a source without comments (string literals kept).
    static func rawHits(_ withoutComments: String) -> [String] { rawSelectors.filter { withoutComments.contains($0) } }

    static func codeOnly(_ text: String) -> String { CLICommandTests().code(text) }

    /// Where each word may be in PandaCore. A word that is not in this table has no file. Each entry has a reason.
    /// A new file with one of these words fails the test, so that a person must look at it. An entry for a file that does not
    /// contain the word any more also fails, so that the table stays true.
    static let wordAllow: [String: [String: String]] = [
        "removeItem": ["Cleaner.swift": "the one place that deletes items, after the guard (`deleteItem`)",
                       "Log.swift": "rotates the log file of the app itself (`trashpanda.log`), never a user file"],
        "moveItem": ["Log.swift": "rotates the log file of the app itself (`trashpanda.log`), never a user file"],
        "createFile": ["Log.swift": "creates the log file of the app itself (`trashpanda.log`), never a user file"],
        "forWritingTo": ["Log.swift": "opens the log file of the app itself (`trashpanda.log`) to append a line"],
        "setAttributes": ["Log.swift": "sets the permissions of the log folder and the log file of the app itself"],
        "trashItem": ["Cleaner.swift": "the field `trashItem` holds the move to the Trash (`TrashMover.move`). Only the Cleaner calls it",
                      "DeleteMode.swift": "TrashMover: the move to the Trash in trash mode. Only the Cleaner calls it"],
        "remove(": ["Cleaner.swift": "calls `Worktrees.remove` and the Ollama `remove` after the guard, and matches the worktree case",
                    "Worktrees.swift": "declares the worktree case `remove` and `Worktrees.remove` (it runs `git worktree remove` through Git)",
                    "Model.swift": "matches the worktree case `.remove(` to read its path",
                    "DiskScanner.swift": "matches the worktree case `.remove(` to read its path",
                    "OllamaModels.swift": "declares `remove`: it runs `ollama rm` through Shell. Only the Cleaner calls it"],
        "perform(": ["Cleaner.swift": "`perform` is a local closure that holds the delete or the move (`try perform(url)`)"],
        "exec": ["Shell.swift": "`execute`: the one runner of tools. It has the trust checks, the time limit, and the quiet mode"],
        "write(to": ["DiskScanner.swift": "writes the settings files of the app itself (the keep list and the help text), never a user file"],
        "Process(": ["Shell.swift": "the one runner of tools. It has the trust checks, the time limit, and the quiet mode"],
    ]

    /// Every file that has a word, by word, in PandaCore (names without the folder).
    private func dangerFiles() throws -> [String: Set<String>] {
        let dir = root().appendingPathComponent("Sources/PandaCore")
        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 50)
        var found: [String: Set<String>] = [:]
        for file in files {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            let name = (file as NSString).lastPathComponent
            for word in Self.dangerHits(text, words: Self.dangers) { found[word, default: []].insert(name) }
            for selector in Self.rawHits(stripComments(text)) { found["raw:" + selector, default: []].insert(name) }
        }
        return found
    }

    func testOnlyTheDocumentedFilesHaveADangerWord() throws {
        let found = try dangerFiles()
        for (word, files) in found.sorted(by: { $0.key < $1.key }) {
            let allowed = Set(Self.wordAllow[word, default: [:]].keys)
            // CleanPlan.swift matches the worktree case `.remove(`. The read-only test removes that one pattern and checks again.
            let extra = word == "remove(" ? files.subtracting(["CleanPlan.swift"]) : files
            XCTAssertEqual(extra, allowed, "word `\(word)`: the files that have it and the files in the allow-list must be equal")
        }
        for word in Self.wordAllow.keys { XCTAssertNotNil(found[word], "the allow-list names `\(word)`, but no file has it") }
        XCTAssertTrue(found.keys.filter { $0.hasPrefix("raw:") }.isEmpty, "No file may name a delete selector, even in a string: \(found)")
    }

    func testOnlyTheDocumentedFilesCanDeleteOrRunAProgram() throws {
        let found = try dangerFiles()
        // The old checks, kept: three files delete or move, one file starts a program, no file builds a Cleaner.
        let deleteWords = ["removeItem", "trashItem", "unlink", "moveItem", "replaceItem", "removefile"]
        let deleters = deleteWords.reduce(into: Set<String>()) { $0.formUnion(found[$1] ?? []) }
        XCTAssertEqual(deleters, ["Cleaner.swift", "DeleteMode.swift", "Log.swift"], "files with a delete word")
        let runners = ["Process(", "Process.init", "posix_spawn", "system(", "popen", "NSTask"].reduce(into: Set<String>()) { $0.formUnion(found[$1] ?? []) }
        XCTAssertEqual(runners, ["Shell.swift"], "files that start a program")
        let dir = root().appendingPathComponent("Sources/PandaCore")
        var cleanerUsers: Set<String> = []
        for file in try FileManager.default.subpathsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
            let text = code(try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8))
            if text.range(of: #"\bCleaner\s*\("#, options: .regularExpression) != nil { cleanerUsers.insert((file as NSString).lastPathComponent) }
        }
        // CLIClean.swift is the one file that builds the real Cleaner: it hands the findings of the plan to it, with all its guards,
        // and has no delete word and no delete rule of its own (the first assertion of this test and `testCLICleanFile...` check that).
        XCTAssertEqual(cleanerUsers, ["CLIClean.swift"], "only the file of the real clean builds a Cleaner")
    }

    // MARK: Made-up sources: the scanners catch each bypass, and harmless code passes
    // These strings are never compiled and never run. They are only text for the scanner. They name no real path of a user.

    private let probeB1 = """
    import Foundation
    enum CleanRules {
        static func exists(_ url: URL) -> Bool { true }
        static func exists(_ path: String, force: Bool) -> Int32 { Darwin.remove(path) }
    }
    """
    private let probeB2 = """
    func move(_ from: String, home: String) {
        _ = rename(from, home + "/.Trash/x")
        _ = renamex_np(from, home + "/.Trash/y", 0)
        _ = renameat(0, from, 0, home + "/.Trash/z")
    }
    """
    private let probeB3 = "func start() throws { let p = Process.init(); try p.run() }"
    private let probeB4 = """
    func go(_ p: String) {
        _ = FileManager.default.perform(NSSelectorFromString("removeItemAtPath:error:"), with: p, with: nil)
    }
    """
    private let probeB5 = "func gone(_ path: String) { _ = rmdir(path) }"
    // The four bypasses of the review of step 2c. Each one type-checks as real Swift.
    /// a. The call is inside a string interpolation.
    private let probeC1 = #"func a(_ p: String) -> String { "\(Darwin.remove(p))" }"#
    private let probeC1b = #"func a(_ u: URL) -> String { "\((try? FileManager.default.removeItem(at: u)) != nil)" }"#
    private let probeC1c = #"func a(_ p: String) -> String { "x \(String("\(Darwin.remove(p))")) y" }"#
    /// b. Code between two raw strings that have a quote inside.
    private let probeC2 = ##"let x = #"x"y"#; _ = Darwin.remove(p); let y = #"x"y"#"##
    /// c. An escaped quote before `//` cut the rest of the line.
    private let probeC3 = #"let s = "\"//"; _ = Darwin.remove(p)"#
    /// d. A declared name that only starts like the called name.
    private let probeC4 = "enum CleanRules { static func truncateText() {}\n static func go(_ p: String) { truncate(p, 0) } }"
    private let harmless = """
    import Foundation
    struct Totals { var a: Int
        func double() -> Int { [a, a].map { $0 * 2 }.reduce(0, +) }
        // Darwin.remove( is only a comment here, and the text "rename(" is a string
        func label() -> String { "rename(" + String(a) }
    }
    """

    func testEachBypassProbeIsCaught() throws {
        let cases: [(name: String, source: String, words: [String])] = [
            ("B1", probeB1, ["Darwin./Glibc.", "remove("]),
            ("B2", probeB2, ["rename", "renamex", "renameat"]),
            ("B3", probeB3, ["Process.init"]),
            ("B4", probeB4, ["NSSelectorFromString", "perform("]),
            ("B5", probeB5, ["rmdir"]),
            ("C1", probeC1, ["Darwin./Glibc.", "remove("]),
            ("C1b", probeC1b, ["removeItem"]),
            ("C1c", probeC1c, ["Darwin./Glibc.", "remove("]),
            ("C2", probeC2, ["Darwin./Glibc.", "remove("]),
            ("C3", probeC3, ["Darwin./Glibc.", "remove("]),
            ("C4", probeC4, ["truncate"]),
        ]
        for c in cases {
            let hits = Self.dangerHits(c.source, words: Self.dangers)
            for word in c.words { XCTAssertTrue(hits.contains(word), "\(c.name) must be caught by `\(word)`; hits: \(hits)") }
            // A new file with this code has no allow-list entry, so the table test fails for it.
            XCTAssertFalse(hits.isEmpty, c.name)
            // The read-only check catches it too.
            XCTAssertFalse(try readOnlyProblems(c.source).isEmpty, "\(c.name) must fail the read-only check")
        }
        // The read-only check names the reason for each of the four new bypasses.
        XCTAssertTrue(try readOnlyProblems(probeC1).contains("low-level call Darwin.remove"))
        XCTAssertTrue(try readOnlyProblems(probeC1c).contains("low-level call Darwin.remove"))
        XCTAssertTrue(try readOnlyProblems(probeC2).contains("low-level call Darwin.remove"))
        XCTAssertTrue(try readOnlyProblems(probeC3).contains("low-level call Darwin.remove"))
        XCTAssertTrue(try readOnlyProblems(probeC1b).contains("calls FileManager.removeItem"))
        let c4 = try readOnlyProblems(probeC4)
        XCTAssertTrue(c4.contains("call not in the allow-list: truncate"), "\(c4)")
        // B4 also hides the selector in a string. The raw scan sees it.
        XCTAssertEqual(Self.rawHits(stripComments(probeB4)), ["removeItemAtPath"])
        XCTAssertEqual(Self.rawHits(stripComments(probeB2)), [])
    }

    func testAnOverloadWithAnAllowedNameDoesNotHideALowLevelCall() throws {
        // `exists` is in the allow-list and the file declares it. `Darwin.remove` must still be found.
        let problems = try readOnlyProblems(probeB1)
        XCTAssertTrue(problems.contains("low-level call Darwin.remove"), "\(problems)")
        // A bare `remove(` call behind a declared overload is found by the word list.
        let bare = "enum CleanRules { static func remove(_ p: String) {}\n static func go() { remove(\"x\") } }"
        XCTAssertTrue(Self.dangerHits(bare, words: Self.dangers).contains("remove("))
        XCTAssertTrue(try readOnlyProblems("import Darwin\nfunc a() {}").contains("imports a low-level module"))
    }

    func testHarmlessCodePassesEveryScanner() throws {
        XCTAssertEqual(Self.dangerHits(harmless, words: Self.dangers), [])
        XCTAssertEqual(Self.rawHits(stripComments(harmless)), [])
        // The two functions of the made-up source are its own code. The read-only check has no other problem with it.
        let problems = try readOnlyProblems(harmless)
        XCTAssertEqual(problems, [])
    }

    func testHarmlessLookalikesOfTheFourBypassesPass() throws {
        let sources = [
            #"func a(_ n: Int) -> String { "value \(n) and \(String(n))" }"#,
            #"let s = "\"//"; let n = 1"#,
            ##"let x = #"x"y"#; let y = #"a "quoted" b"#; let n = x.count + y.count"##,
            "enum E { static func truncateText() {}\n static func go() { truncateText() } }",
            "struct T { func a() -> String { \"\"\"\nDarwin.remove(p) in a text block \\(1)\n\"\"\" } }",
        ]
        for source in sources {
            XCTAssertEqual(Self.dangerHits(source, words: Self.dangers), [], source)
            XCTAssertEqual(Self.rawHits(stripComments(source)), [], source)
            let problems = try readOnlyProblems(source).filter { !$0.hasPrefix("call not in the allow-list: ") }
            XCTAssertEqual(problems, [], source)
        }
        // Whole words only: `truncateText` is declared, `truncate` is not.
        XCTAssertTrue(Self.declares("static func truncateText() {}", "truncateText"))
        XCTAssertFalse(Self.declares("static func truncateText() {}", "truncate"))
        XCTAssertTrue(Self.declares("struct Box {}", "Box"))
        XCTAssertFalse(Self.declares("struct Boxes {}", "Box"))
    }

    func testMutationEachFixOfTheFourBypassesIsNeeded() throws {
        // Old reader, kept here only as a model: it blanked every string on one line and cut at the first `//` with an even
        // quote count. With it, the three reader bypasses pass. This proves that the new reader is what catches them.
        func oldCode(_ text: String) -> String {
            var out = ""
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                var l = String(line)
                if let r = l.range(of: "//"), l[..<r.lowerBound].filter({ $0 == "\"" }).count % 2 == 0 { l = String(l[..<r.lowerBound]) }
                out += l + "\n"
            }
            return out.replacingOccurrences(of: #""([^"\\]|\\.)*""#, with: "\"\"", options: .regularExpression)
        }
        for (name, source) in [("a", probeC1), ("a2", probeC1b), ("b", probeC2), ("c", probeC3)] {
            XCTAssertNil(oldCode(source).range(of: #"\b(Darwin|Glibc)\s*\.|removeItem"#, options: .regularExpression),
                         "bypass \(name) passes the old reader, so the test is a real check")
            XCTAssertNotNil(code(source).range(of: #"\b(Darwin|Glibc)\s*\.|removeItem"#, options: .regularExpression),
                            "bypass \(name) must be seen by the new reader")
        }
        // d. With the old prefix match, the declared name hides the call. With the whole word match, it does not.
        let text = code(probeC4)
        XCTAssertTrue(text.contains("func truncate"), "the old prefix check sees a declaration")
        XCTAssertFalse(Self.declares(text, "truncate"))
        // Each new word has a probe in the next test, and the removal of the word lets the probe through.
        XCTAssertTrue(Self.dangerHits(probeC4, words: Self.dangers.filter { $0.name != "truncate" }).isEmpty)
    }

    /// Ways around the scanners that stay open ON PURPOSE. They need code that no honest change has, and a word list cannot cover
    /// them. The real answer is the check at the level of the system (issue 249: run the binary in a sandbox profile that denies
    /// writes in the home folder). This list is a record, not a test: an item here is a known hole, not a proof of safety.
    /// Known survivors:
    ///   - `method(for:)` plus `unsafeBitCast`, or `dlsym`-like lookups that this scan does not see by name
    ///   - a `typealias FM = FileManager` followed by calls on the alias (the FileManager check reads `FileManager.default.<name>`)
    ///   - `open(..., O_TRUNC)` and `open(..., O_WRONLY)` (the word `open(` is too common to forbid)
    ///   - `rename` or `remove` used as a function VALUE (`let f = remove; f(p)`), because the call regex needs `name(`
    ///   - code that builds a name from parts at run time (`NSSelectorFromString("remove" + "Item...")` is caught by the selector
    ///     scan, but a name that comes from data is not)
    /// Words that are now in the list (so no longer survivors): `write(toFile`, `createFile`, `clonefile`, `copyfile`, `exchangedata`,
    /// `truncate`, `fopen`, `forWritingTo`, `NSFileCoordinator`, `dlsym`.
    static let knownSurvivors = ["method(for:)+unsafeBitCast", "typealias FM", "open with O_TRUNC", "rename/remove as a function value"]

    func testTheNewWordsHaveAProbeAndTheKnownSurvivorsAreNotCaught() throws {
        let probes: [String: String] = [
            "write(toFile": #"try "".write(toFile: p, atomically: true, encoding: .utf8)"#, "createFile": "_ = fm.createFile(atPath: p, contents: nil)",
            "clonefile": "clonefile(a, b, 0)", "copyfile": "copyfile(a, b, nil, 0)", "exchangedata": "exchangedata(a, b, 0)",
            "truncate": "truncate(p, 0)", "fopen": #"let f = fopen(p, "w")"#, "forWritingTo": "let h = try FileHandle(forWritingTo: u)",
            "NSFileCoordinator": "let c = NSFileCoordinator()", "dlsym": "let f = dlsym(h, n)",
        ]
        for (word, source) in probes {
            XCTAssertTrue(Self.dangerHits(source, words: Self.dangers).contains(word), word)
            XCTAssertFalse(Self.dangerHits(source, words: Self.dangers.filter { $0.name != word }).contains(word), word)
            XCTAssertFalse(try readOnlyProblems(source).isEmpty, word)
        }
        // A survivor passes the word list. This test fails the day that one of them gets caught, so the list stays true.
        XCTAssertEqual(Self.dangerHits("let f = rename\nlet g = remove", words: Self.dangers), [])
        XCTAssertEqual(Self.dangerHits("func a() { _ = open(p, O_TRUNC) }", words: Self.dangers), [])
        XCTAssertEqual(Self.knownSurvivors.count, 4)
    }

    func testBareSlashAndBacktickProbesAreCaught() throws {
        // Each source compiles with `swiftc -swift-version 5`. They are strings only: nothing runs.
        let probes: [(word: String, source: String)] = [
            ("Darwin./Glibc.", "let q = [8.0, 2.0].reduce(64, /); _ = Darwin.remove(p); let r = 1.0/2.0"),
            ("unlink", "let f: (Double, Double) -> Double = (/); _ = Darwin.unlink(p); let r2 = 1.0/2.0"),
            ("removeItem", "let q = [8.0, 2.0].reduce(64, /); try FileManager.default.removeItem(atPath: p); let r = 1.0/2.0"),
            ("remove(", "_ = `remove`(p)"), ("rename", "`rename`(a, b)"), ("truncate", "`truncate`(p, 0)"),
        ]
        for (word, source) in probes {
            XCTAssertTrue(Self.dangerHits(source, words: Self.dangers).contains(word), source)
            XCTAssertFalse(try readOnlyProblems(source).isEmpty, "read-only check: \(source)")
        }
        // The raw scan also sees a selector name in backticks.
        XCTAssertFalse(Self.rawHits(stripComments("_ = `unlink`(p)")).isEmpty)
        // A harmless lookalike in backticks passes.
        let harmless = "func `truncateText`() {}\nlet `value` = 1 + `value`"
        XCTAssertEqual(Self.dangerHits(harmless, words: Self.dangers), [])
        XCTAssertEqual(Self.rawHits(stripComments(harmless)), [])
        XCTAssertEqual(try readOnlyProblems(harmless).filter { !$0.hasPrefix("call not in the allow-list: ") }, [])
    }

    func testRemovingAWordFromTheListLetsItsProbeThrough() throws {
        // Mutation check. Each word has a probe. Without the word, the probe is no longer caught by that word.
        let probes: [(word: String, source: String)] = [
            ("remove(", probeB1), ("Darwin./Glibc.", probeB1), ("rename", probeB2), ("renamex", probeB2), ("renameat", probeB2),
            ("Process.init", probeB3), ("NSSelectorFromString", probeB4), ("perform(", probeB4), ("rmdir", probeB5),
        ]
        for (word, source) in probes {
            XCTAssertTrue(Self.dangerHits(source, words: Self.dangers).contains(word), word)
            let without = Self.dangers.filter { $0.name != word }
            XCTAssertEqual(without.count, Self.dangers.count - 1, word)
            XCTAssertFalse(Self.dangerHits(source, words: without).contains(word), "without `\(word)` the probe must pass that word")
        }
        // The probes that only one word covers pass completely when that word is gone.
        XCTAssertTrue(Self.dangerHits(probeB5, words: Self.dangers.filter { $0.name != "rmdir" }).isEmpty)
        XCTAssertTrue(Self.dangerHits(probeB3, words: Self.dangers.filter { $0.name != "Process.init" }).isEmpty)
        // Every word of the list has a probe, so that no word is unchecked.
        let more = ["removeItem": "try fm.removeItem(at: u)", "trashItem": "try fm.trashItem(at: u, resultingItemURL: &r)",
                    "moveItem": "try fm.moveItem(at: a, to: b)", "replaceItem": "try fm.replaceItem(at: a, withItemAt: b)",
                    "copyItem": "try fm.copyItem(at: a, to: b)", "createSymbolicLink": "try fm.createSymbolicLink(at: a, withDestinationURL: b)",
                    "setAttributes": "try fm.setAttributes([:], ofItemAtPath: p)", "write(to": "try text.write(to: u, atomically: true, encoding: .utf8)",
                    "unlink": "unlink(p)", "unlinkat": "unlinkat(0, p, 0)", "removefile": "removefile(p, nil, 0)",
                    "Foundation.<call>": "Foundation.remove(p)", "Process(": "let p = Process()", "posix_spawn": "posix_spawn(&pid, p, nil, nil, a, e)",
                    "system(": "system(c)", "popen": "popen(c, r)", "exec": "execv(p, a)", "NSTask": "let t = NSTask()",
                    "write(toFile": #"try "".write(toFile: p, atomically: true, encoding: .utf8)"#, "createFile": "_ = fm.createFile(atPath: p, contents: nil)",
                    "clonefile": "clonefile(a, b, 0)", "copyfile": "copyfile(a, b, nil, 0)", "exchangedata": "exchangedata(a, b, 0)",
                    "truncate": "truncate(p, 0)", "fopen": #"let f = fopen(p, "w")"#, "forWritingTo": "let h = try FileHandle(forWritingTo: u)",
                    "NSFileCoordinator": "let c = NSFileCoordinator()", "dlsym": "let f = dlsym(h, n)"]
        let covered = Set(probes.map(\.word)).union(more.keys)
        XCTAssertEqual(covered, Set(Self.dangers.map(\.name)))
        for (word, source) in more {
            XCTAssertTrue(Self.dangerHits(source, words: Self.dangers).contains(word), word)
            XCTAssertFalse(Self.dangerHits(source, words: Self.dangers.filter { $0.name != word }).contains(word), word)
        }
    }

    // MARK: Tests never write to the real home folder

    /// Words that write, move, or delete. A test file that has one of these together with the real home folder is a risk: the
    /// previous review moved fixture files into the real Trash this way.
    private static let writeWords = ["removeItem", "moveItem", "trashItem", "copyItem", "createDirectory", "createFile", "createSymbolicLink",
                                     "setAttributes", "write(to", ".write(", "rename", "unlink", "rmdir", "remove(", "removefile", "Process"]
    /// Ways to get the real home folder or the real Trash, as regular expressions for the code with the text of strings kept
    /// (a string is written between \u{1} and \u{2}). They are built from parts, so that this file does not contain them in one piece.
    private static let realHomePatterns: [String] = [
        #"\bNSHome"# + #"Directory\b"#, #"\bhomeDirectory"# + #"ForCurrentUser\b"#, #"\bgetpw"# + #"uid\b"#,
        #"\bexpandingTilde"# + #"InPath\b"#, #"\bNSUser"# + #"Name\b"#, #"\bNSFullUser"# + #"Name\b"#,
        #"\.trash"# + #"Directory\b"#, #"\bNSSearchPathFor"# + #"DirectoriesInDomains\b"#, #"\bURL\.home"# + #"Directory\b"#,
        #"\.homeDirectory\b"#,
    ]
    private static let realHomeStringPatterns: [String] = [
        #"environment\s*\[\s*\x{1}HO"# + #"ME\x{2}\s*\]"#, #"getenv\s*\(\s*\x{1}HO"# + #"ME\x{2}"#,
    ]
    /// Calls that write in the home folder when the argument `home:` is left out (the default is the real home folder).
    private static let homeDefaultCalls = ["ensureFile", "setDeleteMode", "appendKeep", #"FirstStartNote\s*\.\s*record"#, "writeSetting"]

    /// The text between the parentheses of a call that starts at `open` (the index of the opening parenthesis).
    private static func arguments(_ code: String, from open: String.Index) -> String {
        var depth = 0
        var end = open
        for i in code[open...].indices {
            if code[i] == "(" { depth += 1 }
            if code[i] == ")" { depth -= 1; if depth == 0 { end = i; break } }
            end = i
        }
        return String(code[open..<end])
    }

    /// The problems of one test file. Empty means fine. Three kinds:
    /// 1. the real home folder (any spelling in `realHomePatterns`) together with a write call,
    /// 2. a call that writes and leaves out `home:` (it would use the real home folder), and `TrashMover.move`, which moves into
    ///    the real Trash,
    /// 3. a `Cleaner(` in trash mode with no `trashItem =` in the same file (the default `trashItem` is `TrashMover.move`).
    static func homeWriteProblems(_ source: String) -> [String] {
        let test = CLICommandTests()
        let withStrings = test.stripComments(source)
        let code = test.code(source)
        var problems: [String] = []
        // The names are searched in the code, where the text of strings is blank (a probe string in a test file is not a use).
        // The two environment patterns need the text of the string `"HOME"`, so they run on the text with strings kept.
        if realHomePatterns.contains(where: { code.range(of: $0, options: .regularExpression) != nil })
            || realHomeStringPatterns.contains(where: { withStrings.range(of: $0, options: .regularExpression) != nil })
            // `standardizingPath` turns a `~` path into the real home folder. It is a risk only when the file has a string that
            // starts with `~` (a relative path, for example in a manifest, never reaches the home folder).
            || (code.contains("standardizing" + "Path") && withStrings.contains("\u{1}~")) {
            // `Process` is a whole word here (`ProcessInfo` is not a call that starts a program).
            problems += writeWords.filter { $0 == "Process" ? code.range(of: #"\bProcess\b"#, options: .regularExpression) != nil : code.contains($0) }
                .map { "real home with \($0)" }
        }
        for name in homeDefaultCalls {
            let regex = try! NSRegularExpression(pattern: #"\b"# + name + #"\s*\("#)
            for m in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                let open = code.index(code.startIndex, offsetBy: m.range.upperBound - 1)
                if !arguments(code, from: open).contains("home:") { problems.append("\(name) without home:") }
            }
        }
        if code.range(of: #"\bTrashMover\s*\.\s*move\b"#, options: .regularExpression) != nil { problems.append("TrashMover.move") }
        if code.range(of: #"\bCleaner\s*\("#, options: .regularExpression) != nil,
           code.range(of: #"deleteMode\s*:\s*\.trash\b|DeleteMode\s*\.\s*trash\b"#, options: .regularExpression) != nil,
           !code.contains("trashItem =") {
            problems.append("Cleaner in trash mode without trashItem =")
        }
        return problems
    }

    /// The files of `Tests` as (relative path, text).
    private func testFiles() throws -> [(String, String)] {
        let dir = root().appendingPathComponent("Tests")
        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 50)
        return try files.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    func testNoTestFileCombinesTheRealHomeFolderWithAWriteCall() throws {
        // Today no test file names the real home folder. Each test uses a temp home (`Sandbox`), and each call that writes
        // in a home folder passes `home:`. The Cleaner default `trashItem` is the real Trash: each test that uses trash mode
        // sets `trashItem` first. This test checks all of it, for every file of `Tests`.
        var bad: [String: [String]] = [:]
        for (file, text) in try testFiles() {
            let problems = Self.homeWriteProblems(text)
            if !problems.isEmpty { bad[file] = problems }
        }
        XCTAssertTrue(bad.isEmpty, "A test must use a temp home (Sandbox), never the real home folder: \(bad)")
    }

    func testTheHomeGuardCatchesEverySpellingAndPassesHarmlessCode() throws {
        func part(_ a: String, _ b: String) -> String { a + b }
        let spellings = [
            "let h = " + part("NSHome", "Directory()"),
            "let h = ProcessInfo.processInfo.environment[\"" + part("HO", "ME") + "\"]!",
            "let h = FileManager.default." + part("homeDirectory", "ForCurrentUser"),
            "let h = URL." + part("home", "Directory"),
            "let u = fm.urls(for: ." + part("trash", "Directory") + ", in: .userDomainMask)[0]",
            "let h = String(cString: getenv(\"" + part("HO", "ME") + "\"))",
            "let n = " + part("NSUser", "Name()"),
            "let h = NSString(string: \"~/x\")." + part("standardizing", "Path"),
            "let h = NSString(string: \"~/x\")." + part("expandingTilde", "InPath"),
            "let p = " + part("getpw", "uid(getuid())"),
        ]
        for source in spellings {
            XCTAssertFalse(Self.homeWriteProblems(source + "\n_ = rename(a, h + \"/x\")").isEmpty, source)
            XCTAssertTrue(Self.homeWriteProblems(source + "\nlet n = h.count").isEmpty, "a read of the home alone is not flagged: \(source)")
        }
        // A local name that only contains a pattern word is not the real home folder.
        XCTAssertTrue(Self.homeWriteProblems("let homeDirectory = box.home\ntry fm.removeItem(at: homeDirectory)").isEmpty)
        XCTAssertTrue(Self.homeWriteProblems("let trashDirectory = box.trash\ntry fm.removeItem(at: trashDirectory)").isEmpty)
        // The default `home:` of a call that writes.
        for call in ["Config.ensureFile(\"keep\")", "Config.setDeleteMode(.trash)", "Config.appendKeep(path)", "FirstStartNote.record()"] {
            XCTAssertFalse(Self.homeWriteProblems("_ = \(call)").isEmpty, call)
        }
        XCTAssertTrue(Self.homeWriteProblems("_ = Config.appendKeep(path, home: box.home)\n_ = FirstStartNote.record(home: box.home)").isEmpty)
        XCTAssertTrue(Self.homeWriteProblems("_ = Config.ensureFile(name, home: home)\n_ = Config.setDeleteMode(.trash, home: h)").isEmpty)
        // The real Trash.
        XCTAssertFalse(Self.homeWriteProblems("try TrashMover.move(url)").isEmpty)
        XCTAssertFalse(Self.homeWriteProblems("let c = Cleaner(guardian: g, deleteMode: .trash)").isEmpty)
        XCTAssertTrue(Self.homeWriteProblems("var c = Cleaner(guardian: g, deleteMode: .trash)\nc.trashItem = { _ in }").isEmpty)
        // Comments and strings do not count, and a temp home is fine.
        XCTAssertTrue(Self.homeWriteProblems("// " + part("NSHome", "Directory()") + " in a comment\ntry fm.removeItem(at: box.home)").isEmpty)
        XCTAssertTrue(Self.homeWriteProblems("let box = try Sandbox()\ntry fm.removeItem(at: box.home)").isEmpty)
    }

    func testEveryTestThatStartsAProgramUsesTheFakeHomeHelper() throws {
        // A program that starts with only `HOME` can still reach the real home. This test covers only a DIRECT start: a test file
        // that has `Process(`, `Process.init`, `Process.launchedProcess`, or `posix_spawn` must also use `FakeHomeEnvironment`.
        // It does NOT cover an INDIRECT start. These test files start a program through product code, and that code copies
        // `ProcessInfo.environment` (so the program inherits the real HOME). They are known cases, and none of them writes the home:
        //   - `Shell.run` in ShellTimeoutTests (and in the other Shell tests)
        //   - `DiskScanner(dockerPath:)` in the FakeDocker tests (a fake script, started through Shell)
        //   - the real `/usr/bin/git` in WorktreeTests (started through Shell, on temp repositories)
        // The real check for all of them is the OS-level sandbox of issue 249. Product code in Shell.swift is not changed here.
        var bad: [String] = []
        for (file, text) in try testFiles() where file != "FakeHomeEnvironment.swift" {
            let code = self.code(text)
            if code.range(of: #"\bProcess\s*\(|\bProcess\s*\.\s*(init|launchedProcess)|\bposix_spawn"#, options: .regularExpression) != nil,
               !code.contains("FakeHomeEnvironment") {
                bad.append(file)
            }
        }
        XCTAssertEqual(bad, [], "Start a program in a test only with `FakeHomeEnvironment.environment(for:)`. HOME alone does not isolate it.")
    }
}
