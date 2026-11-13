import Foundation
import PandaCore
import UserNotifications

/// The thin AppKit side of the low-disk alert (#34). The decision, the busy flag, the once-a-day rule, and the log lines are in
/// `LowDiskMonitor` (PandaCore), where tests cover them. This file reads the free space, keeps the day of the last alert,
/// and shows the notification.
final class LowDiskNotifier {
    private static let lastAlertKey = "lowDiskAlertLastDate"

    /// A notification needs an app bundle. A plain `swift run` build has none, so it shows nothing.
    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private lazy var monitor = LowDiskMonitor(
        limitGB: { Config.readLowDiskAlertGB() },
        freeBytes: { DiskUsage.alertFree() },
        lastAlert: { UserDefaults.standard.object(forKey: Self.lastAlertKey) as? Date },
        saveAlert: { UserDefaults.standard.set($0, forKey: Self.lastAlertKey) },
        show: { [weak self] title, body, done in
            guard let self else { done(.unavailable); return }
            self.show(title: title, body: body) { outcome in DispatchQueue.main.async { done(outcome) } }
        })

    /// One check. The caller is the refresh timer, not a loop of its own.
    func check() { monitor.check() }

    /// Shows the notice when macOS allows it. The outcome says why when it is not shown.
    private func show(title: String, body: String, done: @escaping (NoticeOutcome) -> Void) {
        guard canNotify else { done(.unavailable); return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional: break
            case .notDetermined: done(.permissionNotAsked); return
            default: done(.permissionDenied); return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: "low-disk-alert", content: content, trigger: nil)
            center.add(request) { error in
                if let error { Log.error("could not show the low-disk alert: \(error.localizedDescription)") }
                done(error == nil ? .shown : .unavailable)
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
