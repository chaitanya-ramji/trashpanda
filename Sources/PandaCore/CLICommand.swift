import Foundation

/// What a command line run gives back. The caller prints `stdout` and `stderr`, flushes the log, and exits with `exitCode`.
public struct CLIResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
}

public enum CLILogLevel: Sendable { case info, warn }

/// The command line commands that only read: `--scan`, `--clean-safe --dry-run`, `--help`, and `--version`.
///
/// This type is a pure function of its input. It prints nothing and it exits never: it returns a `CLIResult`.
/// It has no delete, no Trash call, no shell run, and no owner action. A test reads the source of this file and of
/// `CleanPlan.swift` and `ScanReport.swift` and checks that (see `CleanPlanTests`), and other tests run it on a fixture home
/// and compare every file before and after. The scan itself (`DiskScanner`) only reads too.
public enum CLICommand {
    public static let usage = """
    Usage: trashpanda [option]
      --scan               Print what the app would show. Nothing is deleted.
      --scan --json        Print the same as one JSON object (schema 1) for scripts. Nothing else is printed.
      --clean-safe --dry-run
                           Print the safe items that a clean would remove, and their sum. Nothing is deleted.
                           Add --json for one JSON object (schema 1), or --verbose to list each item with its checks.
                           --verbose and --json cannot be used together.
      --write-icons DIR    Write the app icon sizes to DIR.
      --demo [light|dark]  Show made-up data. Nothing is scanned or deleted.
      --version            Print the version.
      --help               Print this text.

    """

    /// Runs one command. Returns nil when the arguments are not a command line command: the caller starts the app then.
    /// - `scanner`: it is built only when a command needs it.
    /// - `runningApps`: reads which apps run (the dry run needs it).
    /// - `activeDirectories`: the working folders of the running programs, if the caller knows them. nil means unknown.
    /// - `log`: gets each log line.
    public static func run(arguments: [String], scanner: @autoclosure () -> DiskScanner, runningApps: RunningApps,
                           activeDirectories: [String]? = nil, version: String = "unknown", now: () -> Date = Date.init,
                           log: (CLILogLevel, String) -> Void) -> CLIResult? {
        // An option that we do not know is an error. Other values do not start with a dash.
        if let message = CommandLineCheck.error(arguments) {
            log(.warn, "cli: wrong option, exit 64: \(CommandLineCheck.logOptions(arguments))")
            return CLIResult(stdout: "", stderr: message + "\n" + usage, exitCode: 64)
        }
        if arguments.contains("--help") { return CLIResult(stdout: usage, stderr: "", exitCode: 0) }
        if arguments.contains("--version") { return CLIResult(stdout: version + "\n", stderr: "", exitCode: 0) }
        if arguments.contains("--scan") { return scan(arguments, scanner: scanner(), version: version, now: now, log: log) }
        if CommandLineCheck.isDryRun(arguments) {
            return dryRun(arguments, scanner: scanner(), runningApps: runningApps, activeDirectories: activeDirectories,
                          version: version, now: now, log: log)
        }
        return nil
    }

    /// `trashpanda --scan` prints what the app would show. With `--json` it prints only the JSON object.
    private static func scan(_ arguments: [String], scanner: DiskScanner, version: String, now: () -> Date,
                             log: (CLILogLevel, String) -> Void) -> CLIResult {
        let started = now()
        let json = arguments.contains("--json")
        log(.info, "cli start version=\(version) mode=\(CommandLineCheck.mode(arguments)) \(CommandLineCheck.logOptions(arguments))")
        let result = scanner.scan()
        var out: String
        if json {
            out = ScanReport(result, home: scanner.home.path).json()
        } else {
            out = ScanReport.text(result)
            out += String(format: "\nScanned in %.1f s\n", now().timeIntervalSince(started))
        }
        let millis = Int(now().timeIntervalSince(started) * 1000)
        log(.info, "cli end \(ScanReport.summary(result)) duration_ms=\(millis) exit=0")
        return CLIResult(stdout: out, stderr: "", exitCode: 0)
    }

    /// `trashpanda --clean-safe --dry-run` prints the safe items that a clean would remove. Nothing is deleted.
    private static func dryRun(_ arguments: [String], scanner: DiskScanner, runningApps: RunningApps, activeDirectories: [String]?,
                               version: String, now: () -> Date, log: (CLILogLevel, String) -> Void) -> CLIResult {
        let started = now()
        let json = arguments.contains("--json")
        let verbose = arguments.contains("--verbose")
        log(.info, "cli start version=\(version) mode=\(CommandLineCheck.mode(arguments)) \(CommandLineCheck.logOptions(arguments))")
        let result = scanner.scan()
        let plan = CleanPlan(result, guardian: scanner.guardian, running: runningApps.take(), deleteMode: scanner.config.deleteMode,
                             activeDirectories: activeDirectories, now: now())
        let report = DryRunReport(result, plan: plan, home: scanner.home.path)
        for entry in report.findings { log(.info, entry.logLine) }
        let out = json ? report.json() : plan.text(verbose: verbose)
        let millis = Int(now().timeIntervalSince(started) * 1000)
        log(.info, "cli end dry-run \(plan.summary()) duration_ms=\(millis) exit=0")
        return CLIResult(stdout: out, stderr: "", exitCode: 0)
    }
}
