import AppKit
import ServiceManagement
import PandaCore

/// Carries findings from a menu item to its action.
final class FindingBox: NSObject {
    let findings: [Finding]
    let heading: String
    init(_ findings: [Finding], heading: String) {
        self.findings = findings
        self.heading = heading
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

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        updateTitle()
        rebuildMenu()
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.scan() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        disk = DiskUsage.current()
        updateTitle()
        if let last = result?.date, Date().timeIntervalSince(last) > 30 * 60 { scan() }
        rebuildMenu()
    }

    // MARK: Scan

    private func scan() {
        guard !scanning, !cleaning else { return }
        scanning = true
        rebuildMenu()
        let scanner = self.scanner
        DispatchQueue.global(qos: .utility).async {
            let r = scanner.scan()
            DispatchQueue.main.async {
                self.result = r
                self.disk = r.disk
                self.scanning = false
                self.updateTitle()
                self.rebuildMenu()
            }
        }
    }

    // MARK: Title

    private func updateTitle() {
        let text = cleaning ? "cleaning…" : (flash ?? Format.bytes(disk.free))
        statusItem.button?.title = "🦝 \(text)"
    }

    // MARK: Menu

    @objc private func rebuildMenu() {
        menu.removeAllItems()

        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        header.update(disk: disk, reclaimable: result?.reclaimable ?? 0, reviewable: result?.reviewable ?? 0,
                      scanning: scanning)
        menu.addItem(.separator())

        if cleaning {
            menu.addItem(disabled("Cleaning…"))
        } else if let result {
            let safe = result.findings.filter { $0.tier == .safe }
            if safe.isEmpty {
                menu.addItem(disabled(scanning ? "Scanning…" : "Nothing safe to reclaim"))
            } else {
                let item = NSMenuItem(title: "Reclaim \(Format.bytes(result.reclaimable))…",
                                      action: #selector(confirmAndClean(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = FindingBox(safe, heading: "Reclaim \(Format.bytes(result.reclaimable))?")
                menu.addItem(item)
            }
            menu.addItem(.separator())
            addEcosystems(result.findings)
        } else {
            menu.addItem(disabled("Scanning…"))
        }

        menu.addItem(.separator())
        let rescan = NSMenuItem(title: scanning ? "Scanning…" : "Scan Again", action: #selector(rescan), keyEquivalent: "r")
        rescan.target = self
        rescan.isEnabled = !scanning && !cleaning
        menu.addItem(rescan)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
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
        let safe = items.filter { $0.tier == .safe }.sorted { $0.bytes > $1.bytes }
        let review = items.filter { $0.tier == .review }.sorted { $0.bytes > $1.bytes }

        if !safe.isEmpty {
            let total = safe.reduce(Int64(0)) { $0 + $1.bytes }
            let item = NSMenuItem(title: "Clean safe items (\(Format.bytes(total)))…",
                                  action: #selector(confirmAndClean(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = FindingBox(safe, heading: "Delete \(Format.bytes(total)) of \(ecosystem.name) files?")
            sub.addItem(item)
            sub.addItem(.separator())
            for f in safe.prefix(12) { sub.addItem(findingItem(f)) }
            if safe.count > 12 { sub.addItem(disabled("+ \(safe.count - 12) more")) }
        }
        if !review.isEmpty {
            if !safe.isEmpty { sub.addItem(.separator()) }
            sub.addItem(disabled("Review first"))
            for f in review.prefix(12) { sub.addItem(findingItem(f)) }
            if review.count > 12 { sub.addItem(disabled("+ \(review.count - 12) more")) }
        }
        return sub
    }

    private func findingItem(_ f: Finding) -> NSMenuItem {
        let item = NSMenuItem(title: f.title, action: #selector(confirmAndClean(_:)), keyEquivalent: "")
        item.attributedTitle = line(f.title, Format.bytes(f.bytes))
        item.target = self
        item.representedObject = FindingBox([f], heading: "Delete \(Format.bytes(f.bytes))?")
        var tip = "\(f.location)\n\(f.rebuild.label)"
        if let d = f.lastActivity {
            let days = max(0, Int(Date().timeIntervalSince(d) / 86_400))
            tip += "\nLast project activity: \(days) days ago"
        }
        item.toolTip = tip
        return item
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

    @objc private func rescan() { scan() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Open at Login failed: \(error.localizedDescription)")
        }
    }

    @objc private func confirmAndClean(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? FindingBox, !cleaning else { return }
        let total = box.findings.reduce(Int64(0)) { $0 + $1.bytes }

        var lines = box.findings.prefix(10).map { "• \($0.title) — \(Format.bytes($0.bytes)) — \($0.rebuild.label.lowercased())" }
        if box.findings.count > 10 { lines.append("• and \(box.findings.count - 10) more") }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = box.heading
        alert.informativeText = lines.joined(separator: "\n")
            + "\n\nThese files are deleted now. They do not go to the Trash.\(total > 0 ? "" : "")"
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(box.findings)
    }

    private func perform(_ findings: [Finding]) {
        cleaning = true
        updateTitle()
        rebuildMenu()
        let cleaner = Cleaner(guardian: scanner.guardian)
        DispatchQueue.global(qos: .utility).async {
            let report = cleaner.clean(findings)
            DispatchQueue.main.async { self.finish(report) }
        }
    }

    private func finish(_ report: CleanReport) {
        cleaning = false
        disk = DiskUsage.current()
        flash = "freed \(Format.bytes(report.freed))"
        updateTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.flash = nil
            self?.updateTitle()
        }
        if !report.failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some items stayed"
            alert.informativeText = report.failed.prefix(8).joined(separator: "\n")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        scan()
    }
}
