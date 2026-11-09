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
    /// When true, the first (default) button keeps the item. The Return key then cannot delete it.
    let cancelIsDefault: Bool
    init(_ findings: [Finding], title: String, body: String, footer: String? = nil, confirmTitle: String? = nil,
         cancelIsDefault: Bool = false) {
        self.findings = findings
        self.title = title
        self.body = body
        self.footer = footer
        self.confirmTitle = confirmTitle
        self.cancelIsDefault = cancelIsDefault
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
    /// What runs now. The menu reads it each time it is built, so that "quit Xcode" is always up to date.
    private var running = RunningSnapshot(apps: [])
    private lazy var runningApps: RunningApps = {
        // Demo mode pretends that Xcode runs, so that a screenshot can show a blocked item.
        guard demoStyle != nil else { return .system }
        return RunningApps { RunningSnapshot(apps: [RunningApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")]) }
    }()
    /// `--demo light` or `--demo dark` shows made-up data and opens the menu. It never scans or deletes.
    private let demoDialog: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--dialog"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    /// `--submenu docker` pops that submenu open in demo mode, for screenshots.
    private let demoSubmenu: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--submenu"), i + 1 < args.count else { return nil }
        return args[i + 1].lowercased()
    }()
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
                guard let self else { return }
                // `--dialog volume|container|safe` shows that dialog. It deletes nothing, even if you confirm.
                if let kind = self.demoDialog, let item = DemoData.dialogFinding(kind) {
                    NSApp.activate(ignoringOtherApps: true)
                    _ = self.makeAlert(for: self.dialog(for: item)).alert.runModal()
                    NSApp.terminate(nil)
                } else if let name = self.demoSubmenu,
                          let item = self.menu.items.first(where: { $0.attributedTitle?.string.lowercased().hasPrefix(name) == true }),
                          let sub = item.submenu {
                    sub.appearance = self.menu.appearance
                    sub.popUp(positioning: nil, at: NSPoint(x: 700, y: 800), in: nil)
                } else {
                    self.statusItem.button?.performClick(nil)
                }
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

    /// The programs that block this item right now. An empty list means that it can be cleaned.
    private func blockers(_ f: Finding) -> [String] {
        f.owner.map { running.running($0) } ?? []
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        running = runningApps.take()

        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        // The numbers count only what can be cleaned now. An item of a running app is not in them.
        let usable = (result?.findings ?? []).filter { $0.isActionable && blockers($0).isEmpty }
        let usableSafe = usable.filter { $0.tier == .safe }
        let usableReview = usable.filter { $0.tier == .review }
        let safeBytes = usableSafe.reduce(Int64(0)) { $0 + $1.bytes }
        header.update(disk: disk, reclaimable: safeBytes, reviewable: usableReview.reduce(Int64(0)) { $0 + $1.bytes },
                      activity: activity)
        menu.addItem(.separator())

        if cleaning {
            menu.addItem(disabled("Cleaning…"))
        } else if let result {
            let safe = usableSafe
            if safe.isEmpty {
                menu.addItem(disabled(scanning ? "Scanning…" : "Nothing to clean automatically"))
            } else {
                let item = NSMenuItem(title: "Free up \(Format.bytes(safeBytes))…",
                                      action: #selector(confirmAndClean(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = FindingBox(
                    safe, title: "Free up \(Format.bytes(safeBytes))?",
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
        // Information lines (for example a volume that is in use) are not part of any total.
        func total(_ items: [Finding]) -> Int64 {
            items.filter { $0.isActionable && blockers($0).isEmpty }.reduce(0) { $0 + $1.bytes }
        }
        let ordered = grouped.sorted { total($0.value) > total($1.value) }
        for (ecosystem, items) in ordered {
            let amount = total(items)
            let parent = NSMenuItem()
            let waiting = items.contains { $0.isActionable && !blockers($0).isEmpty }
            parent.attributedTitle = line(ecosystem.name, amount > 0 ? Format.bytes(amount) : (waiting ? "app open" : "info"))
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
        let actionable = items.filter(\.isActionable)
        let blocked = actionable.filter { !blockers($0).isEmpty }.sorted { $0.bytes > $1.bytes }
        let safe = actionable.filter { blockers($0).isEmpty && $0.tier == .safe }.sorted { $0.bytes > $1.bytes }
        let review = actionable.filter { blockers($0).isEmpty && $0.tier == .review }.sorted { $0.bytes > $1.bytes }
        let info = items.filter { !$0.isActionable }.sorted { $0.bytes > $1.bytes }

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
        if !blocked.isEmpty {
            if !safe.isEmpty || !review.isEmpty { sub.addItem(.separator()) }
            sub.addItem(disabled("Quit an app first"))
            for f in blocked.prefix(12) {
                let item = NSMenuItem(title: f.title, action: nil, keyEquivalent: "")
                item.attributedTitle = line(f.title, Format.bytes(f.bytes))
                item.isEnabled = false
                item.toolTip = f.location
                sub.addItem(item)
                let names = blockers(f).joined(separator: " and ")
                let note = NSMenuItem(title: "Quit \(names) to clean this.", action: nil, keyEquivalent: "")
                note.attributedTitle = NSAttributedString(string: "  Quit \(names) to clean this.", attributes: [
                    .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                note.isEnabled = false
                sub.addItem(note)
            }
            if blocked.count > 12 { sub.addItem(disabled("+ \(blocked.count - 12) more")) }
        }
        if !info.isEmpty {
            if !safe.isEmpty || !review.isEmpty || !blocked.isEmpty { sub.addItem(.separator()) }
            sub.addItem(disabled("Information only. Cannot be removed here."))
            for f in info.prefix(12) {
                let item = NSMenuItem(title: f.title, action: nil, keyEquivalent: "")
                item.attributedTitle = line(f.title, Format.bytes(f.bytes))
                item.isEnabled = false
                item.toolTip = f.location
                sub.addItem(item)
                if let note = f.note {
                    let n = NSMenuItem(title: note, action: nil, keyEquivalent: "")
                    n.attributedTitle = NSAttributedString(string: "  " + note, attributes: [
                        .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                    n.isEnabled = false
                    sub.addItem(n)
                }
                if let url = f.helpURL {
                    let link = NSMenuItem(title: "Read the official steps…", action: #selector(openHelp(_:)), keyEquivalent: "")
                    link.target = self
                    link.representedObject = url
                    sub.addItem(link)
                }
            }
            if info.count > 12 { sub.addItem(disabled("+ \(info.count - 12) more")) }
        }
        return sub
    }

    private func findingItem(_ f: Finding) -> NSMenuItem {
        let item = NSMenuItem(title: f.title, action: #selector(confirmAndClean(_:)), keyEquivalent: "")
        item.attributedTitle = line(f.title, Format.bytes(f.bytes))
        item.target = self
        item.representedObject = dialog(for: f)
        var tip = "\(f.location)\n\(f.rebuild.label)"
        if isProject(f), let days = daysSinceActivity(f) {
            tip += "\nLast worked on \(days == 0 ? "today" : "\(days) days ago")"
        }
        item.toolTip = tip
        return item
    }

    /// The words of the dialog for one item. Something that cannot be rebuilt gets its own words.
    /// "Your tools will rebuild it" would be wrong for a container or a volume.
    private func dialog(for f: Finding) -> FindingBox {
        switch f.rebuild {
        case .never:
            return FindingBox(
                [f], title: "Delete this volume?", body: singleBody(f),
                footer: "Databases and files inside a volume are lost for good. If it holds a database, export it first. This can't be undone.",
                confirmTitle: "Delete volume", cancelIsDefault: true)
        case .recreate:
            return FindingBox(
                [f], title: "Remove this container?", body: singleBody(f),
                footer: "A container can hold data that is stored nowhere else. This can't be undone.",
                confirmTitle: "Remove")
        default:
            return FindingBox([f], title: "Free up \(Format.bytes(f.bytes))?", body: singleBody(f))
        }
    }

    private func singleBody(_ f: Finding) -> String {
        // A volume's warning is in the footer. We do not say the same thing twice.
        var text = f.rebuild == .never ? "\(f.title)\n\(f.location)"
            : f.rebuild == .recreate ? "\(f.title)\n\(f.location)\n\(f.rebuild.label)."
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

    @objc private func openHelp(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
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
    /// `confirmed` is the button response that means "yes, delete". It is not always the first button.
    private func makeAlert(for box: FindingBox) -> (alert: NSAlert, confirmed: NSApplication.ModalResponse) {
        let total = box.findings.reduce(Int64(0)) { $0 + $1.bytes }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = box.title
        let footer = box.footer
            ?? "Your code and settings are not touched. This can't be undone, but your tools will rebuild what they need."
        alert.informativeText = box.body + "\n\n" + footer
        let confirmTitle = box.confirmTitle ?? "Free up \(Format.bytes(total))"
        if box.cancelIsDefault {
            // "Keep it" is first, so it is the default button. The Return key keeps the item.
            alert.addButton(withTitle: "Keep it")
            alert.addButton(withTitle: confirmTitle).hasDestructiveAction = true
            return (alert, .alertSecondButtonReturn)
        }
        alert.addButton(withTitle: confirmTitle).hasDestructiveAction = true
        alert.addButton(withTitle: "Not now")
        return (alert, .alertFirstButtonReturn)
    }

    @objc private func confirmAndClean(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? FindingBox, !cleaning, demoStyle == nil else { return }
        let total = box.findings.reduce(Int64(0)) { $0 + $1.bytes }
        let (alert, confirmed) = makeAlert(for: box)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == confirmed else {
            Log.info("user: cancelled clean of \(box.findings.count) items")
            return
        }
        Log.info("user: confirmed clean of \(box.findings.count) items, \(total) bytes: \(box.findings.map(\.id).joined(separator: ", "))")
        perform(box.findings)
    }

    private func perform(_ findings: [Finding]) {
        cleaning = true
        busyChanged()
        let cleaner = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:),
                              runningApps: runningApps)
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
        if !report.blockedApps.isEmpty {
            let alert = NSAlert()
            let names = report.blockedApps.joined(separator: " and ")
            alert.messageText = "Quit \(names) first"
            alert.informativeText = "Some items belong to \(names), and it is open. Trash Panda left them alone. Quit it and clean again."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
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
