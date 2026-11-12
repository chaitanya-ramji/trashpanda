import Foundation

/// The low-disk alert (#34). The user sets `low_disk_alert_gb = <number>` in `~/.config/trashpanda/settings`,
/// or chooses a limit in Settings. When the free space is below the limit, the app shows one notification.
/// The alert is off by default, and it shows at most once in a calendar day.
public enum LowDiskAlert {
    public static let settingName = "low_disk_alert_gb"
    /// The limits that the Settings menu offers, in GB. The file can hold any whole number in `limitRange`.
    public static let choices = [5, 10, 20, 50]
    public static let limitRange = 1...10_000
    /// A GB is 1 000 000 000 bytes, like Finder and the numbers in the menu.
    public static let bytesPerGB: Int64 = 1_000_000_000

    /// What a settings value means. `nil` is off. A value that is not valid gives `isValid == false` and the limit stays off.
    public static func parse(_ value: String) -> (limitGB: Int?, isValid: Bool) {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "off" { return (nil, true) }
        if let gb = Int(text), limitRange.contains(gb) { return (gb, true) }
        return (nil, false)
    }

    /// The text of the settings file for a limit.
    public static func settingValue(_ limitGB: Int?) -> String { limitGB.map(String.init) ?? "off" }

    /// True when an alert is due now.
    /// - `limitGB`: the limit. `nil` is off, and then the answer is always false.
    /// - `freeBytes`: the free space now. Below the limit means less than the limit. The same as the limit is not below.
    /// - `lastAlert`: when the last alert was shown, or `nil`.
    /// - `now`, `calendar`: they say which calendar day it is. An alert was already shown today: no second one.
    public static func shouldAlert(limitGB: Int?, freeBytes: Int64, lastAlert: Date?, now: Date,
                                   calendar: Calendar = .current) -> Bool {
        guard let limitGB, limitRange.contains(limitGB) else { return false }
        guard freeBytes < Int64(limitGB) * bytesPerGB else { return false }
        if let lastAlert, calendar.isDate(lastAlert, inSameDayAs: now) { return false }
        return true
    }
}

/// The words of the alert. Simple English. No path. It offers nothing that deletes.
public enum LowDiskText {
    public static let title = "Your disk is almost full"

    public static func body(freeBytes: Int64) -> String {
        "Only \(ByteText.string(freeBytes)) is free on your Mac. Open Trash Panda to see what you can clean."
    }

    /// The Settings row, its choices, and the tooltip.
    public static let settingTitle = "Low-disk alert"
    public static let off = "Off"
    public static func choiceTitle(_ limitGB: Int?) -> String { limitGB.map { "\($0) GB" } ?? off }
    public static let settingTooltip =
        "Show a notification when the free space is below this limit. Off: no alert. The app shows at most one alert in a day. It never cleans by itself."
}

/// One check. Every outside thing is a closure, so a test gives a fixed clock, a fixed free space, and a fake notice.
public struct LowDiskChecker {
    public var limitGB: () -> Int?
    /// The free space of the startup volume. `nil` when it cannot be read: then there is no alert.
    public var freeBytes: () -> Int64?
    public var now: () -> Date
    public var lastAlert: () -> Date?
    public var saveAlert: (Date) -> Void
    /// Shows the notice. It calls `done(true)` only when a notice was really shown. Permission denied, or a failed show: `done(false)`.
    public var notify: (_ title: String, _ body: String, _ done: @escaping (Bool) -> Void) -> Void
    public var calendar: Calendar

    public init(limitGB: @escaping () -> Int?, freeBytes: @escaping () -> Int64?, now: @escaping () -> Date = Date.init,
                lastAlert: @escaping () -> Date?, saveAlert: @escaping (Date) -> Void,
                notify: @escaping (_ title: String, _ body: String, _ done: @escaping (Bool) -> Void) -> Void, calendar: Calendar = .current) {
        self.limitGB = limitGB
        self.freeBytes = freeBytes
        self.now = now
        self.lastAlert = lastAlert
        self.saveAlert = saveAlert
        self.notify = notify
        self.calendar = calendar
    }

    /// Reads the limit first. When the alert is off, the volume is not read.
    /// The day is saved only when the notice was really shown, so a denied permission does not use up the day.
    /// `completion` gets true when a notice was shown.
    public func run(completion: ((Bool) -> Void)? = nil) {
        guard let limit = limitGB(), let free = freeBytes() else { completion?(false); return }
        let time = now()
        guard LowDiskAlert.shouldAlert(limitGB: limit, freeBytes: free, lastAlert: lastAlert(), now: time, calendar: calendar) else {
            completion?(false); return
        }
        notify(LowDiskText.title, LowDiskText.body(freeBytes: free)) { shown in
            if shown { saveAlert(time) }
            completion?(shown)
        }
    }
}
