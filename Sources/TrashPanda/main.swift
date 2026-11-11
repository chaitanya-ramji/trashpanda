import AppKit
import PandaCore

let usage = """
Usage: trashpanda [option]
  --scan               Print what the app would show. Nothing is deleted.
  --write-icons DIR    Write the app icon sizes to DIR.
  --demo [light|dark]  Show made-up data. Nothing is scanned or deleted.
  --version            Print the version.
  --help               Print this text.

"""

// An option that we do not know is an error. Other values do not start with a dash.
let knownOptions: Set<String> = ["--scan", "--write-icons", "--demo", "--dialog", "--submenu", "--hover", "--click", "--backdrop",
                                 "--version", "--help"]
let unknownOptions = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("-") && !knownOptions.contains($0) && !$0.hasPrefix("-psn_") }
if !unknownOptions.isEmpty {
    FileHandle.standardError.write(Data(("Unknown option: \(unknownOptions.joined(separator: " "))\n" + usage).utf8))
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

// `trashpanda --scan` prints what the app would show. It never deletes anything.
if CommandLine.arguments.contains("--scan") {
    let started = Date()
    let result = DiskScanner().scan()
    print("\(Format.bytes(result.disk.free)) free of \(Format.bytes(result.disk.total))")
    print("Reclaim now: \(Format.bytes(result.reclaimable)) · To review: \(Format.bytes(result.reviewable))\n")
    // The name column is as wide as the longest name, plus 2.
    let nameWidth = (result.findings.map { $0.ecosystem.name.count }.max() ?? 0) + 2
    for f in result.findings {
        let tier = !f.isActionable ? "info  " : (f.tier == .safe ? "safe  " : "review")
        print("\(tier)  \(Format.bytes(f.bytes).padding(toLength: 9, withPad: " ", startingAt: 0))"
              + "\(f.ecosystem.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))\(f.title)  [\(f.location)]")
    }
    print(String(format: "\nScanned in %.1f s", Date().timeIntervalSince(started)))
    exit(0)
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
