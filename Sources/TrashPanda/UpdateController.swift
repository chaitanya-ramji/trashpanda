import AppKit
import PandaCore

/// Checks for a new version (#32). Once a day, and when the user asks. It never downloads or installs anything:
/// the menu line opens the release page, and the user installs by hand.
final class UpdateController: NSObject {
    /// The newer release, when one exists. The menu shows a line for it.
    private(set) var available: UpdateCheck.Release?
    /// Called on the main thread when `available` changes.
    var onChange: (() -> Void)?
    let preferences = UpdatePreferences()
    private var timer: Timer?
    private var running = false

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// Starts the daily check. The first check waits a little, so that the launch stays quiet.
    func start() {
        let t = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
    }

    var isEnabled: Bool {
        get { preferences.isEnabled }
        set {
            preferences.isEnabled = newValue
            Log.info("update check turned \(newValue ? "on" : "off")")
            if !newValue { available = nil; onChange?() }
        }
    }

    /// An automatic check, only when it is on and a day passed since the last one.
    func checkIfDue() {
        guard preferences.isDue() else { return }
        run(manual: false)
    }

    /// The user asked. This works even when the automatic check is off, and it tells the answer.
    func checkNow() { run(manual: true) }

    private func run(manual: Bool) {
        guard !running else { return }
        running = true
        let current = Self.currentVersion
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = UpdateCheck.check(current: current)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.preferences.markChecked()
                switch outcome {
                case .newer(let release):
                    Log.info("update check: \(release.version) is newer than \(current)")
                    self.available = release
                case .upToDate:
                    Log.info("update check: \(current) is the newest")
                    self.available = nil
                case .failed(let why):
                    Log.info("update check failed: \(why)")
                }
                self.onChange?()
                if manual { self.tell(outcome, current: current) }
            }
        }
    }

    private func tell(_ outcome: UpdateCheck.Outcome, current: String) {
        let alert = NSAlert()
        switch outcome {
        case .newer(let release):
            alert.messageText = "Version \(release.version) is available"
            alert.informativeText = "You have \(current). Trash Panda does not install updates. The release page has the download and the steps."
            alert.addButton(withTitle: "Open the release page")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { open(release) }
            return
        case .upToDate:
            alert.messageText = "You have the newest version"
            alert.informativeText = "Trash Panda \(current) is the newest release."
        case .failed:
            alert.messageText = "Could not check for updates"
            alert.informativeText = "Check your internet connection and try again."
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Opens the page of the release in the browser. Only a page on github.com in this repository is opened.
    func open(_ release: UpdateCheck.Release) {
        guard UpdateCheck.isTrustedReleaseURL(release.url) else { return }
        NSWorkspace.shared.open(release.url)
    }
}
