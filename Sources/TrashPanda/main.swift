import AppKit
import PandaCore

let usage = """
Usage: trashpanda [option]
  --scan               Print what the app would show. Nothing is deleted.
  --scan --json        Print the same as one JSON object (schema 1) for scripts. Nothing else is printed.
  --clean-safe --dry-run
                       Print the safe items that a clean would remove, and their sum. Nothing is deleted.
                       Add --json for one JSON object (schema 1), --verbose to list each skipped item.
  --write-icons DIR    Write the app icon sizes to DIR.
  --demo [light|dark]  Show made-up data. Nothing is scanned or deleted.
  --version            Print the version.
  --help               Print this text.

"""

// An option that we do not know is an error. Other values do not start with a dash.
// `--json` works with `--scan` or with `--clean-safe --dry-run`. `--clean-safe` needs `--dry-run`: the real clean does not exist yet.
if let message = CommandLineCheck.error(CommandLine.arguments) {
    Log.warn("cli: wrong option, exit 64: \(CommandLineCheck.logOptions(CommandLine.arguments))")
    Log.flush()
    FileHandle.standardError.write(Data((message + "\n" + usage).utf8))
    exit(64)
}
if CommandLine.arguments.contains("--help") {
    print(usage, terminator: "")
    exit(0)
}
if CommandLine.arguments.contains("--version") {
    print(UpdateController.currentVersion)
    exit(0)
}

// BEGIN scan: this path only reads. It must never call a delete (a test reads this text).
// `trashpanda --scan` prints what the app would show. With `--json` it prints only the JSON object.
if CommandLine.arguments.contains("--scan") {
    let started = Date()
    let json = CommandLine.arguments.contains("--json")
    Log.info("cli start version=\(UpdateController.currentVersion) mode=\(CommandLineCheck.mode(CommandLine.arguments)) \(CommandLineCheck.logOptions(CommandLine.arguments))")
    let result = DiskScanner().scan()
    if json {
        print(ScanReport(result).json(), terminator: "")
    } else {
        print(ScanReport.text(result), terminator: "")
        print(String(format: "\nScanned in %.1f s", Date().timeIntervalSince(started)))
    }
    let millis = Int(Date().timeIntervalSince(started) * 1000)
    Log.info("cli end \(ScanReport.summary(result)) duration_ms=\(millis) exit=0")
    Log.flush()
    exit(0)
}
// END scan

// BEGIN dry-run: this path only reads. It must never call a delete (a test reads this text).
// `trashpanda --clean-safe --dry-run` prints the safe items that a clean would remove. Nothing is deleted.
if CommandLineCheck.isDryRun(CommandLine.arguments) {
    let started = Date()
    let json = CommandLine.arguments.contains("--json")
    let verbose = CommandLine.arguments.contains("--verbose")
    Log.info("cli start version=\(UpdateController.currentVersion) mode=\(CommandLineCheck.mode(CommandLine.arguments)) \(CommandLineCheck.logOptions(CommandLine.arguments))")
    let scanner = DiskScanner()
    let result = scanner.scan()
    let plan = CleanPlan(result, guardian: scanner.guardian, running: RunningApps.system.take(), deleteMode: scanner.config.deleteMode)
    let report = DryRunReport(result, plan: plan)
    for entry in report.findings { Log.info(entry.logLine) }
    if json {
        print(report.json(), terminator: "")
    } else {
        print(plan.text(verbose: verbose), terminator: "")
    }
    let millis = Int(Date().timeIntervalSince(started) * 1000)
    Log.info("cli end dry-run \(plan.summary()) duration_ms=\(millis) exit=0")
    Log.flush()
    exit(0)
}
// END dry-run

// `trashpanda --write-icons <folder>` writes the app icon sizes. The build script uses it.
if let flag = CommandLine.arguments.firstIndex(of: "--write-icons"), flag + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    do {
        try PandaArt.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not write icons: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
