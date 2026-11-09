import AppKit
import PandaCore

// `trashpanda --scan` prints what the app would show. It never deletes anything.
if CommandLine.arguments.contains("--scan") {
    let started = Date()
    let result = DiskScanner().scan()
    print("\(Format.bytes(result.disk.free)) free of \(Format.bytes(result.disk.total))")
    print("Reclaim now: \(Format.bytes(result.reclaimable)) · To review: \(Format.bytes(result.reviewable))\n")
    for f in result.findings {
        let tier = !f.isActionable ? "info  " : (f.tier == .safe ? "safe  " : "review")
        print("\(tier)  \(Format.bytes(f.bytes).padding(toLength: 9, withPad: " ", startingAt: 0))"
              + "\(f.ecosystem.name.padding(toLength: 24, withPad: " ", startingAt: 0))\(f.title)  [\(f.location)]")
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
