import AppKit
import ServiceManagement
import PandaCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let header = StorageHeaderView(frame: .zero)
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
    /// Knows whether the menu is open. While it is, a change updates a few rows and waits for the close.
    private var refreshGate = MenuRefreshGate()
    /// Read when the Settings submenu opens, not at each build.
    private var loginEnabled = false
    private let updates = UpdateController()
    /// Waits a moment after an app opens or quits, so that a burst of changes gives one refresh.
    private var appsChangedTimer: Timer?
    private var spinnerTimer: Timer?
    private var spinnerStep = 0
    private let panda = PandaArt.menuBarIcon()
    /// What runs now. The menu reads it each time it is built, so that "quit Xcode" is always up to date.
    private var running = RunningSnapshot(apps: [])
    private lazy var runningApps: RunningApps = demo?.runningApps ?? .system
    /// Not nil when the app was started with `--demo`. Then nothing is scanned and nothing is deleted.
    private let demo = DemoController(arguments: CommandLine.arguments)

    private var activity: MenuModel.Activity { cleaning ? .cleaning : (scanning ? .scanning : .idle) }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = UpdateController.currentVersion
        Log.info("launch Trash Panda \(version), log at \(Log.fileURL.path)")
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
        if let demo { demo.start(self); return }
        updates.onChange = { [weak self] in self?.menuChanged() }
        updates.start()
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
            if (self.result?.findings ?? []).map(self.blockers) != before { self.menuChanged() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { settingsWillOpen(menu); return }
        if demo == nil { disk = DiskUsage.current() }
        refreshStatusItem()
        if let last = result?.date, Date().timeIntervalSince(last) > 30 * 60 { scan() }
        rebuildMenu()
        refreshGate.opened()
        refreshRunning()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        if refreshGate.closed() { rebuildMenu() }
    }

    /// The Settings submenu is about to open. Only now is the login state read, and the check mark is set.
    private func settingsWillOpen(_ settings: NSMenu) {
        loginEnabled = SMAppService.mainApp.status == .enabled
        settings.items.first { $0.title == "Open at login" }?.state = loginEnabled ? .on : .off
    }

    // MARK: Scan

    private func scan() {
        guard demo == nil, !scanning, !cleaning else { return }
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
        menuChanged()
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
        var input = MenuInput(result: result, disk: disk, scanning: scanning, cleaning: cleaning, running: running,
                              staleDays: scanner.config.staleDays, updateVersion: updates.available?.version,
                              updateCheckEnabled: updates.isEnabled, loginEnabled: loginEnabled)
        input.cleaningTitle = cleaner.progressText
        input.stopRequested = cleaner.stopRequested
        return input
    }

    /// The programs that block this item right now. An empty list means that it can be cleaned.
    private func blockers(_ f: Finding) -> [String] { f.owner.map { running.running($0) } ?? [] }

    /// The state changed. A closed menu is built again. An open menu keeps its rows (a rebuild would close the
    /// submenu that the user reads): the header and two rows are updated, and the build waits for the close.
    private func menuChanged() {
        switch refreshGate.changed() {
        case .rebuild:
            rebuildMenu()
        case .updateLiveRows:
            let model = MenuModel.make(menuInput())
            header.update(disk: model.header.disk, totals: model.header.totals, activity: model.header.activity,
                          segments: model.header.segments)
            builder.updateLiveRows(model: model)
        }
    }

    private func rebuildMenu() {
        let model = MenuModel.make(menuInput())
        header.update(disk: model.header.disk, totals: model.header.totals, activity: model.header.activity,
                      segments: model.header.segments)
        header.onSelect = { [weak self] segment in self?.showGroup(segment) }
        builder.populate(menu, model: model, header: header)
        if let index = model.rows.firstIndex(where: { $0.title == "Settings" && $0.submenu != nil }),
           menu.items.indices.contains(index) {
            menu.items[index].submenu?.delegate = self
        }
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
            guard demo == nil else { return }
            cleaner.confirmAndClean(FindingBox(prompt))
        case .quitAndClean(let prompt):
            guard demo == nil else { return }
            cleaner.confirmQuitAndClean(FindingBox(prompt))
        case .rescan:
            Log.info("user: scan again")
            scan()
        case .stopClean:
            cleaner.requestStop()
        case .showLog:
            NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
        case .openUpdate:
            if let release = updates.available { updates.open(release) }
        case .checkForUpdates:
            updates.checkNow()
        case .toggleUpdateCheck:
            updates.isEnabled.toggle()
            menuChanged()
        case .toggleLogin:
            toggleLogin()
        case .quit:
            NSApp.terminate(nil)
        case .openKeepList:
            openInTextEdit(Config.ensureFile("keep"))
        case .openRootsList:
            openInTextEdit(Config.ensureFile("roots"))
        case .openHelp:
            NSWorkspace.shared.open(MenuText.helpURL)
        case .reportProblem:
            let os = ProcessInfo.processInfo.operatingSystemVersion
            NSWorkspace.shared.open(MenuText.reportURL(appVersion: UpdateController.currentVersion,
                                                       osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
        case .showAbout:
            NSApp.bringToFront()
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationVersion: UpdateController.currentVersion,
                .credits: NSAttributedString(string: "License: GNU GPL v3"),
            ])
        }
    }

    private func openInTextEdit(_ file: URL) {
        NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// The words of the dialog for one item. They come from the core, where tests check them. Only demo mode uses this.
    func demoDialog(for f: Finding) -> FindingBox {
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
            let alert = NSAlert()
            alert.messageText = "Could not change Open at login"
            alert.informativeText = error.localizedDescription
            NSApp.bringToFront()
            alert.runModal()
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
        menuChanged()
    }
}

extension AppDelegate: DemoHost {
    var statusButton: NSStatusBarButton? { statusItem.button }

    func showDemo(_ demoResult: ScanResult) {
        result = demoResult
        disk = demoResult.disk
        refreshStatusItem()
        menuChanged()
        refreshRunning()
    }
}
