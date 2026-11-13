import Foundation

/// What happened when the app tried to show the low-disk notice.
public enum NoticeOutcome: Equatable {
    case shown
    /// macOS never asked the user. This happens when the limit was set by editing the settings file.
    case permissionNotAsked
    case permissionDenied
    /// There is no app bundle (a plain `swift run`), or the show failed.
    case unavailable
}

/// The state of one app run for the low-disk alert: the busy flag, the day of the last notice, and the log lines (#229).
/// The app side only shows the notice. It calls `check()` from the refresh timer, and `done` runs on the same thread (the main thread).
/// Every outside thing is a closure, so a test needs no UserNotifications.
public final class LowDiskMonitor {
    private let limitGB: () -> Int?
    private let freeBytes: () -> Int64?
    private let now: () -> Date
    private let lastAlert: () -> Date?
    private let saveAlert: (Date) -> Void
    private let show: (_ title: String, _ body: String, _ done: @escaping (NoticeOutcome) -> Void) -> Void
    /// A closure, so a change of the time zone is seen at the next check (the old code read `Calendar.current` at each check).
    private let calendar: () -> Calendar

    /// True while a notice is on its way. A second check then does nothing.
    public private(set) var busy = false
    /// The day of the last notice in this run. It guards the case where the saved day cannot be written: no repeat in this run.
    private var shownInThisRun: Date?
    private var warned = Set<NoticeOutcome>()

    public init(limitGB: @escaping () -> Int?, freeBytes: @escaping () -> Int64?, now: @escaping () -> Date = Date.init,
                lastAlert: @escaping () -> Date?, saveAlert: @escaping (Date) -> Void,
                show: @escaping (_ title: String, _ body: String, _ done: @escaping (NoticeOutcome) -> Void) -> Void,
                calendar: @escaping () -> Calendar = { .current }) {
        self.limitGB = limitGB
        self.freeBytes = freeBytes
        self.now = now
        self.lastAlert = lastAlert
        self.saveAlert = saveAlert
        self.show = show
        self.calendar = calendar
    }

    /// One check. The day is saved only when a notice was really shown.
    /// Off, or free space that cannot be read: nothing happens, and the volume is not read when the alert is off.
    public func check() {
        guard !busy else { return }
        guard let limit = limitGB(), let free = freeBytes() else { return }
        let time = now()
        let last = [lastAlert(), shownInThisRun].compactMap { $0 }.max()
        guard LowDiskAlert.shouldAlert(limitGB: limit, freeBytes: free, lastAlert: last, now: time, calendar: calendar()) else { return }
        busy = true
        show(LowDiskText.title, LowDiskText.body(freeBytes: free)) { [self] outcome in
            busy = false
            record(outcome)
            if outcome == .shown {
                shownInThisRun = time
                saveAlert(time)
            }
        }
    }

    private func record(_ outcome: NoticeOutcome) {
        switch outcome {
        case .shown:
            Log.info("low-disk alert shown")
        case .permissionNotAsked:
            warnOnce(outcome, "low-disk alert not shown: macOS never asked for the notification permission. Choose a limit in Settings to be asked.")
        case .permissionDenied:
            warnOnce(outcome, "low-disk alert not shown: the notification permission is denied. Allow notifications for Trash Panda in System Settings.")
        case .unavailable:
            Log.info("low-disk alert not shown")
        }
    }

    /// One WARN line for each reason in one run. The check runs again and again, so the same line must not.
    private func warnOnce(_ reason: NoticeOutcome, _ message: String) {
        if warned.insert(reason).inserted { Log.warn(message) }
    }
}
