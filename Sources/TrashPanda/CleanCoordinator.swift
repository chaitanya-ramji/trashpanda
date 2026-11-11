import AppKit
import PandaCore

/// Runs a clean: it asks the user, optionally quits the owner app, cleans in the background, and shows the result.
/// It owns the "cleaning" state and the short "Freed ..." text. The app delegate learns about changes by the callbacks.
final class CleanCoordinator {
    private(set) var isCleaning = false
    /// "Freed 1.2 GB", shown in the menu bar for a few seconds after a clean.
    private(set) var flash: String?
    /// "Cleaning 3 of 38 · Xcode build data". nil when no clean runs.
    private(set) var progressText: String?
    private let stop = StopRequest()
    var stopRequested: Bool { stop.isRequested }

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
        stop.reset()
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
        stop.reset()
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
                    self.stop.reset()
                    self.busyChanged()
                    Dialogs.showStillOpen(names)
                    self.requestScan()
                }
            }
        }
    }

    /// The user chose "Stop after this item". The item that runs now finishes. The others are left alone.
    func requestStop() {
        guard isCleaning, !stop.isRequested else { return }
        Log.info("user: stop after this item")
        stop.request()
        busyChanged()
    }

    private func perform(_ findings: [Finding]) {
        // A stop that the user made before this point (for example while the app quits) stays set.
        isCleaning = true
        progressText = nil
        busyChanged()
        let cleaner = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:),
                              runningApps: runningApps, runtimeRequests: scanner.runtimeRequests)
        let stop = self.stop
        cleaner.shouldStop = { stop.isRequested }
        let total = findings.count
        DispatchQueue.global(qos: .utility).async {
            var number = 0
            let throttle = ProgressThrottle()
            let report = cleaner.clean(findings, progress: { title in
                number += 1
                guard throttle.shouldShow(number: number, total: total) else { return }
                let text = CleanProgress.text(number: number, total: total, title: title)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCleaning else { return }
                    self.progressText = text
                    self.busyChanged()
                }
            })
            DispatchQueue.main.async { self.finish(report) }
        }
    }

    private func finish(_ report: CleanReport) {
        isCleaning = false
        stop.reset()
        progressText = nil
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
