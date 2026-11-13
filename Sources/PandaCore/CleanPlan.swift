import Foundation

/// What a clean of the safe items would do, decided for each finding. It only reads. It never changes a file.
/// `trashpanda --clean-safe --dry-run` prints it. A later step will use the same plan for the real clean.
///
/// An item would be cleaned only if all of this is true. The checks run in this order, and only the FIRST failing check is shown:
/// 1. it is not an information line (`info only`),
/// 2. its tier is `safe` (`review item`),
/// 3. it is not blocked (`blocked: ...`),
/// 4. the path guard accepts each path now (`on the keep list`, `refused by the path guard: ...`). The guard also catches
///    a link in the path itself, a path outside the home folder, and a protected folder,
/// 5. the path is still there, and the places that the Cleaner finds again are not empty (`not there now`, `nothing to clean now`),
/// 6. for an item that empties a folder: each target is a folder that can be listed now (`not a readable folder`). The check runs
///    right after step 5, before the shape checks. A folder with children that cannot be deleted (for example mode 0o555) passes
///    this step, so the real clean can still report a partial result for it,
/// 7. no link is in any part of the path, and the path has the shape that the Cleaner accepts for this action. These are the
///    same functions that the Cleaner calls (`CleanRules`). The link check is made only for the actions where the Cleaner makes it
///    (`a folder in the path is a link`, `not the kind of path that the clean takes`),
/// 8. for a build folder: no program runs in its project (`project is in use`), when the list of working folders is known,
/// 9. its owner app is not open (`owner app is open (name)`). The command line cannot ask an app to quit, the menu can,
/// 10. and the one-click clean of the menu would take it (`isOneClickSafe`). Step 10 is a safety net: steps 1 to 3 and 9 already
///    cover its rule, so no item can fail it alone.
///
/// The Cleaner ALWAYS runs the path guard and the shape checks again right before it deletes, for every item. That is not
/// shown per item. Some parts cannot be decided now at all (a tool decides, an app can start, an age changes). Each item that
/// has such a part names it in `checkedAtCleanTime`. An empty `checkedAtCleanTime` means only that the plan knows no such part.
public struct CleanPlan: Sendable {
    public struct Item: Sendable {
        public let finding: Finding
        public let wouldClean: Bool
        /// A short fixed text. It is empty when `wouldClean` is true.
        public let skipReason: String
        /// True when a check of the path ran at plan time. It says what ran, not what is sure: for most items it is the guard and the
        /// shape checks of the Cleaner, for a worktree it is the guard only.
        public let checkedNow: Bool
        /// Empty, or a short fixed text that says which part only the Cleaner decides at clean time (a tool, an app, an age).
        /// Empty does not mean that nothing is checked later: the Cleaner always runs the guard and the shape checks again.
        /// It is always empty for a skipped item.
        public let checkedAtCleanTime: String
    }

    /// The reason of the last step. No item can reach it alone (see the type comment).
    public static let safetyNetReason = "not part of the one-click clean"

    public let items: [Item]
    public let deleteMode: DeleteMode

    /// The one rule of the one-click clean of safe items. The menu (`MenuModel`) and this plan both use it,
    /// so the two cannot drift. `blockers` are the names of the open owner apps of the item.
    public static func isOneClickSafe(_ f: Finding, blockers: [String]) -> Bool {
        f.isActionable && f.tier == .safe && f.blockedReason == nil && blockers.isEmpty
    }

    /// - `activeDirectories`: the working folders of the running programs, when the caller has them. nil means unknown:
    ///   then a build folder is not checked for use now, and it says that the Cleaner reads it again. The plan never runs a program to find out.
    public init(_ result: ScanResult, guardian: PathGuard, running: RunningSnapshot, deleteMode: DeleteMode,
                activeDirectories: [String]? = nil, now: Date = Date()) {
        self.deleteMode = deleteMode
        items = result.findings.map { f in
            let d = Self.decide(f, guardian: guardian, running: running, active: activeDirectories, now: now)
            return Item(finding: f, wouldClean: d.reason == nil, skipReason: d.reason ?? "", checkedNow: d.checkedNow,
                        checkedAtCleanTime: d.reason == nil ? d.atClean : "")
        }
    }

    struct Decision {
        var reason: String?
        var checkedNow: Bool
        var atClean: String
    }

    /// What the plan reads for one finding.
    struct Inspection {
        /// The paths that the action names. Each one passes the guard.
        var targets: [URL] = []
        /// The name that the guard lets through for one folder of macOS or iCloud (only the cache explorer).
        var allowingSystemCache: String?
        /// The targets must exist.
        var mustExist = false
        /// Each target must be a folder that can be read. The Cleaner lists the folder, and it fails when it cannot.
        var mustBeReadableFolder = false
        /// The shape check of the Cleaner for each target. nil means that the Cleaner has none.
        var shape: ((URL) -> Bool)?
        /// The places that the Cleaner finds again from a fixed rule. nil means that the action has no such list.
        var resolved: [URL]?
        var resolvedShape: ((URL) -> Bool)?
        /// The rule cannot be read (for example an unknown browser id).
        var shapeProblem = false
        /// For a build folder: the folder, so that its project can be checked.
        var artifact: URL?
        /// The Cleaner has one more check with its own text (an installer must be old enough). True means that it fails.
        var extraShapeFailure: (() -> Bool)?
        var atClean: [String] = []
        /// True when a path check ran, so the item is checked now.
        var checked: Bool { !targets.isEmpty || resolved != nil || shapeProblem }
    }

    private static let toolText = "tool decides"
    private static let foundAgainText = "targets are found again"
    private static let wrongShape = "not the kind of path that the clean takes"
    private static let linkInPath = "a folder in the path is a link"
    private static let notReadableFolder = "not a readable folder"

    static func inspect(_ f: Finding, home: URL, now: Date) -> Inspection {
        var i = Inspection()
        switch f.action {
        case .removeContents(let url):
            i.targets = [url]; i.mustExist = true; i.mustBeReadableFolder = true
        case .removeArtifact(let url):
            i.targets = [url]; i.mustExist = true; i.shape = CleanRules.isArtifactTarget; i.artifact = url
            i.atClean = ["project use is read again"]
        case .removeInstaller(let url):
            i.targets = [url]; i.mustExist = true
            i.shape = { Installers.isInstallerPath($0, home: home) }
            i.extraShapeFailure = { Installers.read(url, home: home, now: now) == nil }
            i.atClean = ["mounted disk images are read again"]
        case .removeArchive(let url):
            i.targets = [url]; i.mustExist = true; i.shape = { CleanRules.isArchiveTarget($0, home: home) }
        case .removeDeviceSupport(let url):
            i.targets = [url]; i.mustExist = true; i.shape = { CleanRules.isDeviceSupportTarget($0, home: home) }
        case .removeUpdateDownloads(let sparkle):
            i.targets = [sparkle]; i.mustExist = true; i.shape = { CleanRules.isSparkleTarget($0, home: home) }
            i.resolved = UpdateDownloads.staleItems(in: sparkle, now: now)
            i.resolvedShape = { CleanRules.isUpdateItemTarget($0, sparkle: sparkle, home: home) }
            i.atClean = ["age is read again"]
        case .removeBrowserCaches(let id):
            if let browser = BrowserCaches.browser(id: id) {
                i.resolved = BrowserCaches.targets(of: browser, home: home)
                i.resolvedShape = { CleanRules.isBrowserCacheTarget($0, of: browser, home: home) }
            } else { i.shapeProblem = true }
            i.atClean = [foundAgainText]
        case .removeOldLogs(let kind):
            i.resolved = OldLogs.entries(kind, home: home, now: now).map(\.url)
            i.resolvedShape = { CleanRules.isOldLogTarget($0, kind: kind, home: home) }
            i.atClean = ["age is read again"]
        case .removeOldTestBrowsers(let id):
            if let tool = TestBrowsers.tool(id: id) {
                i.resolved = TestBrowsers.oldVersions(of: tool, home: home)
                i.resolvedShape = { CleanRules.isTestBrowserTarget($0, of: tool, home: home) }
            } else { i.shapeProblem = true }
            i.atClean = ["running programs are read again"]
        case .removeCacheFolderContents(let name):
            let (folder, problem) = CleanRules.cacheFolder(named: name, home: home)
            i.targets = [folder]; i.mustExist = true
            i.allowingSystemCache = CleanRules.systemCacheName(name)
            i.shape = { _ in problem == nil }
        case .worktree(.remove(_, let path)):
            i.targets = [path]; i.atClean = [toolText]
        case .worktree(.prune), .owner, .docker, .simulator, .globalPackage, .brew, .emptyTrash, .agent(.removeOllamaModel):
            i.atClean = [toolText]
        case .removeRuntime, .agent, .removeServiceWorkerSite, .removeServiceWorkerStorage:
            i.atClean = [foundAgainText]
        case .inform:
            break
        }
        return i
    }

    /// nil when the item would be cleaned. Else the short reason. The order of the checks is fixed (see the type comment).
    static func skipReason(_ f: Finding, guardian: PathGuard, running: RunningSnapshot, active: [String]? = nil, now: Date = Date()) -> String? {
        decide(f, guardian: guardian, running: running, active: active, now: now).reason
    }

    /// `inspection` is for tests only: it replaces what the plan reads, so that a test can give a list that no real disk gives.
    static func decide(_ f: Finding, guardian: PathGuard, running: RunningSnapshot, active: [String]?, now: Date,
                       inspection: ((Finding, URL, Date) -> Inspection)? = nil) -> Decision {
        func stop(_ reason: String, checked: Bool = false) -> Decision { Decision(reason: reason, checkedNow: checked, atClean: "") }
        if !f.isActionable { return stop("info only") }
        if f.tier != .safe { return stop("review item") }
        if let why = f.blockedReason { return stop("blocked: \(why)") }

        let home = URL(fileURLWithPath: guardian.home)
        let i = (inspection ?? inspect)(f, home, now)
        let checked = i.checked
        // The path is checked again now, because the disk can change after the scan.
        for url in i.targets + (i.resolved ?? []) {
            switch guardian.check(url, allowingSystemCache: i.allowingSystemCache) {
            case nil: continue
            case .kept?: return stop("on the keep list", checked: true)
            case let refusal?: return stop("refused by the path guard: \(refusal)", checked: true)
            }
        }
        if i.mustExist, i.targets.contains(where: { !CleanRules.exists($0) }) { return stop("not there now", checked: true) }
        if i.mustBeReadableFolder, i.targets.contains(where: { !CleanRules.isReadableFolder($0) }) {
            return stop(notReadableFolder, checked: true)
        }
        if i.shapeProblem { return stop(wrongShape, checked: true) }
        if let shape = i.shape {
            for url in i.targets where !shape(url) { return stop(CleanRules.isPlain(url) ? wrongShape : linkInPath, checked: true) }
        }
        if i.extraShapeFailure?() == true { return stop(wrongShape, checked: true) }
        if let list = i.resolved {
            if list.isEmpty { return stop("nothing to clean now", checked: true) }
            if let shape = i.resolvedShape {
                for url in list where !shape(url) { return stop(CleanRules.isPlain(url) ? wrongShape : linkInPath, checked: true) }
            }
        }
        if let artifact = i.artifact, let active, CleanRules.projectInUse(artifact: artifact, active: active) {
            return stop("project is in use", checked: true)
        }
        let blockers = f.owner.map { running.running($0) } ?? []
        if !blockers.isEmpty { return stop("owner app is open (\(blockers.joined(separator: " and ")))", checked: checked) }
        if !isOneClickSafe(f, blockers: blockers) { return stop(safetyNetReason, checked: checked) }
        var atClean = i.atClean
        if f.owner != nil { atClean.append("app state is read again") }
        return Decision(reason: nil, checkedNow: checked, atClean: atClean.joined(separator: "; "))
    }

    public var wouldClean: [Item] { items.filter(\.wouldClean) }
    public var skipped: [Item] { items.filter { !$0.wouldClean } }

    /// The items that would be cleaned and that have a part which only the Cleaner decides at clean time (a tool, an app, an age).
    public var checkedAgainAtCleanTime: [Item] { wouldClean.filter { !$0.checkedAtCleanTime.isEmpty } }

    /// The bytes that the app adds to its totals for the items that would be cleaned.
    /// An upper-limit item counts 0, as in the app, because its bytes are also in another item.
    public var wouldFree: Int64 { wouldClean.reduce(0) { $0 + $1.finding.countedBytes } }

    /// How many items are skipped for each reason, most first.
    public var skipCounts: [(reason: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in skipped { counts[item.skipReason, default: 0] += 1 }
        return counts.map { (reason: $0.key, count: $0.value) }.sorted { ($0.count, $1.reason) > ($1.count, $0.reason) }
    }

    /// The note of one item for `--verbose`.
    static func note(_ item: Item) -> String {
        let now = "Checked now: \(item.checkedNow ? "yes" : "no")"
        guard item.wouldClean, !item.checkedAtCleanTime.isEmpty else { return now }
        return now + ". Decided again at clean time: \(item.checkedAtCleanTime)"
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
            if verbose { out += "    \(Self.note(item))\n" }
        }
        out += "\(would.count) \(would.count == 1 ? "item" : "items") would be cleaned. Would free \(ByteText.string(wouldFree))\n"
        if !would.isEmpty {
            let again = checkedAgainAtCleanTime.count
            out += "\(again) of \(would.count) \(would.count == 1 ? "item" : "items") can change at clean time\n"
        }
        if deleteMode == .trash {
            out += "Delete mode is trash: files would move to the Trash. Space comes back when the Trash is emptied.\n"
        }
        if !skipped.isEmpty {
            out += "\nSkipped: \(skipped.count) \(skipped.count == 1 ? "item" : "items")\n"
            if verbose {
                for item in skipped {
                    let f = item.finding
                    out += "  \(item.skipReason) - \(f.ecosystem.name) · \(f.title)  [\(f.location)]\n"
                    out += "      \(Self.note(item))\n"
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
        return "wouldClean=\(wouldClean.count) skipped=\(skipped.count) wouldFree=\(wouldFree) checkedAgain=\(checkedAgainAtCleanTime.count) reasons=[\(reasons)]"
    }
}

/// The JSON of the dry run. The finding objects are the same as in `ScanReport` (schema 1), plus the fields below.
///
/// - `mode`: always `dry-run`. Nothing was deleted.
/// - `deleteMode`: `permanent` or `trash`, from the settings.
/// - `totals.wouldFree`: the sum of `countedBytes` of the items with `wouldClean` true. An upper-limit item counts 0, as in the app.
/// - `findings[].wouldClean`: `true` only for an item that a clean of the safe items would take now.
/// - `findings[].skipReason`: a short fixed text. It is empty when `wouldClean` is true.
/// - `findings[].checkedNow`: always present. `true` when a path check ran at plan time (for a worktree: the guard only).
/// - `findings[].checkedAtCleanTime`: always present. Empty, or a short fixed text that says which part only the Cleaner decides at
///   clean time. Empty does not mean that nothing is checked later: the Cleaner always runs the guard and the shape checks again.
///   It is empty for a skipped item.
public struct DryRunReport: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var base: ScanReport.Entry
        public var wouldClean: Bool
        public var skipReason: String
        public var checkedNow: Bool
        public var checkedAtCleanTime: String

        private enum Extra: String, CodingKey { case wouldClean, skipReason, checkedNow, checkedAtCleanTime }

        init(base: ScanReport.Entry, wouldClean: Bool, skipReason: String, checkedNow: Bool, checkedAtCleanTime: String) {
            self.base = base
            self.wouldClean = wouldClean
            self.skipReason = skipReason
            self.checkedNow = checkedNow
            self.checkedAtCleanTime = checkedAtCleanTime
        }

        public init(from decoder: Decoder) throws {
            base = try ScanReport.Entry(from: decoder)
            let c = try decoder.container(keyedBy: Extra.self)
            wouldClean = try c.decode(Bool.self, forKey: .wouldClean)
            skipReason = try c.decode(String.self, forKey: .skipReason)
            checkedNow = try c.decode(Bool.self, forKey: .checkedNow)
            checkedAtCleanTime = try c.decode(String.self, forKey: .checkedAtCleanTime)
        }

        public func encode(to encoder: Encoder) throws {
            try base.encode(to: encoder)
            var c = encoder.container(keyedBy: Extra.self)
            try c.encode(wouldClean, forKey: .wouldClean)
            try c.encode(skipReason, forKey: .skipReason)
            try c.encode(checkedNow, forKey: .checkedNow)
            try c.encode(checkedAtCleanTime, forKey: .checkedAtCleanTime)
        }

        /// The line for the log, one for each item, so that a run can be checked later.
        public var logLine: String {
            "dry-run item id=\(base.id) wouldClean=\(wouldClean) skipReason=\"\(skipReason)\" bytes=\(base.bytes)"
                + " checkedNow=\(checkedNow) checkedAtCleanTime=\"\(checkedAtCleanTime)\""
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
        findings = zip(scan.findings, plan.items).map {
            Entry(base: $0, wouldClean: $1.wouldClean, skipReason: $1.skipReason, checkedNow: $1.checkedNow,
                  checkedAtCleanTime: $1.checkedAtCleanTime)
        }
    }

    /// One compact JSON object with sorted keys, and a new line at the end.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
