import AppKit
import PandaCore

/// Runs a clean: it asks the user, optionally quits the owner app, cleans in the background, and shows the result.
/// It owns the "cleaning" state and the short "Freed ..." text. The app delegate learns about changes by the callbacks.
final class CleanCoordinator {
    private(set) var isCleaning = false
    /// "Freed 1.2 GB", shown in the menu bar for a few seconds after a clean.
    private(set) var flash: String?

    private let scanner: DiskScanner
    private let runningApps: RunningApps

    /// Called when cleaning starts or stops.
    var busyChanged: () -> Void = {}
    /// Called when the flash text goes away.
    var flashCleared: () -> Void = {}
    /// Called with the new disk numbers after a clean.
    var diskChanged: (DiskUsage) -> Void = { _ in }
    /// Called when a scan should run.
    var requestScan: () -> Void = {}

    init(scanner: DiskScanner, runningApps: RunningApps) {
        self.scanner = scanner
        self.runningApps = runningApps
    }

    func confirmAndClean(_ box: FindingBox) {
        guard !isCleaning else { return }
        let total = box.findings.reduce(Int64(0)) { $0 + $1.bytes }
        guard Dialogs.confirm(box) else {
            Log.info("user: cancelled clean of \(box.findings.count) items")
            return
        }
        Log.info("user: confirmed clean of \(box.findings.count) items, \(total) bytes: \(box.findings.map(\.id).joined(separator: ", "))")
        perform(box.findings)
    }

    /// Asks the owner app to quit, politely, and cleans when it has. An app that stays open is left alone.
    func confirmQuitAndClean(_ box: FindingBox) {
        guard let finding = box.findings.first, let owner = finding.owner, !isCleaning else { return }
        guard Dialogs.confirm(box) else {
            Log.info("user: cancelled quit and clean of \(finding.id)")
            return
        }
        Log.info("user: confirmed quit and clean of \(finding.id)")
        isCleaning = true
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
                    self.isCleaning = false
                    self.busyChanged()
                    Dialogs.showStillOpen(names)
                    self.requestScan()
                }
            }
        }
    }

    private func perform(_ findings: [Finding]) {
        isCleaning = true
        busyChanged()
        let cleaner = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:),
                              runningApps: runningApps, runtimeRequests: scanner.runtimeRequests)
        DispatchQueue.global(qos: .utility).async {
            let report = cleaner.clean(findings)
            DispatchQueue.main.async { self.finish(report) }
        }
    }

    private func finish(_ report: CleanReport) {
        isCleaning = false
        diskChanged(DiskUsage.current())
        flash = report.freed > 0 ? "Freed \(Format.bytes(report.freed))" : "Nothing to free"
        busyChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.flash = nil
            self?.flashCleared()
        }
        Dialogs.showReport(report)
        requestScan()
    }
}
