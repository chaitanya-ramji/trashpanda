import Foundation

/// The one dialog after a clean. It says what was removed, what was left alone, and what failed.
/// The words are made here, so that tests can check them.
public enum CleanSummary {
    public enum Button: Equatable, Sendable {
        case ok
        /// Opens the log. Shown when an item failed.
        case showLog
        /// Opens the help about the Docker disk file. Shown when `dockerDiskNote` is true.
        case dockerDiskFile

        public var title: String {
            switch self {
            case .ok: return "OK"
            case .showLog: return "Show Log"
            case .dockerDiskFile: return "About the Docker Disk File"
            }
        }
    }

    /// The most reasons that the dialog lists for one group. The rest is counted.
    static let maxReasons = 3

    /// True when the user must see a dialog. When nothing was left alone and nothing failed, the text in the menu bar is enough.
    /// The Docker note is also a reason, because it explains why the free space of the Mac may not grow.
    public static func needsDialog(_ report: CleanReport, dockerDiskNote: Bool) -> Bool {
        !report.skipped.isEmpty || !report.failed.isEmpty || dockerDiskNote
    }

    public static func make(_ report: CleanReport, dockerDiskNote: Bool) -> (title: String, lines: [String], buttons: [Button]) {
        let title = report.freed > 0 ? "Freed \(ByteText.string(report.freed))" : "Nothing freed"
        var lines: [String] = []
        lines.append(report.removed == 1 ? "1 item removed." : "\(report.removed) items removed.")
        if !report.skipped.isEmpty {
            let n = report.skipped.count
            lines.append("\(n) \(n == 1 ? "item" : "items") left alone: \(reasons(report.skipped)).")
        }
        if !report.failed.isEmpty {
            let n = report.failed.count
            lines.append("\(n) \(n == 1 ? "item" : "items") failed: \(reasons(report.failed)).")
        }
        lines.append(spaceLine(report.volumeChange))

        var buttons: [Button] = [.ok]
        if !report.failed.isEmpty { buttons.append(.showLog) }
        if dockerDiskNote { buttons.append(.dockerDiskFile) }
        return (title, lines, buttons)
    }

    /// What the free space of the Mac did during the clean. It is a check, not a promise: the number can differ from the
    /// bytes that were counted, because a clone or a snapshot can keep space in use.
    static func spaceLine(_ change: Int64) -> String {
        let what: String
        if change > 0 {
            what = "The free space on your Mac grew by \(ByteText.string(change))"
        } else if change < 0 {
            what = "The free space on your Mac went down by \(ByteText.string(-change))"
        } else {
            what = "The free space on your Mac did not change"
        }
        return "\(what) during the clean. This can differ from the number above. "
            + "A clone or a snapshot can keep space in use, and other programs write files too."
    }

    /// The distinct reasons of a list like "path: reason", at most `maxReasons`, then "and 4 more".
    static func reasons(_ entries: [String]) -> String {
        var distinct: [String] = []
        for entry in entries {
            let reason = reason(of: entry)
            if !distinct.contains(reason) { distinct.append(reason) }
        }
        let shown = distinct.prefix(maxReasons).joined(separator: "; ")
        let more = distinct.count - maxReasons
        return more > 0 ? "\(shown) and \(more) more" : shown
    }

    /// The text after the first ": ", without the dot at the end. An entry without ": " is all reason.
    static func reason(of entry: String) -> String {
        var text = entry
        if let r = entry.range(of: ": ") { text = String(entry[r.upperBound...]) }
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
