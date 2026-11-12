import Foundation
import PandaCore
import UserNotifications

/// The thin AppKit side of the low-disk alert (#34). The decision is in `LowDiskChecker` (PandaCore).
/// This file reads the free space, keeps the day of the last alert, and shows the notification.
final class LowDiskNotifier {
    private static let lastAlertKey = "lowDiskAlertLastDate"

    /// A notification needs an app bundle. A plain `swift run` build has none, so it shows nothing.
    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// True while a notice is on its way. A second check then does nothing.
    private var busy = false

    /// One check. The caller is the refresh timer, not a loop of its own.
    /// The day is saved only when a notice was really shown.
    func check() {
        guard !busy else { return }
        let checker = LowDiskChecker(
            limitGB: { Config.readLowDiskAlertGB() },
            freeBytes: { DiskUsage.alertFree() },
            lastAlert: { UserDefaults.standard.object(forKey: Self.lastAlertKey) as? Date },
            saveAlert: { UserDefaults.standard.set($0, forKey: Self.lastAlertKey) },
            notify: { [weak self] title, body, done in
                guard let self else { done(false); return }
                self.busy = true
                self.show(title: title, body: body) { shown in
                    DispatchQueue.main.async {
                        self.busy = false
                        Log.info(shown ? "low-disk alert shown" : "low-disk alert not shown")
                        done(shown)
                    }
                }
            })
        checker.run()
    }

    /// Shows the notice when macOS allows it. `done(false)` when there is no app bundle, when the permission is not given,
    /// or when the show fails.
    private func show(title: String, body: String, done: @escaping (Bool) -> Void) {
        guard canNotify else { done(false); return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { done(false); return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: "low-disk-alert", content: content, trigger: nil)
            center.add(request) { error in
                if let error { Log.error("could not show the low-disk alert: \(error.localizedDescription)") }
                done(error == nil)
            }
        }
    }

    /// Asks for the permission. The caller does this only when the user turns the alert on.
    func requestPermission(then done: @escaping () -> Void) {
        guard canNotify else { done(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            Log.info("notification permission: \(granted ? "granted" : "not granted")\(error.map { " (\($0.localizedDescription))" } ?? "")")
            DispatchQueue.main.async { done() }
        }
    }
}
