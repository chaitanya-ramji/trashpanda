import XCTest
@testable import PandaCore

/// Issue 221. Only `Shell.run` starts programs, and it never starts a shell or a tool that starts other programs.
final class ShellHardeningTests: XCTestCase {

    // MARK: Source scan

    /// The one file that may start programs. This is an exact path, relative to `Sources`. It is not a prefix.
    static let spawnExemptPath = "PandaCore/Shell.swift"

    /// Each pattern names a way to start a program outside `Shell.run`.
    private static let spawnPatterns: [(label: String, regex: NSRegularExpression)] = [
        ("Process", #"\bProcess\b"#),
        ("NSTask", #"\bNSTask\b"#),
        ("posix_spawn", #"posix_spawn"#),
        ("exec family", #"\bexec(?:ve|v|vp|vP|l|le|lp)\b"#),
        ("system(", #"(?:(?<![\w.])|(?<=Darwin\.))system\s*\("#),
        ("popen", #"\bpopen\b"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// Removes comments and string literals, so that a comment cannot hide a call and cannot cause a hit.
    /// Code inside a string interpolation `\( ... )` is kept, because it runs.
    static func codeOnly(_ text: String) -> String {
        var i = 0
        return code(Array(text), &i, nested: false)
    }

    private static func code(_ s: [Character], _ i: inout Int, nested: Bool) -> String {
        var out = ""
        var depth = 0
        func at(_ k: Int) -> Character? { k < s.count ? s[k] : nil }
        while i < s.count {
            let c = s[i]
            if c == "/", at(i + 1) == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", at(i + 1) == "*" {
                var level = 1
                i += 2
                while i < s.count, level > 0 {
                    if s[i] == "/", at(i + 1) == "*" { level += 1; i += 2 }
                    else if s[i] == "*", at(i + 1) == "/" { level -= 1; i += 2 }
                    else { i += 1 }
                }
                out.append(" ")
                continue
            }
            if c == "\"" || c == "#" {
                var hashes = 0
                while at(i + hashes) == "#" { hashes += 1 }
                if at(i + hashes) == "\"" {
                    let multiline = at(i + hashes + 1) == "\"" && at(i + hashes + 2) == "\""
                    let quotes = multiline ? 3 : 1
                    i += hashes + quotes
                    while i < s.count {
                        if s[i] == "\\", (0..<hashes).allSatisfy({ at(i + 1 + $0) == "#" }) {
                            if at(i + 1 + hashes) == "(" {
                                i += 2 + hashes
                                out += " " + code(s, &i, nested: true) + " "
                            } else {
                                i += 2 + hashes
                            }
                            continue
                        }
                        if s[i] == "\"", (1..<quotes).allSatisfy({ at(i + $0) == "\"" }),
                           (0..<hashes).allSatisfy({ at(i + quotes + $0) == "#" }) {
                            i += quotes + hashes
                            break
                        }
                        i += 1
                    }
                    out += " \"\" "
                    continue
                }
            }
            if nested {
                if c == "(" { depth += 1 }
                if c == ")" {
                    if depth == 0 { i += 1; return out }
                    depth -= 1
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// `relativePath` is relative to `Sources`. Only the exact path in `spawnExemptPath` may start programs.
    static func spawnProblems(in text: String, relativePath: String) -> [String] {
        if relativePath == spawnExemptPath { return [] }
        let code = codeOnly(text)
        var problems: [String] = []
        for (label, regex) in spawnPatterns
        where regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
            problems.append("\(relativePath) uses \(label)")
        }
        return problems
    }

    func testOnlyShellSwiftStartsPrograms() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let relatives = files.map { String($0.path.dropFirst(root.path.count + 1)) }
        XCTAssertGreaterThan(files.count, 20)
        XCTAssertTrue(relatives.contains { $0.hasPrefix("TrashPanda/") }, "The scan must cover the app target too")
        XCTAssertTrue(relatives.contains { $0.hasPrefix("PandaCore/") })
        XCTAssertTrue(relatives.contains(Self.spawnExemptPath))
        var problems: [String] = []
        for (f, relative) in zip(files, relatives) {
            problems += Self.spawnProblems(in: try String(contentsOf: f, encoding: .utf8), relativePath: relative)
        }
        XCTAssertEqual(problems, [])
        // The exemption is not empty: Shell.swift really is where programs start.
        let shell = try String(contentsOf: root.appendingPathComponent(Self.spawnExemptPath), encoding: .utf8)
        XCTAssertTrue(Self.codeOnly(shell).contains("Process()"))
    }

    func testScannerDetectsEachBannedToken() {
        let samples: [String: String] = [
            "Process": "let p = Process()",
            "NSTask": "let t = NSTask()",
            "posix_spawn": "posix_spawn(&pid, path, nil, nil, argv, envp)",
            "exec family": "execve(path, argv, envp)",
            "system(": "system(\"ls\")",
            "popen": "let f = popen(\"ls\", \"r\")",
        ]
        for (label, code) in samples {
            let hit = Self.spawnProblems(in: "func f() {\n    \(code)\n}\n", relativePath: "TrashPanda/Bad.swift")
            XCTAssertTrue(hit.contains("TrashPanda/Bad.swift uses \(label)"), "\(label) must be found in: \(code)")
        }
        for variant in ["posix_spawnp(&pid, p, nil, nil, a, e)", "execv(p, a)", "Foundation.Process()", "Darwin.system(c)",
                        "Process.launchedProcess(launchPath: p, arguments: [])", "typealias P = Process"] {
            XCTAssertFalse(Self.spawnProblems(in: variant, relativePath: "A.swift").isEmpty, variant)
        }
    }

    func testScannerIgnoresCommentsAndStrings() {
        let texts = [
            "// Process() posix_spawn NSTask execve system( popen",
            "/// uses Process() here\nlet x = 1",
            "/* posix_spawn(...) /* nested NSTask */ popen */ let x = 1",
            "let s = \"Process() posix_spawn NSTask execve system( popen\"",
            "let s = \"say \\\"Process()\\\" now\"",
            "let s = #\"Process() \"quoted\" popen\"#",
            "let s = \"\"\"\nProcess()\nposix_spawn\n\"\"\"",
            "let info = ProcessInfo.processInfo.environment\nlet f = Font.system(size: 3)\nlet v = view.system()",
        ]
        for text in texts {
            XCTAssertEqual(Self.spawnProblems(in: text, relativePath: "A.swift"), [], text)
        }
        // A comment or a string does not hide the code that follows it.
        XCTAssertFalse(Self.spawnProblems(in: "let s = \"a\"; let p = Process()", relativePath: "A.swift").isEmpty)
        XCTAssertFalse(Self.spawnProblems(in: "/* x */ let p = Process()", relativePath: "A.swift").isEmpty)
        XCTAssertFalse(Self.spawnProblems(in: "// x\nlet p = Process()", relativePath: "A.swift").isEmpty)
        // Code inside an interpolation runs, so it counts.
        XCTAssertFalse(Self.spawnProblems(in: "let s = \"a \\(Process()) b\"", relativePath: "A.swift").isEmpty)
        XCTAssertFalse(Self.spawnProblems(in: "let s = \"a \\(f(\"x\", g())) \\(popen(a, b))\"", relativePath: "A.swift").isEmpty)
    }

    func testExemptionIsTheExactPathOnly() {
        let text = "let p = Process()"
        XCTAssertEqual(Self.spawnProblems(in: text, relativePath: "PandaCore/Shell.swift"), [])
        for path in ["TrashPanda/Shell.swift", "Shell.swift", "PandaCore/Shell.swiftx", "PandaCore/Shell.swift.bak",
                     "PandaCore/ShellExtras.swift", "Other/PandaCore/Shell.swift", "PandaCore/Sub/Shell.swift", "pandacore/shell.swift"] {
            XCTAssertFalse(Self.spawnProblems(in: text, relativePath: path).isEmpty, path)
        }
    }

    // MARK: Refused tools

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-hardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        Shell.searchDirsOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private static let shellNames = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "env", "xargs"]
    private static let signalNames = ["ki" + "ll", "ki" + "llall", "p" + "ki" + "ll", "launch" + "ctl"]

    /// A harmless script under the given name, in a folder that only this test uses. A refusal must not run it.
    private func marker(named name: String) throws -> (path: String, ran: URL) {
        let ran = dir.appendingPathComponent("ran-\(name)")
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\necho ran > '\(ran.path)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url.path, ran)
    }

    func testEveryShellNameIsRefusedAndNotRun() throws {
        for name in Self.shellNames + Self.signalNames {
            let (path, ran) = try marker(named: name)
            let r = Shell.run(path, [], timeout: 5)
            XCTAssertTrue(r.refused, name)
            XCTAssertEqual(r.status, -1, name)
            XCTAssertEqual(r.stderr, "The tool is not safe to run", name)
            XCTAssertFalse(r.timedOut, name)
            XCTAssertEqual(r.stdout, "", name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path), "\(name) must not run")
        }
    }

    func testTheRefusalListIsExactlyTheNamedTools() {
        XCTAssertEqual(Shell.refusedToolNames, Set(Self.shellNames + Self.signalNames))
    }

    func testNameIsComparedWithoutCase() throws {
        let (path, ran) = try marker(named: "BASH")
        XCTAssertTrue(Shell.run(path, [], timeout: 5).refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path))
    }

    func testTheRealSystemShellsAreRefused() {
        for path in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh", "/bin/csh", "/bin/tcsh", "/usr/bin/env"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let r = Shell.run(path, ["-c", "exit 0"], timeout: 5)
            XCTAssertTrue(r.refused, path)
            XCTAssertEqual(r.status, -1, path)
        }
    }

    func testAnAliasThatResolvesToAShellIsRefused() throws {
        for target in ["/bin/sh", "/bin/bash", "/usr/bin/env"] where FileManager.default.isExecutableFile(atPath: target) {
            let link = dir.appendingPathComponent("x-\((target as NSString).lastPathComponent)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: target))
            let r = Shell.run(link.path, ["-c", "echo hi"], timeout: 5)
            XCTAssertTrue(r.refused, "\(link.lastPathComponent) -> \(target)")
            XCTAssertEqual(r.stdout, "")
        }
        // A link to a link to a script that is named like a shell.
        let (real, ran) = try marker(named: "zsh")
        let first = dir.appendingPathComponent("first")
        let second = dir.appendingPathComponent("x")
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: URL(fileURLWithPath: real))
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)
        XCTAssertTrue(Shell.run(second.path, [], timeout: 5).refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path))
    }

    func testOtherToolsStillRun() throws {
        let (path, ran) = try marker(named: "sometool")
        let r = Shell.run(path, [], timeout: 5)
        XCTAssertFalse(r.refused)
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ran.path))
        // A link with another name to a trusted tool that is not on the list still runs.
        let link = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: path))
        XCTAssertFalse(Shell.run(link.path, [], timeout: 5).refused)
        XCTAssertFalse(Shell.run("/bin/echo", ["hi"], timeout: 5).refused)
    }

    func testToolNamesLikeGitAndDockerResolveAsBefore() throws {
        for name in ["git", "docker", "brew", "ollama", "xcrun", "osascript"] {
            XCTAssertFalse(Shell.refusedToolNames.contains(name), name)
        }
        XCTAssertEqual(Shell.resolve("osascript"), Shell.systemTools["osascript"])
        let (git, _) = try marker(named: "git")
        let (docker, _) = try marker(named: "docker")
        Shell.searchDirsOverride = [dir.path]
        XCTAssertEqual(Shell.resolve("git"), git)
        XCTAssertEqual(Shell.resolve("docker"), docker)
        XCTAssertFalse(Shell.run(git, [], timeout: 5).refused)
        XCTAssertFalse(Shell.run(docker, [], timeout: 5).refused)
        // Resolving still finds a file named like a shell. Running it is what is refused.
        let (shPath, _) = try marker(named: "sh")
        XCTAssertEqual(Shell.resolve("sh"), shPath)
        XCTAssertTrue(Shell.run(shPath, [], timeout: 5).refused)
    }
}
