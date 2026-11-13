import XCTest
@testable import PandaCore

/// Issue 221. Only `Shell.run` starts programs, and it never starts a shell or a tool that starts other programs.
final class ShellHardeningTests: XCTestCase {

    // MARK: Source scan

    /// The one file that may start programs. This is an exact path, relative to `Sources`. It is not a prefix.
    static let spawnExemptPath = "PandaCore/Shell.swift"

    /// Each pattern names a way to start a program outside `Shell.run`. It runs on code with strings removed.
    private static let spawnPatterns: [(label: String, regex: NSRegularExpression)] = [
        ("Process", #"\bProcess\b"#),
        ("NSTask", #"\bNSTask\b"#),
        ("posix_spawn", #"posix_spawn"#),
        ("exec family", #"\bf?exec(?:ve|v|vp|vP|l|le|lp)\b"#),
        ("system(", #"(?:(?<![\w.])|(?<=Darwin\.))system\s*\("#),
        ("popen", #"\bpopen\b"#),
        ("fork", #"\bv?fork\s*\("#),
        ("NSUserTask", #"\bNSUser(?:Unix|Script|AppleScript|Automator)Task\b"#),
        ("AppleScript", #"\b(?:NSAppleScript|OSAScript|OSAScriptController)\b"#),
        ("dlopen/dlsym", #"\bdl(?:open|sym|open_preflight)\b"#),
        ("name lookup by string", #"\b(?:NSClassFromString|NSSelectorFromString|NSProtocolFromString|objc_getClass|objc_lookUpClass|objc_getRequiredClass)\b"#),
        ("symbol attribute", #"@\s*_(?:silgen_name|extern|cdecl)\b"#),
        ("privileged launch", #"\b(?:AuthorizationExecuteWithPrivileges|SMJobSubmit|SMJobBless)\b"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// Each pattern runs on code where the text of the strings is kept. It names a shell or a script that a string can start.
    private static let stringPatterns: [(label: String, regex: NSRegularExpression)] = [
        ("shell path in a string", #"(?:^|[\s\x{1}'=])(?:/usr)?/bin/(?:sh|bash|zsh|dash|ksh|csh|tcsh|fish|env)\b"#),
        ("shell name as a string", #"\x{1}(?:sh|bash|zsh|dash|ksh|csh|tcsh|fish)\x{2}"#),
        ("shell script text", #"do shell script"#),
        ("command file", #"\x{1}[^\x{2}]*\.command\b"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// `NSWorkspace` can open a file or an app, and a `.command` file then runs in Terminal. These are the only
    /// files that may call it, with the exact number of calls. A new call site must be added here on purpose.
    static let workspaceOpenAllowed: [String: Int] = [
        // AppDelegate.swift has 4 calls that open something:
        //   line ~100: the first-start note's link to SECURITY.md
        //   line ~322: the help link
        //   line ~325: the report-a-problem link
        //   line ~337: opens the keep or roots list in TextEdit
        "TrashPanda/AppDelegate.swift": 4,
        "TrashPanda/Dialogs.swift": 1,
        "TrashPanda/UpdateController.swift": 1,
    ]
    private static let workspaceOpenCall = try! NSRegularExpression(
        pattern: #"\bNSWorkspace\b[\w.\s]*?\.(?:open|openApplication|openURL|openURLs|openFile|openTempFile|launchApplication|launchApp)\s*\("#)
    /// The same methods on any receiver, for the old names that no allowed file uses.
    private static let workspaceOldNames = try! NSRegularExpression(
        pattern: #"\.(?:openURLs|openFile|openTempFile|launchApplication|launchApp|openApplication)\s*\("#)

    /// Removes comments and string literals, so that a comment cannot hide a call and cannot cause a hit.
    /// Code inside a string interpolation `\( ... )` is kept, because it runs.
    /// In `keepStrings` mode, each string is written between these two marks, so a pattern can tell string text from code.
    static let openMark = "\u{1}"
    static let closeMark = "\u{2}"

    /// With `keepStrings`, the text of each string stays in the result, between the two marks. Comments and `#/.../#` regex literals are still removed.
    static func codeOnly(_ text: String, keepStrings: Bool = false) -> String {
        var i = 0
        let result = code(Array(text), &i, nested: false, keep: keepStrings)
        // A name in backticks (`remove`(p)) is the same name. The marks of strings do not contain a backtick that matters here.
        return result.replacingOccurrences(of: #"`([A-Za-z_][A-Za-z0-9_]*)`"#, with: "$1", options: .regularExpression)
    }

    /// The index after an extended regex literal `#/.../#` (or `##/.../##`) that starts at `i`, or nil when there is none.
    /// A bare `/.../` is NOT handled on purpose. This package uses Swift language mode 5 without the bare-slash regex feature
    /// (see `Package.swift`), so a bare slash is always a division or an operator there (for example `reduce(64, /)`).
    /// If the scan guessed that a slash starts a regex, it could hide real code after it. When nothing closes the literal,
    /// the text is scanned as normal code.
    private static func regexEnd(_ s: [Character], _ i: Int) -> Int? {
        func at(_ k: Int) -> Character? { k < s.count ? s[k] : nil }
        var hashes = 0
        while at(i + hashes) == "#" { hashes += 1 }
        guard hashes > 0, at(i + hashes) == "/" else { return nil }
        if at(i + hashes + 1) == "/" || at(i + hashes + 1) == "*" { return nil }   // a comment, not a regex
        // It may span lines. It ends at a slash with the same number of hashes.
        var j = i + hashes + 1
        while j < s.count {
            if s[j] == "\\" { j += 2; continue }
            if s[j] == "/", (0..<hashes).allSatisfy({ at(j + 1 + $0) == "#" }) { return j + 1 + hashes }
            j += 1
        }
        return nil
    }

    private static func code(_ s: [Character], _ i: inout Int, nested: Bool, keep: Bool = false) -> String {
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
            if c == "#" {
                if let end = regexEnd(s, i) {
                    i = end
                    out.append(" ")
                    continue
                }
            }
            if c == "\"" || c == "#" {
                var hashes = 0
                while at(i + hashes) == "#" { hashes += 1 }
                if at(i + hashes) == "\"" {
                    let multiline = at(i + hashes + 1) == "\"" && at(i + hashes + 2) == "\""
                    let quotes = multiline ? 3 : 1
                    i += hashes + quotes
                    var body = ""
                    while i < s.count {
                        if s[i] == "\\", (0..<hashes).allSatisfy({ at(i + 1 + $0) == "#" }) {
                            if at(i + 1 + hashes) == "(" {
                                i += 2 + hashes
                                out += " " + code(s, &i, nested: true, keep: keep) + " "
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
                        if keep { body.append(s[i]) }
                        i += 1
                    }
                    out += keep ? " \(openMark)\(body)\(closeMark) " : " \"\" "
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
        func found(_ regex: NSRegularExpression, in t: String) -> Int {
            regex.numberOfMatches(in: t, range: NSRange(t.startIndex..., in: t))
        }
        for (label, regex) in spawnPatterns where found(regex, in: code) > 0 {
            problems.append("\(relativePath) uses \(label)")
        }
        let withStrings = codeOnly(text, keepStrings: true)
        for (label, regex) in stringPatterns where found(regex, in: withStrings) > 0 {
            problems.append("\(relativePath) has a \(label)")
        }
        let opens = found(workspaceOpenCall, in: code)
        let allowed = workspaceOpenAllowed[relativePath, default: 0]
        if opens != allowed { problems.append("\(relativePath) calls NSWorkspace open \(opens) times, allowed \(allowed)") }
        if found(workspaceOldNames, in: code) > 0 { problems.append("\(relativePath) uses an old NSWorkspace launch call") }
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

    func testRegexLiteralsDoNotHideACall() {
        let hidden = [
            "let r = #/\"/#; let p = Process()",
            "let r = ##/\"#/##; let p = Process()",
            "let r = #/\n  \"\n/#\nlet p = Process()",
        ]
        for text in hidden {
            XCTAssertFalse(Self.spawnProblems(in: text, relativePath: "A.swift").isEmpty, text)
        }
        // A regex literal hides nothing from the scan, and a word in it is not a hit.
        let harmless = [
            "let r = #/Process|posix_spawn/#",
            "let r = #/a\\/Process/#",
        ]
        for text in harmless {
            XCTAssertEqual(Self.spawnProblems(in: text, relativePath: "A.swift"), [], text)
        }
        // Division is not a regex.
        XCTAssertFalse(Self.spawnProblems(in: "let a = x / 2; let b = y / 3; Process()", relativePath: "A.swift").isEmpty)
        XCTAssertFalse(Self.spawnProblems(in: "let a = (x)/2/\"q\"; Process()", relativePath: "A.swift").isEmpty)
        // A slash with no end is scanned as code.
        XCTAssertFalse(Self.spawnProblems(in: "let r = #/ never ends\nProcess()", relativePath: "A.swift").isEmpty)
    }

    func testScannerCatchesTheOtherLaunchVectors() {
        let cases: [String: String] = [
            "let t = NSUserUnixTask(url: u)": "NSUserTask",
            "let t = NSUserScriptTask(url: u)": "NSUserTask",
            "let t = NSUserAppleScriptTask(url: u)": "NSUserTask",
            "let t = NSUserAutomatorTask(url: u)": "NSUserTask",
            "let s = NSAppleScript(source: x)": "AppleScript",
            "let s = OSAScript(source: x)": "AppleScript",
            "let h = dlopen(nil, RTLD_NOW)": "dlopen/dlsym",
            "let f = dlsym(h, \"posix_\" + \"spawn\")": "dlopen/dlsym",
            "let c = NSClassFromString(\"NS\" + \"Task\")": "name lookup by string",
            "let c: AnyClass? = objc_getClass(\"NSTask\") as? AnyClass": "name lookup by string",
            "let s = NSSelectorFromString(x)": "name lookup by string",
            "let pid = fork()": "fork",
            "let pid = vfork ()": "fork",
            "fexecve(fd, a, e)": "exec family",
            "execle(p, a, nil, e)": "exec family",
            "posix_spawn_file_actions_init(&fa)": "posix_spawn",
            "AuthorizationExecuteWithPrivileges(a, p, f, args, nil)": "privileged launch",
            "NSWorkspace.shared.open(url)": "NSWorkspace",
            "NSWorkspace.shared.openApplication(at: u, configuration: c, completionHandler: nil)": "NSWorkspace",
            "let w = NSWorkspace.shared\nw.launchApplication(\"Terminal\")": "NSWorkspace",
            "NSWorkspace.shared.open([f], withApplicationAt: a, configuration: c)": "NSWorkspace",
            "let a = \"/bin/sh\"": "shell path in a string",
            "let a = \"/bin/bash -c ls\"": "shell path in a string",
            "let a = #\"/usr/bin/env\"#": "shell path in a string",
            "let a = \"\\(x) /bin/zsh\"": "shell path in a string",
            "let a = [\"sh\", \"-c\", cmd]": "shell name as a string",
            "let a = \"bash\"": "shell name as a string",
            "let a = \"tell app \\\"Terminal\\\" to do shell script \\\"ls\\\"\"": "shell script text",
            "let u = dir.appendingPathComponent(\"x.command\")": "command file",
        ]
        for (code, label) in cases {
            let hit = Self.spawnProblems(in: "func f() {\n    \(code)\n}\n", relativePath: "TrashPanda/Bad.swift")
            XCTAssertTrue(hit.contains { $0.contains(label) }, "\(label) must be found in: \(code)\n\(hit)")
        }
    }

    func testSymbolAttributesAreCaught() {
        let bad = [
            "@_silgen_name(\"posix_spawn\") func ps(_ a: Int) -> Int",
            "@_silgen_name(\"execve\") func ev()",
            "@_silgen_name(\"system\") func sy(_ c: UnsafePointer<CChar>) -> Int32",
            "@_extern(c, \"posix_spawn\") func ps()",
            "@_cdecl(\"posix_spawn\") func ps() {}",
            "@_silgen_name  (\"x\")\nfunc f()",
            "@ _silgen_name(\"posix_spawn\") func ps()",
            "@\n_cdecl(\"x\") func f() {}",
            "@/*x*/_cdecl(\"y\") func q() {}",
        ]
        for text in bad {
            XCTAssertTrue(Self.spawnProblems(in: text, relativePath: "A.swift").contains("A.swift uses symbol attribute"), text)
        }
        // A comment or a string that names the attribute is not a hit.
        for text in ["// @_silgen_name(\"x\")\nlet a = 1", "let s = \"@_cdecl @_extern\"", "let a = 1 /* @_silgen_name */"] {
            XCTAssertEqual(Self.spawnProblems(in: text, relativePath: "A.swift"), [], text)
        }
    }

    func testSlashAfterPostfixBangIsDivision() {
        for text in ["let x = b!/2; let p = Process(); let y = 4/2", "let x = b!/\"q\"; Process()"] {
            XCTAssertTrue(Self.spawnProblems(in: text, relativePath: "A.swift").contains("A.swift uses Process"), text)
        }
    }

    func testBareSlashOperatorsNeverHideCode() {
        // Swift mode 5 has no bare-slash regex, so `/` is an operator or a division. Each text below compiles with `-swift-version 5`.
        let texts = [
            "let q = [8.0, 2.0].reduce(64, /); let p = Process(); let r = 1.0/2.0",
            "let f: (Double, Double) -> Double = (/); let p = Process(); let r2 = 1.0/2.0",
            "let q = [8.0, 2.0].reduce(64, /); posix_spawn(&pid, p, nil, nil, a, e); let r = 1.0/2.0",
        ]
        for text in texts {
            XCTAssertFalse(Self.spawnProblems(in: text, relativePath: "A.swift").isEmpty, text)
        }
        // The extended literal is still removed, and a bare slash pair is not a literal.
        XCTAssertEqual(Self.spawnProblems(in: "let r = #/Process()/#", relativePath: "A.swift"), [])
        XCTAssertFalse(Self.spawnProblems(in: "let r = /Process()/", relativePath: "A.swift").isEmpty)
    }

    func testBackticksDoNotHideAName() {
        XCTAssertFalse(Self.spawnProblems(in: "let p = `Process`()", relativePath: "A.swift").isEmpty)
        XCTAssertTrue(Self.codeOnly("_ = `remove`(p)").contains("remove(p)"))
    }

    func testTypeAliasesOfProcessAreCaught() {
        for text in ["typealias Runner = Foundation.Process", "typealias R = Process\nlet r = R()",
                     "import Foundation\nextension Process { }", "let t = (Process).self", "func f(_ p: Process) {}",
                     "let t: Process.Type = Process.self"] {
            XCTAssertFalse(Self.spawnProblems(in: text, relativePath: "A.swift").isEmpty, text)
        }
    }

    func testScannerLeavesHarmlessCodeAlone() {
        let harmless = [
            "let s = \"shell\"; let b = \"bashful\"; let e = \"/usr/bin/envelope\"",
            "let a = \"commands\"; let b = x.command; let c = \"my.commandline\"",
            "let w = NSWorkspace.shared.runningApplications",
            "let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b)",
            "NSWorkspace.shared.activateFileViewerSelecting([u])",
            "NSWorkspace.shared.notificationCenter.addObserver(self, selector: s, name: n, object: nil)",
            "let f = FileHandle.standardOutput; try f.close(); let d = Dialog.open(x)",
            "let forked = 1; let fork_count = 2; let platform = \"dlopen\"",
            "// NSAppleScript dlopen fork() NSClassFromString \"/bin/sh\"\nlet x = 1",
            "let s = \"NSUserUnixTask and do shell script\"".replacingOccurrences(of: "do shell script", with: "x"),
            "let ratio = a / b; let c = d / e",
            "let p = ProcessInfo.processInfo; let q = ProcessInfo()",
        ]
        for text in harmless {
            XCTAssertEqual(Self.spawnProblems(in: text, relativePath: "A.swift"), [], text)
        }
    }

    func testWorkspaceOpenNeedsAnAllowedFileAndAnExactCount() {
        let one = "NSWorkspace.shared.open(url)\n"
        XCTAssertEqual(Self.spawnProblems(in: one, relativePath: "TrashPanda/Dialogs.swift"), [],
                       "One call in an allowed file must pass.")
        XCTAssertFalse(Self.spawnProblems(in: one + one, relativePath: "TrashPanda/Dialogs.swift").isEmpty,
                       "Two calls in a file that allows one must be reported.")
        XCTAssertFalse(Self.spawnProblems(in: "let x = 1", relativePath: "TrashPanda/Dialogs.swift").isEmpty,
                       "The allowance is exact. A file that no longer calls it must leave the list.")
        XCTAssertFalse(Self.spawnProblems(in: one, relativePath: "PandaCore/Other.swift").isEmpty,
                       "A call in a file that is not on the list must be reported.")
        XCTAssertFalse(Self.spawnProblems(in: one, relativePath: "TrashPanda/Dialogs.swift.bak").isEmpty,
                       "The allowed path is exact, so a copy with a suffix must be reported.")
        XCTAssertEqual(Self.spawnProblems(in: "// NSWorkspace.shared.open(url)\nlet s = \"NSWorkspace.shared.open(\"", relativePath: "A.swift"), [])
    }

    // MARK: Package and file layout

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Returns a problem for each target that sets a `path:` outside `Sources/`, so that the scan would not see it.
    static func packagePathProblems(in manifest: String) -> [String] {
        let code = codeOnly(manifest, keepStrings: true)
        let regex = try! NSRegularExpression(pattern: #"\bpath:\s*\x{1}([^\x{2}]*)\x{2}"#)
        var problems: [String] = []
        for m in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            let path = String(code[Range(m.range(at: 1), in: code)!])
            let clean = (path as NSString).standardizingPath
            if !clean.hasPrefix("Sources/") && !clean.hasPrefix("./Sources/") || clean.contains("..") {
                problems.append("a target has the path \(path), outside Sources")
            }
        }
        for word in [" sources:", "(sources:", ".binaryTarget", ".plugin(", ".systemLibrary", ".macro("]
        where code.contains(word) { problems.append("Package.swift uses \(word)") }
        return problems
    }

    func testPackageManifestKeepsEveryTargetUnderSources() throws {
        let manifest = try String(contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertEqual(Self.packagePathProblems(in: manifest), [])
    }

    func testPackageScanFindsABadPath() {
        XCTAssertFalse(Self.packagePathProblems(in: ".target(name: \"A\", path: \"Vendor/A\")").isEmpty,
                       "A target path outside Sources must be reported.")
        XCTAssertFalse(Self.packagePathProblems(in: ".target(name: \"A\", path: \"Sources/../Vendor\")").isEmpty,
                       "A path that leaves Sources with .. must be reported.")
        XCTAssertFalse(Self.packagePathProblems(in: ".target(name: \"A\", path: \"../x\")").isEmpty,
                       "A path above the package must be reported.")
        XCTAssertFalse(Self.packagePathProblems(in: ".binaryTarget(name: \"A\", path: \"Sources/A.xcframework\")").isEmpty,
                       "A binary target must be reported.")
        XCTAssertFalse(Self.packagePathProblems(in: ".target(name: \"A\", sources: [\"../x.swift\"])").isEmpty,
                       "A sources list must be reported.")
        XCTAssertEqual(Self.packagePathProblems(in: ".target(name: \"A\", path: \"Sources/A\")\n// path: \"Vendor\""), [])
        XCTAssertEqual(Self.packagePathProblems(in: ".target(name: \"PandaCore\")"), [])
    }

    func testSourcesHoldOnlySwiftCode() throws {
        let root = Self.packageRoot.appendingPathComponent("Sources")
        let bad = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { ["c", "m", "mm", "h", "cpp", "cc", "s", "S", "sh", "command", "py", "scpt", "applescript"].contains($0.pathExtension) }
        XCTAssertEqual(bad.map(\.lastPathComponent), [], "The scan reads Swift files only")
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
