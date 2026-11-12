import AppKit
import PandaCore

// The read-only commands live in PandaCore (`CLICommand`), so that tests can run them. This file only parses nothing itself:
// it calls the command, prints the result, flushes the log, and exits.
if let result = CLICommand.run(arguments: CommandLine.arguments, scanner: DiskScanner(), runningApps: .system,
                               version: UpdateController.currentVersion, log: { level, text in
    switch level {
    case .info: Log.info(text)
    case .warn: Log.warn(text)
    }
}) {
    Log.flush()
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
    FileHandle.standardError.write(Data(result.stderr.utf8))
    exit(result.exitCode)
}

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
