import XCTest
@testable import PandaCore

/// Step 2b of #197: the commands that only read are a pure function in PandaCore (`CLICommand.run`).
/// These tests run it end to end on a fixture home with real files, and compare every file before and after.
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
        // The text form says how many items are checked again.
        let text = try XCTUnwrap(run(["--clean-safe", "--dry-run"], box).result?.stdout)
        XCTAssertTrue(text.contains("checked again at clean time"), text)
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
            ["--clean-safe"], ["--clean-safe", "--json"], ["--clean-safe", "--verbose"], ["--clean-safe", "--yes"],
            ["--clean-safe", "--dry-run", "--yes"], ["--clean-safe", "--dry-run", "--yes", "--json"], ["--yes"],
            ["--yes", "--dry-run", "--clean-safe"], ["--dry-run"], ["--dry-run", "--json"], ["--dry-run", "--scan"],
            ["--dry-run", "--verbose"], ["--scan", "--clean-safe"], ["--scan", "--clean-safe", "--dry-run"],
            ["--scan", "--yes"], ["--scan", "--verbose"], ["--scan", "--json", "--verbose"], ["--json"], ["--json", "--demo"],
            ["--verbose"], ["--verbose", "--json"], ["--clean-safe", "--dry-run", "--json", "--verbose"],
            ["--clean-safe", "--dry-run", "--nope"], ["--delete"], ["--clean"], ["--scan", "--nope"], ["--demo", "--verbose"],
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
        XCTAssertTrue(run(["--clean-safe"], box).result!.stderr.hasPrefix("--clean-safe needs --dry-run in this version\n"))
        XCTAssertTrue(run(["--clean-safe", "--dry-run", "--json", "--verbose"], box).result!.stderr.hasPrefix("--verbose cannot be used with --json\n"))
        XCTAssertTrue(run(["--verbose"], box).result!.stderr.hasPrefix("--verbose works only with --clean-safe --dry-run\n"))
        XCTAssertTrue(run(["--clean-safe", "--dry-run", "--yes"], box).result!.stderr.hasPrefix("--yes is not available in this version\n"))
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
        XCTAssertFalse(CLICommand.usage.contains("--yes"))
        XCTAssertTrue(CLICommand.usage.contains("--verbose and --json cannot be used together"))
    }

    // MARK: Source: the read-only code has no way to delete

    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(relative), encoding: .utf8)
    }

    /// The code of a file without comments and without the text inside string literals.
    private func code(_ text: String) -> String {
        var out = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var l = String(line)
            if let r = l.range(of: "//") {
                // Keep a "//" that is inside a string (for example a URL). The files here have none, so cut at the first one
                // that is not inside quotes.
                let before = l[..<r.lowerBound]
                if before.filter({ $0 == "\"" }).count % 2 == 0 { l = String(before) }
            }
            out += l + "\n"
        }
        // Remove the text of string literals (one line each).
        return out.replacingOccurrences(of: #""([^"\\]|\\.)*""#, with: "\"\"", options: .regularExpression)
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
        "systemCacheName": "pure", "projectInUse": "pure", "exists": "FileManager read", "isPlain": "reads the links of a path",
        "isPlainPath": "reads the links of a path", "isArtifactFolder": "Catalog: reads a folder list",
        "isArchive": "pure path shape", "isDeviceSupport": "pure path shape", "isSparkleFolder": "pure path shape",
        "isInstallerPath": "pure path shape", "read": "Installers.read: reads file attributes", "staleItems": "reads folder lists",
        "targets": "BrowserCaches: reads folder lists", "browser": "table lookup", "tool": "table lookup",
        "oldVersions": "TestBrowsers: reads folder lists", "entries": "OldLogs: reads folder lists", "isTarget": "pure path shape",
        "isVersionFolder": "pure path shape", "kind": "pure path shape", "isFolderName": "pure", "catalogNames": "pure table",
        "keepReason": "pure table", "cleanedFolders": "a table", "isOneClick": "pure", "sizeText": "text", "countedBytes": "a number",
        "wouldClean": "a list", "skipped": "a list", "skipCounts": "a list",
        // Log lines
        "info": "writes a log line (the log function of the caller)", "warn": "writes a log line (the log function of the caller)",
        // Types, enum cases, and properties that the regular expression sees as calls. None of them runs anything.
        "Bool": "a type", "Int64": "a type", "Equatable": "a type", "Sendable": "a type", "CodingKey": "a type", "Array": "a type",
        "Rebuild": "a type", "JSONEncoder": "encodes to memory", "NSHomeDirectory": "reads the path of the home folder",
        "autoclosure": "an attribute", "self": "keyword", "nil": "keyword", "true": "keyword",
        "now": "the clock function of the caller", "findings": "a property", "base": "a property", "shape": "a closure of the plan that only reads",
        "resolvedShape": "a closure of the plan that only reads", "resolved": "a list", "shapeProblem": "a flag", "blockedReason": "a property",
        "isActionable": "a property", "would": "a local name", "verbose": "a flag", "safe": "an enum case", "trash": "an enum case",
        "action": "a property", "remove": "an enum case that is matched, never run", "worktree": "an Action case that is matched, never run",
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

    func testReadOnlyFilesCallOnlyAllowedFunctions() throws {
        var unknown: [String: Set<String>] = [:]
        for file in readOnlyFiles {
            let text = code(try source(file))
            let regex = try NSRegularExpression(pattern: #"\b([A-Za-z_][A-Za-z0-9_]*)\s*[(\{]"#)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let name = String(text[Range(m.range(at: 1), in: text)!])
                // A name that the file declares itself (a function or a type) is the code of that file. It is read like the rest.
                if text.contains("func \(name)") || text.contains("struct \(name)") || text.contains("enum \(name)")
                    || text.contains("class \(name)") || text.contains("init(") && name == "init" { continue }
                if Self.allowedCalls[name] == nil { unknown[file, default: []].insert(name) }
            }
        }
        XCTAssertTrue(unknown.isEmpty, "These calls are not in the allow-list. Check that each one is read-only, then add it with a reason: \(unknown)")
    }

    func testReadOnlyFilesDoNotReferenceTheCleanerOrAToolRunner() throws {
        let forbidden = ["Cleaner", "Shell", "Process", "removeItem", "trashItem", "unlink", "moveItem", "copyItem", "replaceItem",
                         "createFile", "createDirectory", "createSymbolicLink", "createLink", "setAttributes", "linkItem",
                         "FileHandle", "NSWorkspace", "recycle", "TrashMover", "TrashBin", "deleteItem", "dispose", "Docker", "Simctl",
                         "Brew", "write(to", "write(", "performDelete", "OwnerCommand", "ownerRunner", "emptyTrash"]
        for file in readOnlyFiles {
            let text = code(try source(file))
            for word in forbidden {
                // `emptyTrash` is an Action case that the plan names in a switch. Naming it is fine: the plan never runs it.
                if word == "emptyTrash" { continue }
                XCTAssertFalse(text.contains(word), "\(file) must not contain \(word)")
            }
        }
        // The FileManager is used only through read methods.
        let readMethods: Set<String> = ["attributesOfItem", "contentsOfDirectory", "fileExists"]
        for file in readOnlyFiles {
            let text = code(try source(file))
            let regex = try NSRegularExpression(pattern: #"FileManager\.default\.([A-Za-z]+)"#)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let name = String(text[Range(m.range(at: 1), in: text)!])
                XCTAssertTrue(readMethods.contains(name), "\(file) calls FileManager.\(name)")
            }
        }
        // main.swift is thin: it calls the command, writes the result, and exits. It has no scan, plan, or delete code.
        let main = code(try source("Sources/TrashPanda/main.swift"))
        XCTAssertTrue(main.contains("CLICommand.run("))
        for word in ["Cleaner", "CleanPlan", "DryRunReport", "ScanReport", "removeItem", "trashItem", "Shell", "\"--yes\"", "\"--dry-run\""] {
            XCTAssertFalse(main.contains(word), "main.swift must not contain \(word)")
        }
    }

    /// Where a delete, a move to the Trash, or a program start may be in PandaCore. Each entry has a reason.
    /// A new file with one of these words fails the test, so that a person must look at it.
    static let deleteWords = ["removeItem", "trashItem", "unlink", "moveItem", "replaceItem", "removeFile"]
    static let deleteAllowList: [String: String] = [
        "Cleaner.swift": "the one place that deletes items, after the guard (`deleteItem`)",
        "DeleteMode.swift": "TrashMover: the move to the Trash in trash mode. Only the Cleaner calls it",
        "Log.swift": "rotates the log file of the app itself (`trashpanda.log`), never a user file",
    ]
    static let processAllowList: [String: String] = [
        "Shell.swift": "the one runner of tools. It has the trust checks, the time limit, and the quiet mode",
    ]

    func testOnlyTheDocumentedFilesCanDeleteOrRunAProgram() throws {
        let dir = root().appendingPathComponent("Sources/PandaCore")
        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 50)
        var deleters: Set<String> = [], runners: Set<String> = [], cleanerUsers: Set<String> = []
        for file in files {
            let text = code(try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8))
            let name = (file as NSString).lastPathComponent
            if Self.deleteWords.contains(where: { text.contains($0) }) { deleters.insert(name) }
            if text.contains("Process(") || text.contains("Process()") { runners.insert(name) }
            if text.range(of: #"\bCleaner\s*\("#, options: .regularExpression) != nil { cleanerUsers.insert(name) }
        }
        XCTAssertEqual(deleters, Set(Self.deleteAllowList.keys), "files with a delete word")
        XCTAssertEqual(runners, Set(Self.processAllowList.keys), "files that start a program")
        XCTAssertTrue(cleanerUsers.isEmpty, "no file in PandaCore builds a Cleaner except through its own type: \(cleanerUsers)")
    }
}
