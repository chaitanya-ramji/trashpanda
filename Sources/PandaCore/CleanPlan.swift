import Foundation

/// What a clean of the safe items would do, decided for each finding. It only reads. It never changes a file.
/// `trashpanda --clean-safe --dry-run` prints it. A later step will use the same plan for the real clean.
///
/// An item would be cleaned only if all of this is true:
/// - it is not an information line,
/// - its tier is `safe`,
/// - it is not blocked,
/// - the path guard accepts its path now (this also catches a link, a path outside the home folder,
///   a protected folder, and the keep list),
/// - its owner app is not open (the command line cannot ask an app to quit, the menu can),
/// - and the one-click clean of the menu would take it (`isOneClickSafe`).
public struct CleanPlan: Sendable {
    public struct Item: Sendable {
        public let finding: Finding
        public let wouldClean: Bool
        /// A short fixed text. It is empty when `wouldClean` is true.
        public let skipReason: String
    }

    public let items: [Item]
    public let deleteMode: DeleteMode

    /// The one rule of the one-click clean of safe items. The menu (`MenuModel`) and this plan both use it,
    /// so the two cannot drift. `blockers` are the names of the open owner apps of the item.
    public static func isOneClickSafe(_ f: Finding, blockers: [String]) -> Bool {
        f.isActionable && f.tier == .safe && f.blockedReason == nil && blockers.isEmpty
    }

    public init(_ result: ScanResult, guardian: PathGuard, running: RunningSnapshot, deleteMode: DeleteMode) {
        self.deleteMode = deleteMode
        items = result.findings.map { f in
            let reason = Self.skipReason(f, guardian: guardian, running: running)
            return Item(finding: f, wouldClean: reason == nil, skipReason: reason ?? "")
        }
    }

    /// nil when the item would be cleaned. Else the short reason. The order of the checks is fixed.
    static func skipReason(_ f: Finding, guardian: PathGuard, running: RunningSnapshot) -> String? {
        if !f.isActionable { return "info only" }
        if f.tier != .safe { return "review item" }
        if let why = f.blockedReason { return "blocked: \(why)" }
        // The path is checked again now, because the disk can change after the scan.
        for url in paths(of: f, home: guardian.home) {
            switch guardian.check(url) {
            case nil: continue
            case .kept?: return "on the keep list"
            case let refusal?: return "refused by the path guard: \(refusal)"
            }
        }
        let blockers = f.owner.map { running.running($0) } ?? []
        if !blockers.isEmpty { return "owner app is open: \(blockers.joined(separator: " and "))" }
        if !isOneClickSafe(f, blockers: blockers) { return "not part of the one-click clean" }
        return nil
    }

    /// The paths that an action names. A tool action (Docker, Homebrew, ...) names none.
    static func paths(of f: Finding, home: String) -> [URL] {
        switch f.action {
        case .removeContents(let url), .removeArtifact(let url), .removeInstaller(let url), .removeArchive(let url),
             .removeUpdateDownloads(let url), .removeDeviceSupport(let url):
            return [url]
        case .removeCacheFolderContents(let name):
            // A name with a slash or a dot name is not a folder name. The guard refuses the path that results.
            return [URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/\(name)", isDirectory: true)]
        case .worktree(.remove(_, let path)):
            return [path]
        default:
            return []
        }
    }

    public var wouldClean: [Item] { items.filter(\.wouldClean) }
    public var skipped: [Item] { items.filter { !$0.wouldClean } }

    /// The bytes that the app adds to its totals for the items that would be cleaned.
    /// An upper-limit item counts 0, as in the app, because its bytes are also in another item.
    public var wouldFree: Int64 { wouldClean.reduce(0) { $0 + $1.finding.countedBytes } }

    /// How many items are skipped for each reason, most first.
    public var skipCounts: [(reason: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in skipped { counts[item.skipReason, default: 0] += 1 }
        return counts.map { (reason: $0.key, count: $0.value) }.sorted { ($0.count, $1.reason) > ($1.count, $0.reason) }
    }

    /// The text of `trashpanda --clean-safe --dry-run`. Each line ends with a new line.
    public func text(verbose: Bool) -> String {
        var out = ""
        let would = wouldClean
        let width = (would.map { $0.finding.ecosystem.name.count }.max() ?? 0) + 2
        for item in would {
            let f = item.finding
            out += "\(f.sizeText.padding(toLength: 14, withPad: " ", startingAt: 0))"
                + "\(f.ecosystem.name.padding(toLength: width, withPad: " ", startingAt: 0))\(f.title)  [\(f.location)]\n"
        }
        out += "\(would.count) \(would.count == 1 ? "item" : "items") would be cleaned. Would free \(ByteText.string(wouldFree))\n"
        if deleteMode == .trash {
            out += "Delete mode is trash: files would move to the Trash. Space comes back when the Trash is emptied.\n"
        }
        if !skipped.isEmpty {
            out += "\nSkipped: \(skipped.count) \(skipped.count == 1 ? "item" : "items")\n"
            if verbose {
                for item in skipped {
                    let f = item.finding
                    out += "  \(item.skipReason): \(f.ecosystem.name) · \(f.title)  [\(f.location)]\n"
                }
            } else {
                for entry in skipCounts { out += "  \(entry.count)  \(entry.reason)\n" }
            }
        }
        out += "Nothing was deleted.\n"
        return out
    }

    /// The numbers for the end line of the log.
    public func summary() -> String {
        let reasons = skipCounts.map { "\"\($0.reason)\"=\($0.count)" }.joined(separator: " ")
        return "wouldClean=\(wouldClean.count) skipped=\(skipped.count) wouldFree=\(wouldFree) reasons=[\(reasons)]"
    }
}

/// The JSON of the dry run. The finding objects are the same as in `ScanReport` (schema 1), plus `wouldClean` and `skipReason`.
///
/// - `mode`: always `dry-run`. Nothing was deleted.
/// - `deleteMode`: `permanent` or `trash`, from the settings.
/// - `totals.wouldFree`: the sum of `countedBytes` of the items with `wouldClean` true. An upper-limit item counts 0, as in the app.
/// - `findings[].wouldClean`: `true` only for an item that a clean of the safe items would take now.
/// - `findings[].skipReason`: a short fixed text. It is empty when `wouldClean` is true.
public struct DryRunReport: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var base: ScanReport.Entry
        public var wouldClean: Bool
        public var skipReason: String

        private enum Extra: String, CodingKey { case wouldClean, skipReason }

        init(base: ScanReport.Entry, wouldClean: Bool, skipReason: String) {
            self.base = base
            self.wouldClean = wouldClean
            self.skipReason = skipReason
        }

        public init(from decoder: Decoder) throws {
            base = try ScanReport.Entry(from: decoder)
            let c = try decoder.container(keyedBy: Extra.self)
            wouldClean = try c.decode(Bool.self, forKey: .wouldClean)
            skipReason = try c.decode(String.self, forKey: .skipReason)
        }

        public func encode(to encoder: Encoder) throws {
            try base.encode(to: encoder)
            var c = encoder.container(keyedBy: Extra.self)
            try c.encode(wouldClean, forKey: .wouldClean)
            try c.encode(skipReason, forKey: .skipReason)
        }

        /// The line for the log, one for each item, so that a run can be checked later.
        public var logLine: String {
            "dry-run item id=\(base.id) wouldClean=\(wouldClean) skipReason=\"\(skipReason)\" bytes=\(base.bytes)"
        }
    }

    public struct Totals: Codable, Equatable, Sendable {
        public var reclaimable: Int64
        public var reviewable: Int64
        public var wouldFree: Int64
    }

    public var schema: Int
    public var mode: String
    public var deleteMode: String
    public var disk: ScanReport.Disk
    public var totals: Totals
    public var findings: [Entry]

    public init(_ result: ScanResult, plan: CleanPlan, home: String = NSHomeDirectory()) {
        let scan = ScanReport(result, home: home)
        schema = scan.schema
        mode = "dry-run"
        deleteMode = plan.deleteMode.rawValue
        disk = scan.disk
        totals = Totals(reclaimable: scan.totals.reclaimable, reviewable: scan.totals.reviewable, wouldFree: plan.wouldFree)
        // The plan and the report keep the order of the scan.
        findings = zip(scan.findings, plan.items).map { Entry(base: $0, wouldClean: $1.wouldClean, skipReason: $1.skipReason) }
    }

    /// One compact JSON object with sorted keys, and a new line at the end.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
