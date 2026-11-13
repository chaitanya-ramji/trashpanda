import Foundation

/// A request to stop the run after the current item. A signal handler sets it (see `CLISignals`). The run reads it between two items.
public final class CLIStop: @unchecked Sendable {
    private let lock = NSLock()
    private var number: Int32 = 0
    public init() {}

    /// Asks the run to stop. The first signal counts. A later signal does not change the number.
    public func request(signal: Int32) {
        lock.lock(); defer { lock.unlock() }
        if number == 0 { number = signal }
    }

    public var isRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return number != 0
    }

    /// The number of the signal that asked for the stop. 0 when nobody asked.
    public var signalNumber: Int32 {
        lock.lock(); defer { lock.unlock() }
        return number
    }

    /// 130 for SIGINT, 143 for SIGTERM: 128 plus the number of the signal, as a shell does.
    public var exitCode: Int32 { 128 + signalNumber }

    public var signalName: String {
        switch signalNumber {
        case SIGINT: return "SIGINT"
        case SIGTERM: return "SIGTERM"
        default: return "signal \(signalNumber)"
        }
    }
}

/// Connects SIGINT and SIGTERM to a `CLIStop`. The handlers run on a background queue, because the main thread is busy with the run.
public enum CLISignals {
    private static var sources: [DispatchSourceSignal] = []

    /// Call it once, before the run. A second signal does not end the run at once: the run always finishes the item that it works on.
    public static func install(_ stop: CLIStop) {
        for number in [SIGINT, SIGTERM] {
            // The default action ends the program at once. The dispatch source takes the signal instead.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: DispatchQueue.global(qos: .userInitiated))
            source.setEventHandler { stop.request(signal: number) }
            source.resume()
            sources.append(source)
        }
    }
}

/// The lock of the real clean. Two runs of `--clean-safe --yes` can never work at the same time.
/// It is an exclusive `flock` on `clean.lock` in the log folder. It never waits. The system frees it when the program ends,
/// also after a crash. The menu app does not take this lock.
public final class CLILock {
    public enum Failure: Error, Equatable {
        /// Another run holds the lock.
        case held
        /// The lock file or its folder could not be opened. The run must not go on without a lock.
        case cannotOpen(String)
    }

    public static let fileName = "clean.lock"
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { release() }

    /// Takes the lock, or says why not. The file has mode 0600, and the folder has mode 0700 when it is made here.
    public static func acquire(in folder: URL) -> Result<CLILock, Failure> {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(.cannotOpen("the folder \(folder.path) could not be made"))
        }
        let path = folder.appendingPathComponent(fileName).path
        // O_NOFOLLOW: a link in place of the lock file is refused, never followed.
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .failure(.cannotOpen("the lock file \(path) could not be opened")) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(fd)
            return .failure(busy ? .held : .cannotOpen("the lock file \(path) could not be locked"))
        }
        return .success(CLILock(descriptor: fd))
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

/// What the real clean needs from the outside. The defaults are the real ones. A test gives other ones.
public struct CLICleanEnvironment {
    /// The user id that the program runs as. 0 is root. The real clean refuses to run as root, because `~` would be the home of root.
    public var effectiveUserID: () -> UInt32 = { UInt32(geteuid()) }
    /// The folder of the lock file. nil means the log folder (`~/Library/Logs/TrashPanda`).
    public var lockFolder: URL?
    /// Set by a signal. The run stops after the item that it works on.
    public var stop: CLIStop = CLIStop()
    /// The move to the Trash in trash mode. nil means the system Trash. A test gives a folder inside its fixture.
    public var moveToTrash: ((URL) throws -> Void)?
    /// The working folders of the running programs, read at clean time. nil means the real read.
    public var activeDirectories: (() -> [String])?
    /// Called with each finding right before it goes to the Cleaner. Tests use it to see exactly what the Cleaner gets.
    public var willClean: ((Finding) -> Void)?

    public init() {}
}

/// The result of one item of a real clean.
public struct CleanOutcome: Equatable, Sendable {
    public enum Result: String, Sendable { case cleaned, skipped, failed }
    public var result: Result
    public var skipReason: String
    public var failReason: String
    /// Measured by the Cleaner: the bytes that really left the disk.
    public var freedBytes: Int64
    /// Measured by the Cleaner in trash mode: the bytes that moved to the Trash. This space is not free yet.
    public var movedToTrashBytes: Int64
}

/// `trashpanda --clean-safe --yes`: the one command line command that removes files.
///
/// It runs ONLY the items that the unattended `CleanPlan` marks with `wouldClean`, from a fresh scan of this same run. It takes no id,
/// no path, and no item from the command line, from a file, or from the environment. Each item goes to the real `Cleaner`, one at a
/// time, with all its checks (the shape check, the measuring, the guard, the keep list, the owner app, the link checks). This file
/// has no delete rule of its own and no delete call.
enum CLIClean {
    /// The kind of an action for the log: the case name only, never its arguments (they hold paths).
    static func actionKind(_ action: Action) -> String {
        let text = String(describing: action)
        return String(text.prefix { $0 != "(" })
    }

    /// The text of the failure that the run prints when it cannot start. Exit code 1, 75, or 77.
    private static func refuse(_ message: String, code: Int32, log: (CLILogLevel, String) -> Void, line: String) -> CLIResult {
        log(.warn, "cli clean: \(line), exit \(code)")
        return CLIResult(stdout: "", stderr: message + "\n", exitCode: code)
    }

    static func run(arguments: [String], scanner: () -> DiskScanner, runningApps: RunningApps, activeDirectories: [String]?,
                    version: String, now: () -> Date, log: (CLILogLevel, String) -> Void,
                    environment: CLICleanEnvironment) -> CLIResult {
        let started = now()
        let json = arguments.contains("--json")
        let verbose = arguments.contains("--verbose")
        let startText = "cli start version=\(version) mode=\(CommandLineCheck.mode(arguments)) \(CommandLineCheck.logOptions(arguments))"

        // (d) Never as root: `~` would be the home of root.
        guard environment.effectiveUserID() != 0 else {
            log(.info, startText)
            return refuse("trashpanda --clean-safe --yes does not run as root. Run it as the user whose caches you want to clean.",
                          code: 77, log: log, line: "refused to run as root")
        }
        let scan = scanner()
        // (f) The real home folder must be known. We never fall back to `/`.
        let home = scan.home.standardizedFileURL
        var isFolder: ObjCBool = false
        guard home.path.hasPrefix("/"), home.path != "/", FileManager.default.fileExists(atPath: home.path, isDirectory: &isFolder),
              isFolder.boolValue else {
            log(.info, startText)
            return refuse("The home folder could not be found. Nothing was cleaned.", code: 1, log: log, line: "home folder unknown")
        }

        // (a) One clean at a time.
        let lockFolder = environment.lockFolder ?? Log.fileURL.deletingLastPathComponent()
        let lock: CLILock
        switch CLILock.acquire(in: lockFolder) {
        case .success(let taken):
            lock = taken
            log(.info, "cli lock taken: \(Log.redact(lockFolder.appendingPathComponent(CLILock.fileName).path, home: home.path))")
        case .failure(.held):
            log(.info, startText)
            return refuse("Another trashpanda clean is running. This run did not start. Nothing was cleaned.", code: 75, log: log,
                          line: "lock is held by another run")
        case .failure(.cannotOpen(let why)):
            log(.info, startText)
            return refuse("The lock could not be taken (\(Log.redact(why, home: home.path))). Nothing was cleaned.", code: 1, log: log,
                          line: "lock could not be taken")
        }
        defer { lock.release() }

        // The scan, then the plan. The dry run makes the same plan, so it is an exact preview of this run.
        let result = scan.scan()
        let plan = CleanPlan(result, guardian: scan.guardian, running: runningApps.take(), deleteMode: scan.config.deleteMode,
                             activeDirectories: activeDirectories, now: now(), unattended: true)
        log(.info, "\(startText) deleteMode=\(plan.deleteMode.rawValue) plan: \(plan.summary())")

        let cleaner = Cleaner(guardian: scan.guardian, remaining: scan.remainingBytes(of:), runningApps: runningApps,
                              runtimeRequests: scan.runtimeRequests, deleteMode: plan.deleteMode)
        cleaner.staleDays = scan.config.staleDays
        if let move = environment.moveToTrash { cleaner.useTrashMove(move) }
        if let active = environment.activeDirectories { cleaner.activeDirectories = active }
        let stop = environment.stop
        cleaner.shouldStop = { stop.isRequested }

        let run = runPlan(plan: plan, result: result, cleaner: cleaner, home: home.path, stop: stop,
                          willClean: environment.willClean, log: log)
        let millis = Int(now().timeIntervalSince(started) * 1000)
        // A signal wins over a failure: 130 or 143. Else 1 when an item failed. A skipped item is not a failure.
        let code: Int32 = run.stopped ? stop.exitCode : (run.failed > 0 ? 1 : 0)
        log(.info, "cli end clean-safe --yes cleaned=\(run.cleaned) skipped=\(run.skipped) failed=\(run.failed) freed=\(run.freedBytes)"
            + " movedToTrash=\(run.movedToTrashBytes) stopped=\(run.stopped) duration_ms=\(millis) exit=\(code)")
        let out = json ? run.json() : run.text(verbose: verbose, nothing: result.findings.isEmpty)
        return CLIResult(stdout: out, stderr: "", exitCode: code)
    }

    /// Runs the items of a plan that have `wouldClean`, one at a time. A skipped item never reaches the Cleaner.
    /// A test can give a plan that it built itself, to check that the run does not trust it blindly.
    static func runPlan(plan: CleanPlan, result: ScanResult, cleaner: Cleaner, home: String, stop: CLIStop,
                        willClean: ((Finding) -> Void)?, log: (CLILogLevel, String) -> Void) -> CleanRun {
        var run = CleanRun(plan: plan, result: result, home: home)
        var stopLogged = false
        for (index, item) in plan.items.enumerated() {
            let f = item.finding
            let id = ScanReport.id(f.id, home: home)
            guard item.wouldClean else {
                run.outcomes[index] = CleanOutcome(result: .skipped, skipReason: item.skipReason, failReason: "", freedBytes: 0,
                                                   movedToTrashBytes: 0)
                continue
            }
            // A second look at the plan item. A plan that was built by hand or by a bug must not send a tool item, a review item,
            // a blocked item, or an information line to the Cleaner.
            if !CleanPlan.isOneClickSafe(f, blockers: []) || CleanPlan.needsAPerson(f.action) {
                let why = CleanPlan.needsAPerson(f.action) ? CleanPlan.needsAPersonReason : "not part of the one-click clean"
                log(.warn, "clean item id=\(id) result=skipped freed=0 reason=\"\(why)\"")
                run.outcomes[index] = CleanOutcome(result: .skipped, skipReason: why, failReason: "", freedBytes: 0, movedToTrashBytes: 0)
                continue
            }
            if stop.isRequested {
                if !stopLogged {
                    log(.warn, "cli stopped by signal \(stop.signalName): the items that are left are not cleaned")
                    stopLogged = true
                }
                run.stopped = true
                run.outcomes[index] = CleanOutcome(result: .skipped, skipReason: Self.stoppedReason, failReason: "", freedBytes: 0,
                                                   movedToTrashBytes: 0)
                continue
            }
            log(.info, "clean item id=\(id) bytes=\(f.bytes) action=\(actionKind(f.action))")
            willClean?(f)
            let report = cleaner.clean([f])
            let outcome = classify(report, home: home)
            run.outcomes[index] = outcome
            let reason = outcome.result == .skipped ? outcome.skipReason : outcome.failReason
            log(outcome.result == .failed ? .warn : .info,
                "clean item id=\(id) result=\(outcome.result.rawValue) freed=\(outcome.freedBytes) movedToTrash=\(outcome.movedToTrashBytes)"
                + " reason=\"\(reason)\"")
        }
        if stop.isRequested { run.stopped = true }
        return run
    }

    static let stoppedReason = "stopped by signal"

    /// What happened to one item, from the report of the Cleaner. A failure wins over everything else.
    /// A folder that was emptied only in part, with children that could not be removed, is `failed`, and it shows the bytes that did leave.
    static func classify(_ report: CleanReport, home: String) -> CleanOutcome {
        func text(_ lines: [String]) -> String { Log.redact(lines.joined(separator: "; "), home: home) }
        let freed = report.freed, moved = report.movedToTrash
        if !report.failed.isEmpty {
            return CleanOutcome(result: .failed, skipReason: "", failReason: text(report.failed), freedBytes: freed, movedToTrashBytes: moved)
        }
        // A folder whose children were all skipped is not a clean: nothing left the disk.
        if report.removed > 0, !(freed == 0 && moved == 0 && !report.skipped.isEmpty) {
            return CleanOutcome(result: .cleaned, skipReason: "", failReason: "", freedBytes: freed, movedToTrashBytes: moved)
        }
        let why = report.skipped.isEmpty ? "nothing was cleaned" : text(report.skipped)
        return CleanOutcome(result: .skipped, skipReason: why, failReason: "", freedBytes: freed, movedToTrashBytes: moved)
    }
}

/// The result of a whole real clean: the plan, the scan, and one outcome for each item. It makes the text and the JSON.
struct CleanRun {
    let plan: CleanPlan
    let result: ScanResult
    let home: String
    var outcomes: [Int: CleanOutcome] = [:]
    var stopped = false

    init(plan: CleanPlan, result: ScanResult, home: String) {
        self.plan = plan
        self.result = result
        self.home = home
    }

    func outcome(_ index: Int) -> CleanOutcome {
        outcomes[index] ?? CleanOutcome(result: .skipped, skipReason: CLIClean.stoppedReason, failReason: "", freedBytes: 0, movedToTrashBytes: 0)
    }

    private var all: [CleanOutcome] { plan.items.indices.map(outcome) }
    var cleaned: Int { all.filter { $0.result == .cleaned }.count }
    var skipped: Int { all.filter { $0.result == .skipped }.count }
    var failed: Int { all.filter { $0.result == .failed }.count }
    var freedBytes: Int64 { all.reduce(0) { $0 + $1.freedBytes } }
    var movedToTrashBytes: Int64 { all.reduce(0) { $0 + $1.movedToTrashBytes } }

    /// The items that went to the Cleaner, with their outcome.
    private var attempted: [(CleanPlan.Item, CleanOutcome)] {
        plan.items.indices.compactMap { i in
            plan.items[i].wouldClean && outcomes[i] != nil && outcomes[i]?.skipReason != CLIClean.stoppedReason
                ? (plan.items[i], outcome(i)) : nil
        }
    }

    /// The text of `trashpanda --clean-safe --yes`. Each line ends with a new line.
    func text(verbose: Bool, nothing: Bool) -> String {
        var out = ""
        if nothing { return "Nothing to clean.\n" }
        let tried = attempted
        let width = (tried.map { $0.0.finding.ecosystem.name.count }.max() ?? 0) + 2
        for (item, outcome) in tried {
            let f = item.finding
            let amount = outcome.freedBytes > 0 ? outcome.freedBytes : outcome.movedToTrashBytes
            out += "\(outcome.result.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))"
                + "\(ByteText.string(amount).padding(toLength: 11, withPad: " ", startingAt: 0))"
                + "\(f.ecosystem.name.padding(toLength: width, withPad: " ", startingAt: 0))\(f.title)  [\(f.location)]\n"
            if outcome.result == .skipped { out += "    skipped: \(outcome.skipReason)\n" }
            if outcome.result == .failed { out += "    failed: \(outcome.failReason)\n" }
        }
        let count = { (n: Int) in "\(n) \(n == 1 ? "item" : "items")" }
        out += "\(count(cleaned)) cleaned, \(skipped) skipped, \(failed) failed.\n"
        if plan.deleteMode == .trash {
            out += "Moved \(ByteText.string(movedToTrashBytes)) to the Trash. \(DeleteModeText.notFreeYet)\n"
            if freedBytes > 0 { out += "Freed \(ByteText.string(freedBytes)) (measured).\n" }
        } else {
            out += "Freed \(ByteText.string(freedBytes)) (measured).\n"
        }
        let notTried = plan.items.indices.filter { !(plan.items[$0].wouldClean && outcomes[$0]?.skipReason != CLIClean.stoppedReason) }
        if !notTried.isEmpty {
            out += "\nSkipped: \(count(notTried.count))\n"
            if verbose {
                for i in notTried {
                    let f = plan.items[i].finding
                    out += "  \(outcome(i).skipReason) - \(f.ecosystem.name) · \(f.title)  [\(f.location)]\n"
                }
            } else {
                var counts: [String: Int] = [:]
                for i in notTried { counts[outcome(i).skipReason, default: 0] += 1 }
                for entry in counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) { out += "  \(entry.value)  \(entry.key)\n" }
            }
        }
        if stopped { out += "Stopped by a signal. The items that are left were not cleaned. This report is partial.\n" }
        return out
    }

    func json() -> String {
        let report = CleanReportJSON(self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(report)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// The JSON of the real clean (`trashpanda --clean-safe --yes --json`). The finding objects are the same as in `ScanReport` (schema 1),
/// plus the fields below. Fields of the scan and the dry run are never changed or dropped.
///
/// - `mode`: always `clean`.
/// - `deleteMode`: `permanent` or `trash`, from the settings.
/// - `stopped`: `true` when a signal (SIGINT or SIGTERM) stopped the run. The items that were left are `skipped` with the reason
///   `stopped by signal`.
/// - `note`: in trash mode, the line that says that the space is not free until the Trash is emptied. Empty in permanent mode.
/// - `totals.cleaned`, `skipped`, `failed`: the number of items for each result.
/// - `totals.freedBytes`: the bytes that really left the disk, as the Cleaner measured them. It is never the estimate.
/// - `totals.movedToTrashBytes`: the bytes that moved to the Trash (trash mode). This space is not free until the Trash is emptied.
/// - `findings[].result`: `cleaned`, `skipped`, or `failed`.
/// - `findings[].skipReason`: empty unless `result` is `skipped`. `findings[].failReason`: empty unless `result` is `failed`.
/// - `findings[].freedBytes` and `findings[].movedToTrashBytes`: measured, for this item. A `failed` item can show a part.
public struct CleanReportJSON: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var base: ScanReport.Entry
        public var result: String
        public var skipReason: String
        public var failReason: String
        public var freedBytes: Int64
        public var movedToTrashBytes: Int64

        private enum Extra: String, CodingKey { case result, skipReason, failReason, freedBytes, movedToTrashBytes }

        init(base: ScanReport.Entry, outcome: CleanOutcome) {
            self.base = base
            result = outcome.result.rawValue
            skipReason = outcome.result == .skipped ? outcome.skipReason : ""
            failReason = outcome.result == .failed ? outcome.failReason : ""
            freedBytes = outcome.freedBytes
            movedToTrashBytes = outcome.movedToTrashBytes
        }

        public init(from decoder: Decoder) throws {
            base = try ScanReport.Entry(from: decoder)
            let c = try decoder.container(keyedBy: Extra.self)
            result = try c.decode(String.self, forKey: .result)
            skipReason = try c.decode(String.self, forKey: .skipReason)
            failReason = try c.decode(String.self, forKey: .failReason)
            freedBytes = try c.decode(Int64.self, forKey: .freedBytes)
            movedToTrashBytes = try c.decode(Int64.self, forKey: .movedToTrashBytes)
        }

        public func encode(to encoder: Encoder) throws {
            try base.encode(to: encoder)
            var c = encoder.container(keyedBy: Extra.self)
            try c.encode(result, forKey: .result)
            try c.encode(skipReason, forKey: .skipReason)
            try c.encode(failReason, forKey: .failReason)
            try c.encode(freedBytes, forKey: .freedBytes)
            try c.encode(movedToTrashBytes, forKey: .movedToTrashBytes)
        }
    }

    public struct Totals: Codable, Equatable, Sendable {
        public var reclaimable: Int64
        public var reviewable: Int64
        public var cleaned: Int
        public var skipped: Int
        public var failed: Int
        public var freedBytes: Int64
        public var movedToTrashBytes: Int64
    }

    public var schema: Int
    public var mode: String
    public var deleteMode: String
    public var stopped: Bool
    public var note: String
    public var disk: ScanReport.Disk
    public var totals: Totals
    public var findings: [Entry]

    init(_ run: CleanRun) {
        let scan = ScanReport(run.result, home: run.home)
        schema = scan.schema
        mode = "clean"
        deleteMode = run.plan.deleteMode.rawValue
        stopped = run.stopped
        note = run.plan.deleteMode == .trash ? DeleteModeText.notFreeYet : ""
        disk = scan.disk
        totals = Totals(reclaimable: scan.totals.reclaimable, reviewable: scan.totals.reviewable, cleaned: run.cleaned,
                        skipped: run.skipped, failed: run.failed, freedBytes: run.freedBytes, movedToTrashBytes: run.movedToTrashBytes)
        // The plan and the report keep the order of the scan.
        findings = scan.findings.enumerated().map { Entry(base: $1, outcome: run.outcome($0)) }
    }
}
