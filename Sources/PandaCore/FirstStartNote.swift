import Foundation

/// The first-start note (#198). At the first start, the app shows one dialog that says what it does and what it never
/// touches. The app then writes `first_start_note = shown` to the settings file, so the note does not come back.
///
/// If that line cannot be written, the note still shows only once in the same run. It never repeats in a loop.
/// Demo mode never shows the note.
public struct FirstStartNote {
    public static let settingName = "first_start_note"
    public static let recordedValue = "shown"

    public static let message = "Trash Panda finds build data and caches of developer tools. It removes nothing until you ask. It never touches your code, your documents, or your settings."
    public static let okTitle = "OK"
    public static let neverTouchesTitle = "What it never touches"
    /// The section of SECURITY.md that the second button opens.
    public static let neverTouchesURL = URL(string: "https://github.com/chaitanya-ramji/trashpanda/blob/main/SECURITY.md#what-it-never-touches")!

    /// True when the settings text has the line that says the note was shown.
    public static func isRecorded(settingsText: String) -> Bool {
        settingsText.split(separator: "\n").contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return false }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == settingName && parts[1] == recordedValue
        }
    }

    /// True when the settings file of `home` has the line that says the note was shown.
    public static func isRecorded(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let file = home.appendingPathComponent(".config/trashpanda/settings")
        return isRecorded(settingsText: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }

    /// Writes `first_start_note = shown` to the settings file. The other lines stay. False when the file cannot be written.
    @discardableResult
    public static func record(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        Config.writeSetting(settingName, recordedValue, home: home)
    }

    /// True once the note has been shown in this run. It is set before the dialog shows, so a failed write cannot repeat it.
    public private(set) var shownThisRun = false

    public init() {}

    /// True when the note must show now. Call it once at each start.
    /// - `isDemo`: demo mode never shows the note.
    /// - `recorded`: the settings file says the note was shown before.
    /// The answer is true at most once per run, whatever the settings file holds.
    public mutating func showNow(isDemo: Bool, recorded: Bool) -> Bool {
        guard !isDemo, !recorded, !shownThisRun else { return false }
        shownThisRun = true
        return true
    }
}
