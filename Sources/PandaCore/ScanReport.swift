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
/// - `bytes`: a whole number. It is the size of the item. For an item with tier `info`, and for an
///   item that is only an upper limit, the size is not part of any total.
/// - `location`: the text that the plain text output shows. It is not changed.
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
    }

    public var schema: Int
    public var disk: Disk
    public var findings: [Entry]

    /// Builds the report. `home` is the home folder. It is only used to write `~` in the ids.
    public init(_ result: ScanResult, home: String = NSHomeDirectory()) {
        schema = Self.currentSchema
        disk = Disk(total: result.disk.total, free: result.disk.free)
        findings = result.findings.map { f in
            Entry(id: Log.redact(f.id, home: home), group: f.ecosystem.rawValue, title: f.title, bytes: f.bytes,
                  tier: Self.tierName(f), rebuild: f.rebuild.key, location: f.location)
        }
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
                                                   "--click", "--backdrop", "--version", "--help"]

    /// nil when the options are fine. Else the message for stderr (without the usage text). The exit code is then 64.
    public static func error(_ arguments: [String]) -> String? {
        let args = arguments.dropFirst()
        let unknown = args.filter { $0.hasPrefix("-") && !knownOptions.contains($0) && !$0.hasPrefix("-psn_") }
        if !unknown.isEmpty { return "Unknown option: \(unknown.joined(separator: " "))" }
        if args.contains("--json") && !args.contains("--scan") { return "--json works only with --scan" }
        return nil
    }

    /// `scan` or `scan --json`, for the log.
    public static func mode(_ arguments: [String]) -> String {
        arguments.contains("--json") ? "scan --json" : "scan"
    }
}
