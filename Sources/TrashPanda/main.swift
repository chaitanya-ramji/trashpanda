import AppKit
import PandaCore

// `trashpanda --scan` prints what the app would show. It never deletes anything.
if CommandLine.arguments.contains("--scan") {
    let started = Date()
    let result = DiskScanner().scan()
    print("\(Format.bytes(result.disk.free)) free of \(Format.bytes(result.disk.total))")
    print("Reclaim now: \(Format.bytes(result.reclaimable)) · To review: \(Format.bytes(result.reviewable))\n")
    for f in result.findings {
        let tier = f.tier == .safe ? "safe  " : "review"
        print("\(tier)  \(Format.bytes(f.bytes).padding(toLength: 9, withPad: " ", startingAt: 0))"
              + "\(f.ecosystem.name.padding(toLength: 24, withPad: " ", startingAt: 0))\(f.title)  [\(f.location)]")
    }
    print(String(format: "\nScanned in %.1f s", Date().timeIntervalSince(started)))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
