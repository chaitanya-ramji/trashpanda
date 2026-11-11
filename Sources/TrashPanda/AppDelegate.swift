import AppKit
import ServiceManagement
import PandaCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let header = StorageHeaderView(frame: .zero)
    private let scanner = DiskScanner()
    private lazy var builder = MenuBuilder { [weak self] action in self?.handle(action) }
    private lazy var cleaner: CleanCoordinator = {
        let c = CleanCoordinator(scanner: scanner, runningApps: runningApps)
        c.busyChanged = { [weak self] in self?.busyChanged() }
        c.flashCleared = { [weak self] in self?.refreshStatusItem() }
        c.diskChanged = { [weak self] in self?.disk = $0 }
        c.requestScan = { [weak self] in self?.scan() }
        return c
    }()

    private var result: ScanResult?
    private var disk = DiskUsage.current()
    private var scanning = false
    private var cleaning: Bool { cleaner.isCleaning }
    private var flash: String? { cleaner.flash }
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

    private var activity: MenuModel.Activity { cleaning ? .cleaning : (scanning ? .scanning : .idle) }

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
                    _ = Dialogs.makeAlert(for: self.dialog(for: item)).alert.runModal()
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
        let label = MenuText.statusLabel(free: disk.free, total: disk.total, activity: activity)
        statusItem.button?.setAccessibilityLabel(label.accessibility)
        statusItem.button?.toolTip = label.tooltip
    }

    // MARK: Menu

    private func menuInput() -> MenuInput {
        MenuInput(result: result, disk: disk, scanning: scanning, cleaning: cleaning, running: running,
                  staleDays: scanner.config.staleDays, updateVersion: updates.available?.version,
                  updateCheckEnabled: updates.isEnabled, loginEnabled: SMAppService.mainApp.status == .enabled)
    }

    /// The programs that block this item right now. An empty list means that it can be cleaned.
    private func blockers(_ f: Finding) -> [String] { f.owner.map { running.running($0) } ?? [] }

    private func rebuildMenu() {
        let model = MenuModel.make(menuInput())
        header.update(disk: model.header.disk, totals: model.header.totals, activity: model.header.activity,
                      segments: model.header.segments)
        header.onSelect = { [weak self] segment in self?.showGroup(segment) }
        builder.populate(menu, model: model, header: header)
    }


    /// The user clicked a part of the split bar. The menu closes, and the items of that group open under the icon.
    private func showGroup(_ segment: SplitSegment) {
        guard result != nil else { return }
        let popup = NSMenu()
        popup.appearance = menu.appearance
        builder.populate(popup, submenu: MenuModel.popup(for: segment, menuInput()))
        Log.info("user: opened \(segment.name) from the split bar")
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusItem.button else { return }
            popup.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.height + 4 : -4), in: button)
        }
    }

    // MARK: Actions

    private func handle(_ action: MenuModel.Action) {
        switch action {
        case .clean(let prompt):
            guard demoStyle == nil else { return }
            cleaner.confirmAndClean(FindingBox(prompt))
        case .quitAndClean(let prompt):
            guard demoStyle == nil else { return }
            cleaner.confirmQuitAndClean(FindingBox(prompt))
        case .rescan:
            Log.info("user: scan again")
            scan()
        case .showLog:
            NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
        case .openUpdate:
            if let release = updates.available { updates.open(release) }
        case .checkForUpdates:
            updates.checkNow()
        case .toggleUpdateCheck:
            updates.isEnabled.toggle()
            rebuildMenu()
        case .toggleLogin:
            toggleLogin()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    /// The words of the dialog for one item. They come from the core, where tests check them. Only demo mode uses this.
    private func dialog(for f: Finding) -> FindingBox {
        let c = Confirmation.forOne(f, staleDays: scanner.config.staleDays)
        return FindingBox([f], title: c.title, body: c.body, footer: c.footer, confirmTitle: c.confirmTitle,
                          cancelIsDefault: c.cancelIsDefault)
    }

    private func toggleLogin() {
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
}

