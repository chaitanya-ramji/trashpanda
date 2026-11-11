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
    /// Text of the button that keeps things as they are, when it is first. When nil, it says "Keep it".
    let cancelTitle: String?
    init(_ findings: [Finding], title: String, body: String, footer: String? = nil, confirmTitle: String? = nil,
         cancelIsDefault: Bool = false, cancelTitle: String? = nil) {
        self.cancelTitle = cancelTitle
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
    private let updates = UpdateController()
    /// Waits a moment after an app opens or quits, so that a burst of changes gives one refresh.
    private var appsChangedTimer: Timer?
    private var spinnerTimer: Timer?
    private var spinnerStep = 0
    private let panda = PandaArt.menuBarIcon()
    /// Demo mode with `--backdrop` puts a plain window behind the menu, so that a screenshot does not show other windows.
    private var backdrop: NSWindow?
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
    private func showBackdrop(dark: Bool) {
        guard let frame = statusItem.button?.window?.frame, let screen = NSScreen.main else { return }
        let area = NSRect(x: frame.minX - 60, y: screen.frame.maxY - 24 - 520, width: 460, height: 520)
        let window = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.91, alpha: 1)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.orderFrontRegardless()
        backdrop = window
    }

    /// `--hover N` and `--click N` act on the Nth part of the split bar in demo mode.
    private func demoNumber(_ flag: String) -> Int? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }
    private let demoStyle: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo") else { return nil }
        return i + 1 < args.count ? args[i + 1] : "light"
    }()

    private var activity: Activity { cleaning ? .cleaning : (scanning ? .scanning : .idle) }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = UpdateController.currentVersion
        Log.info("launch Trash Panda \(version), log at \(Log.fileURL.path)")
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
        if demoStyle == nil {
            updates.onChange = { [weak self] in self?.rebuildMenu() }
            updates.start()
        }
        if let style = demoStyle {
            menu.appearance = NSAppearance(named: style == "dark" ? .darkAqua : .aqua)

            let demo = DemoData.result()
            result = ScanResult(findings: demo.findings.filter(\.isActionable), disk: demo.disk)
            disk = result!.disk
            refreshStatusItem()
            rebuildMenu()
            refreshRunning()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                // The status item has its place by now, so the backdrop can go right under it.
                if CommandLine.arguments.contains("--backdrop") { self.showBackdrop(dark: style == "dark") }
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
                    // While a menu is open, the run loop is in tracking mode. Plain dispatch blocks do not run then,
                    // so these timers use the common modes. Opening the menu resets the header, so they wait for it.
                    func later(_ seconds: Double, _ work: @escaping () -> Void) {
                        let t = Timer(timeInterval: seconds, repeats: false) { _ in work() }
                        RunLoop.main.add(t, forMode: .common)
                    }
                    if let n = self.demoNumber("--hover") { later(1.2) { self.header.simulateHover(n) } }
                    if let n = self.demoNumber("--click") { later(1.6) { self.header.simulateClick(n) } }
                    // A short wait, so that the backdrop is on screen before the menu opens over it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.statusItem.button?.performClick(nil) }
                }
            }
            return
        }
        refreshStatusItem()
        rebuildMenu()
        refreshRunning()
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.scan() }
        // An app that opens or quits changes which items are blocked. The bar and the rows must follow, also while
        // the menu is open. A scan, a clean, and opening the menu rebuild the menu already.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.appsChanged() }
        }
    }

    /// Called when an app opens or quits. After a short wait, the menu is rebuilt if an item became blocked or free.
    private func appsChanged() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.appsChanged() }; return }
        appsChangedTimer?.invalidate()
        // The common modes, so that the timer also fires while the menu is open.
        let t = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self, self.result != nil, !self.cleaning else { return }
            self.refreshRunning()
        }
        RunLoop.main.add(t, forMode: .common)
        appsChangedTimer = t
    }

    /// Reads the running apps in the background. The menu is rebuilt only when it changes which items are blocked,
    /// because a rebuild closes a submenu that the user has open. Nothing here waits for a process.
    private func refreshRunning() {
        runningApps.refresh { [weak self] in
            guard let self, !self.cleaning else { return }
            let before = (self.result?.findings ?? []).map(self.blockers)
            self.running = self.runningApps.cached
            if (self.result?.findings ?? []).map(self.blockers) != before { self.rebuildMenu() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if demoStyle == nil { disk = DiskUsage.current() }
        refreshStatusItem()
        if let last = result?.date, Date().timeIntervalSince(last) > 30 * 60 { scan() }
        rebuildMenu()
        refreshRunning()
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
                // Nothing in the menu is read only. A line that has no action (a note) is not shown. Everything shown can be removed.
                self.result = ScanResult(findings: r.findings.filter(\.isActionable), disk: r.disk)
                self.disk = r.disk
                self.scanning = false
                self.busyChanged()
                self.refreshRunning()
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

        // "Free up" takes only safe items that need no quit.
        let usableSafe = (result?.findings ?? []).filter { $0.isActionable && $0.tier == .safe && blockers($0).isEmpty }
        let safeBytes = usableSafe.reduce(Int64(0)) { $0 + $1.countedBytes }
        // The bar has one part for each group row that shows a size, with the same number as the row.
        // An item of an open app stays in the bar, drawn with stripes. The line under the title does not count it
        // as "free now", because it cannot be freed now. It counts it as "when apps quit", so it does not vanish.
        let all = result?.findings ?? []
        let segments = cleaning ? [] : SplitBar.segments(from: all, blockers: blockers)
        header.update(disk: disk, totals: SplitBar.totals(from: all, blockers: blockers), activity: activity, segments: segments)
        header.onSelect = { [weak self] segment in self?.showGroup(segment) }
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
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
        if let update = updates.available {
            let item = NSMenuItem(title: "Update available: \(update.version)…", action: #selector(openUpdate), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
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

        let check = NSMenuItem(title: "Check for updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let auto = NSMenuItem(title: "Check for updates every day", action: #selector(toggleUpdateCheck), keyEquivalent: "")
        auto.target = self
        auto.state = updates.isEnabled ? .on : .off
        menu.addItem(auto)

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Quit Trash Panda", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addEcosystems(_ findings: [Finding]) {
        let grouped = Dictionary(grouping: findings, by: \.ecosystem)
        // The rows follow the number that each row shows, like the parts of the bar. A tie is broken by name.
        // A row that only says "info" has no number, so it goes after the rows with a size.
        let sizes = grouped.mapValues(SplitBar.rowBytes)
        let ordered = grouped.sorted { a, b in
            let x = sizes[a.key] ?? 0, y = sizes[b.key] ?? 0
            return x != y ? x > y : a.key.name < b.key.name
        }
        for (ecosystem, items) in ordered { menu.addItem(ecosystemItem(ecosystem, items)) }
    }

    /// One row for a group, with its items as a submenu.
    private func ecosystemItem(_ ecosystem: Ecosystem, _ items: [Finding]) -> NSMenuItem {
        // An item of an open app is still an item. Its size shows here, like any other.
        let amount = SplitBar.rowBytes(items)
        let parent = NSMenuItem()
        parent.attributedTitle = line(ecosystem.name, amount > 0 ? Format.bytes(amount) : "info")
        parent.submenu = submenu(for: ecosystem, items: items)
        return parent
    }

    /// The user clicked a part of the split bar. The menu closes, and the items of that group open under the icon.
    private func showGroup(_ segment: SplitSegment) {
        guard let result else { return }
        let popup = NSMenu()
        popup.appearance = menu.appearance
        if let only = segment.ecosystems.first, !segment.isOther {
            popup.items = submenu(for: only, items: result.findings.filter { $0.ecosystem == only }).items
        } else {
            // "Other" is several groups. Each one is a row, so the user can open it.
            for eco in segment.ecosystems {
                popup.addItem(ecosystemItem(eco, result.findings.filter { $0.ecosystem == eco }))
            }
        }
        Log.info("user: opened \(segment.name) from the split bar")
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusItem.button else { return }
            popup.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.height + 4 : -4), in: button)
        }
    }

    /// The AI agents group, split by product. One row for each product, with its icon and what it can free.
    /// Each row opens the usual list of that product, with its own "Free up" line.
    private func nestedAgentMenu(_ items: [Finding]) -> NSMenu {
        let sub = NSMenu()
        let safe = items.filter { $0.isActionable && $0.tier == .safe && blockers($0).isEmpty }
        if !safe.isEmpty {
            let total = safe.reduce(Int64(0)) { $0 + $1.countedBytes }
            let bulk = NSMenuItem(title: "Free up \(Format.bytes(total))…", action: #selector(confirmAndClean(_:)), keyEquivalent: "")
            bulk.target = self
            bulk.representedObject = FindingBox(safe, title: "Free up \(Format.bytes(total)) of AI agents files?",
                                                body: "Trash Panda will clear old build files and caches.")
            sub.addItem(bulk)
            sub.addItem(.separator())
        }
        for group in AgentMenu.groups(items) {
            let parent = NSMenuItem()
            parent.attributedTitle = line(group.product, group.bytes > 0 ? Format.bytes(group.bytes) : "info")
            parent.image = group.info.flatMap(productImage) ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: group.product)
            parent.image?.size = NSSize(width: 16, height: 16)
            parent.submenu = submenu(for: .aiAgents, items: group.items, nest: false)
            sub.addItem(parent)
        }
        return sub
    }

    private func submenu(for ecosystem: Ecosystem, items: [Finding], nest: Bool = true) -> NSMenu {
        if nest, ecosystem == .aiAgents, AgentMenu.shouldNest(items) { return nestedAgentMenu(items) }
        let sub = NSMenu()
        let font = NSFont.menuFont(ofSize: 0)
        let widest = items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        tabLocation = min(520, max(268, widest + 90))
        defer {
            tabLocation = 268
            // One column for the text: if any row has an app icon, the other rows get a blank one.
            if sub.items.contains(where: { $0.image != nil }) {
                let blank = NSImage(size: NSSize(width: 16, height: 16))
                for item in sub.items where item.image == nil && !item.isSeparatorItem { item.image = blank }
            }
        }
        if ecosystem == .docker, let engine = items.first?.location, engine.hasPrefix("Docker engine: ") {
            sub.addItem(disabled(engine.replacingOccurrences(of: "Docker engine: ", with: "Engine: ") + " (local)"))
            sub.addItem(.separator())
        }
        let actionable = items.filter(\.isActionable)
        // The bulk "Free up" line takes only items that need no quit. It never quits an app.
        let safeAll = actionable.filter { $0.tier == .safe }.sorted { $0.bytes > $1.bytes }
        let safe = safeAll.filter { blockers($0).isEmpty }
        let review = actionable.filter { $0.tier == .review }.sorted { $0.bytes > $1.bytes }

        if !safe.isEmpty {
            let total = safe.reduce(Int64(0)) { $0 + $1.countedBytes }
            let item = NSMenuItem(title: "Free up \(Format.bytes(total))…",
                                  action: #selector(confirmAndClean(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = FindingBox(
                safe, title: "Free up \(Format.bytes(total)) of \(ecosystem.name) files?",
                body: "Trash Panda will clear old build files and caches.")
            sub.addItem(item)
        }
        if !safeAll.isEmpty {
            if !safe.isEmpty { sub.addItem(.separator()) }
            for f in safeAll.prefix(12) { sub.addItem(findingItem(f)) }
            if safeAll.count > 12 { sub.addItem(moreItem(Array(safeAll.dropFirst(12)))) }
        }
        if !review.isEmpty {
            if !safeAll.isEmpty { sub.addItem(.separator()) }
            sub.addItem(disabled("Take a look first"))
            for f in review.prefix(12) { sub.addItem(findingItem(f)) }
            if review.count > 12 { sub.addItem(moreItem(Array(review.dropFirst(12)))) }
        }
        return sub
    }

    /// The rows after the first 12 of a list. They open in a submenu, so that no row is hidden behind a disabled "+ N more".
    private func moreItem(_ rest: [Finding]) -> NSMenuItem {
        let parent = NSMenuItem(title: "\(rest.count) more…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for f in rest { sub.addItem(findingItem(f)) }
        if sub.items.contains(where: { $0.image != nil }) {
            let blank = NSImage(size: NSSize(width: 16, height: 16))
            for item in sub.items where item.image == nil { item.image = blank }
        }
        parent.submenu = sub
        return parent
    }

    private func findingItem(_ f: Finding) -> NSMenuItem {
        let item = NSMenuItem(title: f.title, action: #selector(confirmAndClean(_:)), keyEquivalent: "")
        item.attributedTitle = line(f.title, f.sizeText)
        item.target = self
        item.image = icon(for: f)
        let open = blockers(f)
        if open.isEmpty {
            item.representedObject = dialog(for: f)
        } else {
            // The app is open. The row looks like any other. The click asks, then quits the app politely, then cleans.
            let names = open.joined(separator: " and ")
            let c = Confirmation.forOne(f, staleDays: scanner.config.staleDays)
            item.action = #selector(confirmQuitAndClean(_:))
            item.representedObject = FindingBox(
                [f], title: c.title,
                body: c.body + "\n\n\(names) is open. Trash Panda will ask it to quit first. If it asks to save your work, answer it.",
                footer: c.footer, confirmTitle: "Quit \(names) and free \(Format.bytes(f.bytes))",
                cancelIsDefault: true, cancelTitle: "Not now")
        }
        var tip = "\(f.location)\n\(f.rebuild.label)"
        if isProject(f), let days = daysSinceActivity(f) {
            tip += "\nLast worked on \(days == 0 ? "today" : "\(days) days ago")"
        }
        item.toolTip = tip
        return item
    }

    /// The small icon of the app that owns an item: the running app, or the installed one.
    /// The icon of an item: the icon of its owner app, or the icon of its product (AI agents), or a symbol.
    private func icon(for f: Finding) -> NSImage? {
        if let owner = f.owner, let icon = appIcon(owner) { return icon }
        guard f.ecosystem == .aiAgents, let info = AgentProduct.info(forTitle: f.title) else { return nil }
        return productImage(info)
    }

    /// The icon of a product: its app when it is installed, and its symbol when it is not.
    private func productImage(_ info: AgentProduct.Info) -> NSImage? {
        let workspace = NSWorkspace.shared
        for id in info.iconBundleIDs {
            if let url = workspace.urlForApplication(withBundleIdentifier: id) {
                let icon = workspace.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                return icon
            }
        }
        let symbol = NSImage(systemSymbolName: info.symbol, accessibilityDescription: info.name)
        symbol?.size = NSSize(width: 16, height: 16)
        return symbol
    }

    private func appIcon(_ owner: AppOwner) -> NSImage? {
        let workspace = NSWorkspace.shared
        var icon = workspace.runningApplications.first { app in app.bundleIdentifier.map(owner.matches(bundleID:)) ?? false
            && app.activationPolicy == .regular }?.icon
        if icon == nil {
            for id in owner.bundleIDs where !id.hasSuffix("*") && !id.contains(".helper") {
                if let url = workspace.urlForApplication(withBundleIdentifier: id) { icon = workspace.icon(forFile: url.path); break }
            }
        }
        guard let small = icon?.copy() as? NSImage else { return nil }
        small.size = NSSize(width: 16, height: 16)
        return small
    }

    /// The words of the dialog for one item. They come from the core, where tests check them.
    private func dialog(for f: Finding) -> FindingBox {
        let c = Confirmation.forOne(f, staleDays: scanner.config.staleDays)
        return FindingBox([f], title: c.title, body: c.body, footer: c.footer, confirmTitle: c.confirmTitle,
                          cancelIsDefault: c.cancelIsDefault)
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

    /// Where the sizes end. A submenu with a long title widens it, so that the sizes stay in one column.
    private var tabLocation: CGFloat = 268

    private func line(_ left: String, _ right: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: tabLocation)]
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

    @objc private func openUpdate() { if let release = updates.available { updates.open(release) } }
    @objc private func checkForUpdates() { updates.checkNow() }
    @objc private func toggleUpdateCheck() {
        updates.isEnabled.toggle()
        rebuildMenu()
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
        // A dialog where Cancel is the default is for a delete that loses data. It gets the critical style.
        alert.alertStyle = box.cancelIsDefault ? .critical : .informational
        alert.messageText = box.title
        let footer = box.footer
            ?? "Your code and settings are not touched. This can't be undone, but your tools will rebuild what they need."
        alert.informativeText = box.body + "\n\n" + footer
        let confirmTitle = box.confirmTitle ?? "Free up \(Format.bytes(total))"
        if box.cancelIsDefault {
            // "Keep it" is first, so it is the default button. The Return key keeps the item.
            alert.addButton(withTitle: box.cancelTitle ?? "Keep it")
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

    /// Asks the owner app to quit, politely, and cleans when it has. An app that stays open is left alone.
    @objc private func confirmQuitAndClean(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? FindingBox, let finding = box.findings.first, let owner = finding.owner,
              !cleaning, demoStyle == nil else { return }
        let (alert, confirmed) = makeAlert(for: box)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == confirmed else {
            Log.info("user: cancelled quit and clean of \(finding.id)")
            return
        }
        Log.info("user: confirmed quit and clean of \(finding.id)")
        cleaning = true
        busyChanged()
        let quitter = AppQuitter(running: runningApps, ask: { ids in
            // Main thread. terminate() is the polite request, the same as choosing Quit in the app.
            DispatchQueue.main.sync {
                for id in ids {
                    for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where app.activationPolicy == .regular {
                        _ = app.terminate()
                    }
                }
            }
        })
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = quitter.quit(owner)
            DispatchQueue.main.async {
                switch outcome {
                case .quit:
                    self.perform([finding])
                case .stillOpen(let names):
                    self.cleaning = false
                    self.busyChanged()
                    let alert = NSAlert()
                    let list = names.joined(separator: " and ")
                    alert.messageText = "\(list) is still open"
                    alert.informativeText = "It may be asking you to save. Finish that, or quit it yourself, then clean again. Nothing was removed."
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                    self.scan()
                }
            }
        }
    }

    private func perform(_ findings: [Finding]) {
        cleaning = true
        busyChanged()
        let cleaner = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:),
                              runningApps: runningApps, runtimeRequests: scanner.runtimeRequests)
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
        if let note = report.dockerNote {
            let alert = NSAlert()
            alert.messageText = note
            alert.informativeText = "Docker keeps its data in one disk file, and the file can give the space back slowly."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Read the steps")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(DockerDesktopDisk.helpURL) }
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
