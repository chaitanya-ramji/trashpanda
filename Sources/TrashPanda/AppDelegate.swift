import AppKit
import ServiceManagement
import PandaCore

/// Carries findings from a menu item to its action.
final class FindingBox: NSObject {
    let findings: [Finding]
    let title: String
    let body: String
    /// Text under the body. When nil, the dialog says that tools rebuild what they need.
    let footer: String?
    /// Text of the confirm button. When nil, it says "Free up <size>".
    let confirmTitle: String?
    init(_ findings: [Finding], title: String, body: String, footer: String? = nil, confirmTitle: String? = nil) {
        self.findings = findings
        self.title = title
        self.body = body
        self.footer = footer
        self.confirmTitle = confirmTitle
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let header = StorageHeaderView(frame: .zero)
    private let scanner = DiskScanner()

    private var result: ScanResult?
    private var disk = DiskUsage.current()
    private var scanning = false
    private var cleaning = false
    private var flash: String?
    private var timer: Timer?
    private var spinnerTimer: Timer?
    private var spinnerStep = 0
    private let panda = PandaArt.menuBarIcon()
    /// `--demo light` or `--demo dark` shows made-up data and opens the menu. It never scans or deletes.
    private let demoStyle: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo") else { return nil }
        return i + 1 < args.count ? args[i + 1] : "light"
    }()

    private var activity: Activity { cleaning ? .cleaning : (scanning ? .scanning : .idle) }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        Log.info("launch Trash Panda \(version), log at \(Log.fileURL.path)")
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
        if let style = demoStyle {
            menu.appearance = NSAppearance(named: style == "dark" ? .darkAqua : .aqua)
            result = DemoData.result()
            disk = result!.disk
            refreshStatusItem()
            rebuildMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
            return
        }
        refreshStatusItem()
        rebuildMenu()
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.scan() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if demoStyle == nil { disk = DiskUsage.current() }
        refreshStatusItem()
        if let last = result?.date, Date().timeIntervalSince(last) > 30 * 60 { scan() }
        rebuildMenu()
    }

    // MARK: Scan

    private func scan() {
        guard demoStyle == nil, !scanning, !cleaning else { return }
        scanning = true
        busyChanged()
        let scanner = self.scanner
        DispatchQueue.global(qos: .utility).async {
            let r = scanner.scan()
            DispatchQueue.main.async {
                self.result = r
                self.disk = r.disk
                self.scanning = false
                self.busyChanged()
            }
        }
    }

    // MARK: Menu bar item and spinner

    /// Call when scanning or cleaning starts or stops.
    private func busyChanged() {
        if activity == .idle {
            spinnerTimer?.invalidate()
            spinnerTimer = nil
        } else if spinnerTimer == nil {
            spinnerStep = 0
            let t = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.spinnerStep += 1
                self.statusItem.button?.image = PandaArt.spinnerFrame(self.spinnerStep)
            }
            RunLoop.main.add(t, forMode: .common)   // keeps turning while the menu is open
            spinnerTimer = t
        }
        refreshStatusItem()
        rebuildMenu()
    }

    private func refreshStatusItem() {
        if activity == .idle { statusItem.button?.image = panda }
        let text = cleaning ? "Cleaning…" : (flash ?? Format.bytes(disk.free))
        statusItem.button?.title = " \(text)"
    }

    // MARK: Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        header.update(disk: disk, reclaimable: result?.reclaimable ?? 0, reviewable: result?.reviewable ?? 0,
                      activity: activity)
        menu.addItem(.separator())

        if cleaning {
            menu.addItem(disabled("Cleaning…"))
        } else if let result {
            let safe = result.findings.filter { $0.tier == .safe }
            if safe.isEmpty {
                menu.addItem(disabled(scanning ? "Scanning…" : "Nothing to clean automatically"))
            } else {
                let item = NSMenuItem(title: "Free up \(Format.bytes(result.reclaimable))…",
                                      action: #selector(confirmAndClean(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = FindingBox(
                    safe, title: "Free up \(Format.bytes(result.reclaimable))?",
                    body: "Trash Panda will clear old build files and caches from \(names(of: safe)).")
                menu.addItem(item)
            }
            menu.addItem(.separator())
            addEcosystems(result.findings)
        } else {
            menu.addItem(disabled("Scanning…"))
        }

        menu.addItem(.separator())
        let rescan = NSMenuItem(title: scanning ? "Scanning…" : "Scan again", action: #selector(rescan), keyEquivalent: "r")
        rescan.target = self
        rescan.isEnabled = !scanning && !cleaning
        menu.addItem(rescan)

        // Hold Option to see the log item. It is for support, so it stays out of the way.
        let log = NSMenuItem(title: "Show log in Finder", action: #selector(showLog), keyEquivalent: "r")
        log.keyEquivalentModifierMask = [.option]
        log.isAlternate = true
        log.target = self
        menu.addItem(log)

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Quit Trash Panda", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addEcosystems(_ findings: [Finding]) {
        let grouped = Dictionary(grouping: findings, by: \.ecosystem)
        let ordered = grouped.sorted { a, b in
            a.value.reduce(0) { $0 + $1.bytes } > b.value.reduce(0) { $0 + $1.bytes }
        }
        for (ecosystem, items) in ordered {
            let total = items.reduce(Int64(0)) { $0 + $1.bytes }
            let parent = NSMenuItem()
            parent.attributedTitle = line(ecosystem.name, Format.bytes(total))
            parent.submenu = submenu(for: ecosystem, items: items)
            menu.addItem(parent)
        }
    }

    private func submenu(for ecosystem: Ecosystem, items: [Finding]) -> NSMenu {
        let sub = NSMenu()
        if ecosystem == .docker, let engine = items.first?.location, engine.hasPrefix("Docker engine: ") {
            sub.addItem(disabled(engine.replacingOccurrences(of: "Docker engine: ", with: "Engine: ") + " (local)"))
            sub.addItem(.separator())
        }
        let safe = items.filter { $0.tier == .safe }.sorted { $0.bytes > $1.bytes }
        let review = items.filter { $0.tier == .review }.sorted { $0.bytes > $1.bytes }

        if !safe.isEmpty {
            let total = safe.reduce(Int64(0)) { $0 + $1.bytes }
            let item = NSMenuItem(title: "Free up \(Format.bytes(total))…",
                                  action: #selector(confirmAndClean(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = FindingBox(
                safe, title: "Free up \(Format.bytes(total)) of \(ecosystem.name) files?",
                body: "Trash Panda will clear old build files and caches.")
            sub.addItem(item)
            sub.addItem(.separator())
            for f in safe.prefix(12) { sub.addItem(findingItem(f)) }
            if safe.count > 12 { sub.addItem(disabled("+ \(safe.count - 12) more")) }
        }
        if !review.isEmpty {
            if !safe.isEmpty { sub.addItem(.separator()) }
            sub.addItem(disabled("Take a look first"))
            for f in review.prefix(12) { sub.addItem(findingItem(f)) }
            if review.count > 12 { sub.addItem(disabled("+ \(review.count - 12) more")) }
        }
        return sub
    }

    private func findingItem(_ f: Finding) -> NSMenuItem {
        let item = NSMenuItem(title: f.title, action: #selector(confirmAndClean(_:)), keyEquivalent: "")
        item.attributedTitle = line(f.title, Format.bytes(f.bytes))
        item.target = self
        // Something that cannot be rebuilt gets its own words. "Your tools will rebuild it" would be wrong.
        let cannotRebuild = f.rebuild == .recreate
        item.representedObject = FindingBox(
            [f],
            title: cannotRebuild ? "Remove this container?" : "Free up \(Format.bytes(f.bytes))?",
            body: singleBody(f),
            footer: cannotRebuild ? "A container can hold data that is stored nowhere else. This can't be undone." : nil,
            confirmTitle: cannotRebuild ? "Remove" : nil)
        var tip = "\(f.location)\n\(f.rebuild.label)"
        if isProject(f), let days = daysSinceActivity(f) {
            tip += "\nLast worked on \(days == 0 ? "today" : "\(days) days ago")"
        }
        item.toolTip = tip
        return item
    }

    private func singleBody(_ f: Finding) -> String {
        var text = f.rebuild == .recreate
            ? "\(f.title)\n\(f.location)\n\(f.rebuild.label)."
            : "\(f.title)\n\(f.rebuild.label)."
        if isProject(f), f.tier == .review, let days = daysSinceActivity(f), days < scanner.config.staleDays {
            text += " You worked on this project \(days == 0 ? "today" : "\(days) days ago")."
        }
        return text
    }

    /// Only a project folder has "last worked on". A Docker image has "on this Mac for".
    private func isProject(_ f: Finding) -> Bool {
        if case .removeArtifact = f.action { return true }
        return false
    }

    private func daysSinceActivity(_ f: Finding) -> Int? {
        f.lastActivity.map { max(0, Int(Date().timeIntervalSince($0) / 86_400)) }
    }

    /// "JavaScript, Xcode and 2 more"
    private func names(of findings: [Finding]) -> String {
        var seen: [String] = []
        for f in findings.sorted(by: { $0.bytes > $1.bytes }) where !seen.contains(f.ecosystem.name) {
            seen.append(f.ecosystem.name)
        }
        switch seen.count {
        case 0: return "your tools"
        case 1: return seen[0]
        case 2: return "\(seen[0]) and \(seen[1])"
        default: return "\(seen[0]), \(seen[1]) and \(seen.count - 2) more"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func line(_ left: String, _ right: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 268)]
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: "\(left)\t\(right)", attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .paragraphStyle: style,
        ])
    }

    // MARK: Actions

    @objc private func rescan() {
        Log.info("user: scan again")
        scan()
    }

    @objc private func showLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.error("Open at login failed: \(error.localizedDescription)")
        }
    }

    /// One short dialog. It says what happens and that it cannot be undone. Nothing more.
    @objc private func confirmAndClean(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? FindingBox, !cleaning, demoStyle == nil else { return }
        let total = box.findings.reduce(Int64(0)) { $0 + $1.bytes }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = box.title
        let footer = box.footer
            ?? "Your code and settings are not touched. This can't be undone, but your tools will rebuild what they need."
        alert.informativeText = box.body + "\n\n" + footer
        let confirm = alert.addButton(withTitle: box.confirmTitle ?? "Free up \(Format.bytes(total))")
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            Log.info("user: cancelled clean of \(box.findings.count) items")
            return
        }
        Log.info("user: confirmed clean of \(box.findings.count) items, \(total) bytes: \(box.findings.map(\.id).joined(separator: ", "))")
        perform(box.findings)
    }

    private func perform(_ findings: [Finding]) {
        cleaning = true
        busyChanged()
        let cleaner = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:))
        DispatchQueue.global(qos: .utility).async {
            let report = cleaner.clean(findings)
            DispatchQueue.main.async { self.finish(report) }
        }
    }

    private func finish(_ report: CleanReport) {
        cleaning = false
        disk = DiskUsage.current()
        flash = report.freed > 0 ? "Freed \(Format.bytes(report.freed))" : "Nothing to free"
        busyChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.flash = nil
            self?.refreshStatusItem()
        }
        if !report.failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = "A few things couldn't be cleaned"
            alert.informativeText = "They may be in use. Close your editor or Docker and try again. Details are in the log."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        scan()
    }
}
