import Foundation

/// The result of a scan as plain data for scripts (`trashpanda --scan --json`).
///
/// This is schema 1. Inside schema 1 a field is never removed and never changes its meaning.
/// A new field can be added, so a reader must ignore a key that it does not know.
///
/// - `id`: the id of the finding in the catalog. It is made from fixed names (and, for a folder
///   that the user owns, from its path), never from a random value or a time. The same finding
///   has the same id in each run. The home folder is written as `~`, so the id does not
///   depend on the user name.
/// - `group`: the language or tool group. It is the raw name of `Ecosystem`, for example `swift`,
///   `javascript`, `homebrew`, `aiAgents`. A new group can appear in a later version.
/// - `tier`: `safe` (cheap to rebuild, in the one-click clean), `review` (the user must choose it),
///   or `info` (shown for information only, it cannot be cleaned).
/// - `rebuild`: `seconds`, `minutes`, `download`, `recreate`, or `never`.
/// - `bytes`: a whole number. It is the size of the item, as measured.
/// - `blocked`: always present. `true` when the app shows the item but cannot clean it now
///   (`Finding.blockedReason` is set at scan time).
/// - `blockedReason`: always present. The same text as the menu shows. It is empty when `blocked` is `false`.
/// - `upperLimit`: always present. `true` when `bytes` is only an upper limit (the menu shows "up to").
/// - `countedBytes`: always present. The bytes that the app adds to its totals. It is 0 for an item with
///   tier `info`, for a blocked item, and for an upper-limit item.
/// - `location`: the text that the plain text output shows. It can hold a full path. It is not changed.
/// - `totals.reclaimable` and `totals.reviewable`: the numbers of "Reclaim now" and "To review" in the text.
///   The sum of `countedBytes` of the items with tier `safe` is `reclaimable`. The same is true for `review`.
///
/// `tier` is only the category (`safe`, `review`, `info`). It does not say if the item can be cleaned now:
/// use `blocked` for that. An item can be cleaned by a script only when `tier` is `safe` and `blocked` is
/// `false`. Whether the owner app is running, and the keep list, are checked at clean time. A script must never
/// take an id as delete input.
///
/// Later steps (a dry run, a clean) will reuse these same entry objects and add fields to them.
///
/// An id is an opaque string. It is unique inside one report. It can be an absolute path when the item is
/// outside the home folder.
public struct ScanReport: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public struct Disk: Codable, Equatable, Sendable {
        public var total: Int64
        public var free: Int64
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var group: String
        public var title: String
        public var bytes: Int64
        public var tier: String
        public var rebuild: String
        public var location: String
        public var blocked: Bool
        public var blockedReason: String
        public var upperLimit: Bool
        public var countedBytes: Int64
    }

    public struct Totals: Codable, Equatable, Sendable {
        public var reclaimable: Int64
        public var reviewable: Int64
    }

    public var schema: Int
    public var disk: Disk
    public var totals: Totals
    public var findings: [Entry]

    /// Builds the report. `home` is the home folder. It is only used to write `~` in the ids.
    public init(_ result: ScanResult, home: String = NSHomeDirectory()) {
        schema = Self.currentSchema
        disk = Disk(total: result.disk.total, free: result.disk.free)
        findings = result.findings.map { f in
            Entry(id: Self.id(f.id, home: home), group: f.ecosystem.rawValue, title: f.title, bytes: f.bytes,
                  tier: Self.tierName(f), rebuild: f.rebuild.key, location: f.location,
                  blocked: f.blockedReason != nil, blockedReason: f.blockedReason ?? "",
                  upperLimit: f.sizeIsUpperLimit, countedBytes: f.isActionable ? f.countedBytes : 0)
        }
        totals = Totals(reclaimable: result.reclaimable, reviewable: result.reviewable)
    }

    /// Writes the home folder as `~` at the start of an id, and at the start of the part after a `kind:` colon:
    /// `~` when it is the home folder, `~/rest` when it starts with the home folder and a slash, else it is not changed.
    /// So `/Users/al` does not change `/Users/alice/x`. An id can start with a kind and a colon, for example
    /// `worktree:/Users/al/x`. The kind is kept and the rest is rewritten the same way (it can repeat for a second colon).
    public static func id(_ text: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            let rest = String(text[text.index(after: colon)...])
            return text[...colon] + id(rest, home: home)
        }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        if text == base { return "~" }
        if text.hasPrefix(base + "/") { return "~/" + text.dropFirst(base.count + 1) }
        return text
    }

    /// `info` for an item that cannot be cleaned, else `safe` or `review`.
    public static func tierName(_ f: Finding) -> String {
        !f.isActionable ? "info" : (f.tier == .safe ? "safe" : "review")
    }

    /// One compact JSON object with sorted keys, and a new line at the end.
    /// There is no date inside, so the same scan gives the same bytes.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain strings and numbers does not fail.
        let data = (try? encoder.encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The text of `trashpanda --scan`. Each line ends with a new line. The "Scanned in" line is not part of it.
    public static func text(_ result: ScanResult) -> String {
        var out = "\(ByteText.string(result.disk.free)) free of \(ByteText.string(result.disk.total))\n"
        out += "Reclaim now: \(ByteText.string(result.reclaimable)) · To review: \(ByteText.string(result.reviewable))\n\n"
        // The name column is as wide as the longest name, plus 2.
        let nameWidth = (result.findings.map { $0.ecosystem.name.count }.max() ?? 0) + 2
        for f in result.findings {
            let tier = !f.isActionable ? "info  " : (f.tier == .safe ? "safe  " : "review")
            out += "\(tier)  \(ByteText.string(f.bytes).padding(toLength: 9, withPad: " ", startingAt: 0))"
                + "\(f.ecosystem.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))\(f.title)  [\(f.location)]\n"
        }
        return out
    }

    /// The numbers for the end line of the log.
    public static func summary(_ result: ScanResult) -> String {
        let tiers = result.findings.map(tierName)
        return "findings=\(tiers.count) safe=\(tiers.filter { $0 == "safe" }.count) review=\(tiers.filter { $0 == "review" }.count)"
            + " info=\(tiers.filter { $0 == "info" }.count) reclaimable=\(result.reclaimable) reviewable=\(result.reviewable)"
    }
}

extension Rebuild {
    /// The fixed name in the JSON report. It never changes inside schema 1.
    public var key: String {
        switch self {
        case .seconds: return "seconds"
        case .minutes: return "minutes"
        case .download: return "download"
        case .recreate: return "recreate"
        case .never: return "never"
        }
    }
}

/// The options of the command line, checked without any side effect.
public enum CommandLineCheck {
    public static let knownOptions: Set<String> = ["--scan", "--json", "--write-icons", "--demo", "--dialog", "--submenu", "--hover",
                                                   "--click", "--backdrop", "--version", "--help", "--clean-safe", "--dry-run", "--yes", "--verbose"]

    /// nil when the options are fine. Else the message for stderr (without the usage text). The exit code is then 64.
    public static func error(_ arguments: [String]) -> String? {
        let args = arguments.dropFirst()
        let unknown = args.filter { $0.hasPrefix("-") && !knownOptions.contains($0) && !$0.hasPrefix("-psn_") }
        // The message never repeats the text of an argument: it could be a secret (`--password=...`, `-psn_...`).
        if !unknown.isEmpty { return "Unknown option" }
        // `--yes` is for the real clean (`--clean-safe --yes`). It deletes, so it mixes with nothing else.
        if args.contains("--yes") {
            if !args.contains("--clean-safe") { return "--yes works only with --clean-safe" }
            let others = ["--dry-run", "--scan", "--demo", "--write-icons", "--dialog", "--submenu", "--hover", "--click", "--backdrop",
                          "--version", "--help"].filter { args.contains($0) }
            if !others.isEmpty { return "--yes cannot be used with \(others.joined(separator: " "))" }
        }
        // `--write-icons` needs a folder. Without it the app would start by chance.
        if let i = args.firstIndex(of: "--write-icons") {
            let next = args.index(after: i)
            if next >= args.endIndex || args[next].hasPrefix("-") { return "--write-icons needs a folder" }
        }
        // `--demo` shows made-up data in the app. It does not mix with a command that scans.
        if args.contains("--demo") && (args.contains("--scan") || args.contains("--clean-safe") || args.contains("--dry-run")) {
            return "--demo cannot be used with --scan, --clean-safe, or --dry-run"
        }
        if args.contains("--scan") && args.contains("--clean-safe") { return "Use --scan or --clean-safe, not both" }
        if args.contains("--clean-safe") && !args.contains("--dry-run") && !args.contains("--yes") {
            return "--clean-safe needs --dry-run (a preview) or --yes (a real clean)"
        }
        if args.contains("--dry-run") && !args.contains("--clean-safe") { return "--dry-run works only with --clean-safe" }
        if args.contains("--json") && !args.contains("--scan") && !args.contains("--clean-safe") {
            return "--json works only with --scan or with --clean-safe (--dry-run or --yes)"
        }
        // `--verbose` only changes the text of the dry run. It is an error anywhere else, so that it never starts the app by chance.
        if args.contains("--verbose") && args.contains("--json") { return "--verbose cannot be used with --json" }
        if args.contains("--verbose") && !(args.contains("--clean-safe") && (args.contains("--dry-run") || args.contains("--yes"))) {
            return "--verbose works only with --clean-safe --dry-run or --clean-safe --yes"
        }
        return strictError(args.map { $0 })
    }

    /// The two commands that read the disk for a clean (`--clean-safe --dry-run`) and that delete (`--clean-safe --yes`) take ONLY
    /// their own options, each one at most once. A value, an empty text, a repeated option, or the launcher argument `-psn_...`
    /// is a mistake here: the run would go on with a command that the caller did not mean. The launcher argument is accepted
    /// only where the menu bar app starts. The message never repeats a value, because a value could be a secret.
    private static func strictError(_ args: [String]) -> String? {
        let deleting = args.contains("--yes"), preview = args.contains("--dry-run")
        guard args.contains("--clean-safe"), deleting || preview else { return nil }
        let command = deleting ? "--clean-safe --yes" : "--clean-safe --dry-run"
        let allowed: Set<String> = deleting ? ["--clean-safe", "--yes", "--json", "--verbose"]
                                            : ["--clean-safe", "--dry-run", "--json", "--verbose"]
        if args.contains(where: { !$0.hasPrefix("-") }) {
            return "\(command) takes no value. Only these options are allowed: \(allowed.sorted().joined(separator: " "))"
        }
        let foreign = args.filter { !allowed.contains($0) }
        if !foreign.isEmpty {
            // Only an option that this program knows is named. Any other argument (for example `-psn_...`) is never repeated.
            let known = foreign.filter { knownOptions.contains($0) }
            return "\(command) cannot be used with \(known.isEmpty ? "other arguments" : known.joined(separator: " "))"
        }
        if let twice = args.first(where: { option in args.filter { $0 == option }.count > 1 }) { return "\(twice) was given more than once" }
        return nil
    }

    /// What a command does with the home folder. `read` commands (`--scan`, `--clean-safe --dry-run`) only read, so a home that is a link
    /// is allowed. The `clean` command deletes, so its home must be its own real path.
    public enum HomeUse { case read, clean
        var done: String { self == .clean ? "cleaned" : "scanned" }
    }

    /// nil when the home values are fine. Else the message for stderr (exit code 1). `CFFIXED_USER_HOME` and `HOME` must be not set or
    /// plain absolute paths, and the home of the system must be a plain absolute path. A value like `~`, `.`, `sub`, or an empty text
    /// is refused. This reads text only: it never expands `~` and never standardizes a path (that can call itself without end).
    public static func homeError(_ values: (cffixedUserHome: String?, home: String?, resolved: String), use: HomeUse = .clean) -> String? {
        let bad = [values.cffixedUserHome, values.home].contains { $0 != nil && !Log.isPlainAbsolute($0 ?? "") }
        if bad || !Log.isPlainAbsolute(values.resolved) {
            return "CFFIXED_USER_HOME, HOME, or the home folder is not an absolute path. Nothing was \(use.done)."
        }
        return nil
    }

    /// True when both paths are the same folder (links are followed, and the letter case does not matter on a volume that ignores it).
    /// A path that cannot be read is never the same.
    private static func sameFolder(_ a: String, _ b: String) -> Bool {
        var x = stat(), y = stat()
        guard stat(a, &x) == 0, stat(b, &y) == 0 else { return false }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    /// The full home check for every command that scans: the values are plain absolute paths, and the home exists, is a folder, and is
    /// not `/`. `HOME`, when it is set, must be the same folder as the home that is used: the tools that the scan starts (npm, brew,
    /// yarn, pnpm) get `HOME`, and they would write in another folder. For `.clean` the home must also be its own real path (no link,
    /// and no other letter case, in the path). A `.read` command allows a link: it only reads, and the plan marks each item below a link
    /// as skipped. It reads and never writes. nil means fine.
    /// `message` goes to stderr (exit 1). `logLine` is nil when no log line may be written: a missing home, or a `HOME` that is not
    /// the home, must get none.
    public static func homeProblem(_ values: (cffixedUserHome: String?, home: String?, resolved: String), use: HomeUse = .clean)
        -> (message: String, logLine: String?)? {
        if let message = homeError(values, use: use) { return (message, "cli: home folder is not a plain absolute path, exit 1") }
        let home = URL(fileURLWithPath: values.resolved).standardizedFileURL
        var isFolder: ObjCBool = false
        guard home.path != "/", FileManager.default.fileExists(atPath: home.path, isDirectory: &isFolder), isFolder.boolValue else {
            return ("The home folder could not be found. Nothing was \(use.done).", nil)
        }
        if let env = values.home, !env.isEmpty, !sameFolder(env, home.path) {
            return ("HOME and the home folder are not the same folder. Set both CFFIXED_USER_HOME and HOME to the same folder. Nothing was \(use.done).", nil)
        }
        if use == .clean, !UpdateDownloads.isPlainPath(home) {
            return (homeNotRealPathMessage, "cli: home folder path is not its real path, exit 1")
        }
        return nil
    }

    /// The last lines of the text of a dry run when the home is a link, or has another letter case.
    public static let linkedHomeNote =
        "Note: the home folder path is a link, or is not its real path. Each item below a link is skipped (a folder in the path is a link), so nothing would be cleaned.\n"

    public static let homeNotRealPathMessage =
        "The home folder path is not the same as its real path (a link in the path, or another letter case). Use the real path of the home folder. Nothing was cleaned."

    /// The options for the log. It names only the known options that are present, and counts the others.
    /// It never holds the text of another argument (it could be a secret).
    public static func logOptions(_ arguments: [String]) -> String {
        let args = Array(arguments.dropFirst())
        let known = args.filter { knownOptions.contains($0) }
        return "options=\(known.joined(separator: " ")) other=\(args.count - known.count)"
    }

    /// True for `--clean-safe --dry-run` (the options are fine, see `error`).
    public static func isDryRun(_ arguments: [String]) -> Bool {
        arguments.contains("--clean-safe") && arguments.contains("--dry-run")
    }

    /// True for `--clean-safe --yes` (the options are fine, see `error`). This is the one command that deletes.
    public static func isClean(_ arguments: [String]) -> Bool {
        arguments.contains("--clean-safe") && arguments.contains("--yes")
    }

    /// `scan`, `clean-safe --dry-run`, or `clean-safe --yes`, with `--json` when it is there, for the log.
    public static func mode(_ arguments: [String]) -> String {
        let base = isClean(arguments) ? "clean-safe --yes" : isDryRun(arguments) ? "clean-safe --dry-run" : "scan"
        return arguments.contains("--json") ? base + " --json" : base
    }
}
