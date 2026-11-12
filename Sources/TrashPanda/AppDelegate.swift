import AppKit
import ServiceManagement
import PandaCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    /// The header view of the menu that is built now. Each build makes a new one, so two menu items never hold one view.
    private(set) var header = StorageHeaderView(frame: .zero)
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
    /// Decides when the menu builds, updates a few rows, or waits for the close. This class only runs what it says.
    private var wiring = MenuWiring()
    /// Read when the Settings submenu opens, not at each build.
    private var loginEnabled = false
    /// The delete mode of the settings file. Read again when the Settings submenu opens.
    private var deleteMode = Config.readDeleteMode()
    /// The low-disk limit of the settings file in GB. nil: off. Read again when the Settings submenu opens.
    private var lowDiskAlertGB = Config.readLowDiskAlertGB()
    private let lowDisk = LowDiskNotifier()
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

    func applicationWillTerminate(_ notification: Notification) {
        Log.flush()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = UpdateController.currentVersion
        Log.info("launch Trash Panda \(version), log at \(Log.fileURL.path)")
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        Dialogs.keepListChanged = { [weak self] in self?.scan() }
        statusItem.menu = menu
        if let demo { demo.start(self); return }
        updates.onChange = { [weak self] in self?.menuChanged() }
        updates.start()
        refreshStatusItem()
        menuChanged()   // the menu is closed: it builds at once
        refreshRunning()
        scan()
        lowDisk.check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.scan()
            self?.lowDisk.check()
        }
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
        wiring.openingBegan()
        if let last = result?.date, Date().timeIntervalSince(last) > 30 * 60 { scan() }
        run(wiring.openingFinished(model: MenuModel.make(menuInput())))
        refreshRunning()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        run(wiring.menuClosed(model: MenuModel.make(menuInput())))
    }

    /// The Settings submenu is about to open. Only now is the login state read, and the check mark is set.
    private func settingsWillOpen(_ settings: NSMenu) {
        loginEnabled = SMAppService.mainApp.status == .enabled
        settings.items.first { $0.title == "Open at login" }?.state = loginEnabled ? .on : .off
        deleteMode = Config.readDeleteMode()
        settings.items.first { $0.title == MenuText.trashModeTitle }?.state = deleteMode == .trash ? .on : .off
        lowDiskAlertGB = Config.readLowDiskAlertGB()
        for item in settings.items.first(where: { $0.title == LowDiskText.settingTitle })?.submenu?.items ?? [] {
            item.state = item.title == LowDiskText.choiceTitle(lowDiskAlertGB) ? .on : .off
        }
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
                // Every item in a list can be removed. A line that has no action is not an item: it goes to "Good to know".
                self.result = ScanResult(findings: r.findings.filter(\.isActionable), disk: r.disk,
                                         infoRows: StorageFacts.rows(from: r.findings, disk: r.disk))
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
        run(wiring.activityChanged(activity))
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
        input.deleteMode = deleteMode
        input.lowDiskAlertGB = lowDiskAlertGB
        input.cleaningTitle = cleaner.progressText
        input.stopRequested = cleaner.stopRequested
        return input
    }

    /// The programs that block this item right now. An empty list means that it can be cleaned.
    private func blockers(_ f: Finding) -> [String] { f.owner.map { running.running($0) } ?? [] }

    /// The state changed. A closed menu is built again. An open menu keeps its rows (a rebuild would close the
    /// submenu that the user reads): the header and two rows are updated, and the build waits for the close.
    private func menuChanged() {
        run(wiring.modelChanged(MenuModel.make(menuInput())))
    }

    /// Runs what `MenuWiring` decided. There is no decision here.
    private func run(_ actions: [MenuWiring.Action]) {
        for action in actions {
            switch action {
            case .buildMenu(let model, let headerIsOpen):
                // A new header view for each build. An equal model builds nothing.
                guard let fresh = builder.rebuild(menu, model: model, onSelect: { [weak self] segment in self?.showGroup(segment) }) else { continue }
                header = fresh
                header.isMenuOpen = headerIsOpen
                if let index = model.rows.firstIndex(where: { $0.title == "Settings" && $0.submenu != nil }),
                   menu.items.indices.contains(index) {
                    menu.items[index].submenu?.delegate = self
                }
            case .skipEqualModel:
                break
            case .updateLiveRows(let model, let content):
                header.updateLive(content: content)
                builder.updateLiveRows(model: model)
                builder.invalidate()   // the open menu no longer shows the last build
            case .setHeaderOpen(let open):
                header.isMenuOpen = open   // the timer of the header stops when it closes
            case .startSpinner:
                spinnerStep = 0
                let t = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.spinnerStep += 1
                    self.statusItem.button?.image = PandaArt.spinnerFrame(self.spinnerStep)
                }
                RunLoop.main.add(t, forMode: .common)   // keeps turning while the menu is open
                spinnerTimer = t
            case .stopSpinner:
                spinnerTimer?.invalidate()
                spinnerTimer = nil
            }
        }
    }

    /// The user clicked a part of the split bar. The menu closes, and the items of that group open under the icon.
    private func showGroup(_ segment: SplitSegment) {
        guard result != nil, !cleaning else { return }
        let popup = NSMenu()
        popup.appearance = menu.appearance
        let input = menuInput()
        builder.populate(popup, submenu: MenuModel.popup(for: segment, input), tab: builder.mainTab(for: MenuModel.make(input)))
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
        case .toggleTrashMode:
            let next: DeleteMode = Config.readDeleteMode() == .trash ? .permanent : .trash
            if Config.setDeleteMode(next) {
                Log.info("user: delete mode is now \(next.rawValue)")
            } else {
                Log.error("could not save the delete mode")
            }
            deleteMode = Config.readDeleteMode()
            menuChanged()
        case .setLowDiskAlert(let gb):
            if Config.setLowDiskAlertGB(gb) {
                Log.info("user: low-disk alert is now \(LowDiskAlert.settingValue(gb))")
            } else {
                Log.error("could not save the low-disk alert")
            }
            lowDiskAlertGB = Config.readLowDiskAlertGB()
            menuChanged()
            // The permission is asked only now, when the user turns the alert on.
            if gb != nil { lowDisk.requestPermission { [weak self] in self?.lowDisk.check() } }
        case .quit:
            NSApp.terminate(nil)
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
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
