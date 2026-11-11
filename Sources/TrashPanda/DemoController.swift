import AppKit
import PandaCore

/// What the demo needs from the app. `AppDelegate` gives it. Demo mode never scans and never deletes.
protocol DemoHost: AnyObject {
    var menu: NSMenu { get }
    var header: StorageHeaderView { get }
    var statusButton: NSStatusBarButton? { get }
    /// Shows made-up results in the menu and in the menu bar item.
    func showDemo(_ result: ScanResult)
    func demoDialog(for finding: Finding) -> FindingBox
}

/// Demo mode (`trashpanda --demo light` or `--demo dark`): made-up data, for screenshots.
/// The flags are `--dialog`, `--submenu`, `--hover N`, `--click N` and `--backdrop`.
final class DemoController {
    let style: String
    private let arguments: [String]
    /// A plain window behind the menu, so that a screenshot does not show other windows.
    private var backdrop: NSWindow?

    /// nil when the app was not started with `--demo`.
    init?(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--demo") else { return nil }
        self.arguments = arguments
        style = i + 1 < arguments.count ? arguments[i + 1] : "light"
    }

    /// The made-up running apps: Xcode runs, so that a screenshot can show a blocked item.
    var runningApps: RunningApps {
        RunningApps { RunningSnapshot(apps: [RunningApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")]) }
    }

    private func value(of flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private func number(of flag: String) -> Int? { value(of: flag).flatMap { Int($0) } }

    func start(_ host: DemoHost) {
        host.menu.appearance = NSAppearance(named: style == "dark" ? .darkAqua : .aqua)
        let data = DemoData.result()
        host.showDemo(ScanResult(findings: data.findings.filter(\.isActionable), disk: data.disk))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak host] in
            guard let self, let host else { return }
            // The status item has its place by now, so the backdrop can go right under it.
            if arguments.contains("--backdrop") { showBackdrop(host) }
            // `--dialog volume|container|safe` shows that dialog. It deletes nothing, even if you confirm.
            if let kind = value(of: "--dialog"), let item = DemoData.dialogFinding(kind) {
                NSApp.activate(ignoringOtherApps: true)
                _ = Dialogs.makeAlert(for: host.demoDialog(for: item)).alert.runModal()
                NSApp.terminate(nil)
            } else if let name = value(of: "--submenu")?.lowercased(),
                      let item = host.menu.items.first(where: { $0.attributedTitle?.string.lowercased().hasPrefix(name) == true }),
                      let sub = item.submenu {
                sub.appearance = host.menu.appearance
                sub.popUp(positioning: nil, at: NSPoint(x: 700, y: 800), in: nil)
            } else {
                // While a menu is open, the run loop is in tracking mode. Plain dispatch blocks do not run then,
                // so these timers use the common modes. Opening the menu resets the header, so they wait for it.
                func later(_ seconds: Double, _ work: @escaping () -> Void) {
                    let t = Timer(timeInterval: seconds, repeats: false) { _ in work() }
                    RunLoop.main.add(t, forMode: .common)
                }
                let header = host.header
                if let n = number(of: "--hover") { later(1.2) { header.simulateHover(n) } }
                if let n = number(of: "--click") { later(1.6) { header.simulateClick(n) } }
                // A short wait, so that the backdrop is on screen before the menu opens over it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { host.statusButton?.performClick(nil) }
            }
        }
    }

    private func showBackdrop(_ host: DemoHost) {
        guard let frame = host.statusButton?.window?.frame, let screen = NSScreen.main else { return }
        let area = NSRect(x: frame.minX - 60, y: screen.frame.maxY - 24 - 520, width: 460, height: 520)
        let window = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = style == "dark" ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.91, alpha: 1)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.orderFrontRegardless()
        backdrop = window
    }
}
