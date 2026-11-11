import Foundation

/// Small texts of the menu and of the menu bar item, built here so that tests can check each case.
public enum MenuText {
    // MARK: The menu bar item

    /// The button shows the panda and a short number such as "54 GB".
    /// VoiceOver and the tooltip need the full sentence, so that a new user knows what the number means.
    public struct StatusLabel: Equatable, Sendable {
        /// For VoiceOver, for example "Trash Panda, 54 GB free".
        public let accessibility: String
        /// For the mouse pointer, for example "Trash Panda · 54 GB free of 245 GB".
        public let tooltip: String
    }

    public static func statusLabel(free: Int64, total: Int64, activity: MenuModel.Activity) -> StatusLabel {
        let freeText = ByteText.string(free)
        let totalText = ByteText.string(total)
        switch activity {
        case .cleaning:
            return StatusLabel(accessibility: "Trash Panda, cleaning", tooltip: "Trash Panda · cleaning")
        case .scanning:
            return StatusLabel(accessibility: "Trash Panda, scanning, \(freeText) free",
                               tooltip: "Trash Panda · scanning · \(freeText) free of \(totalText)")
        case .idle:
            return StatusLabel(accessibility: "Trash Panda, \(freeText) free",
                               tooltip: "Trash Panda · \(freeText) free of \(totalText)")
        }
    }

    // MARK: The main row

    /// The main row: what it does, and what it leaves alone.
    public struct Primary: Equatable, Sendable {
        public let title: String
        /// Text under the title (or the tooltip on an older system). nil: none.
        public let subtitle: String?
        /// False when there is nothing to choose.
        public let enabled: Bool
    }

    /// `safeCount` and `safeBytes` are the items that "Free up" removes. `reviewBytes` is what stays for the user to review.
    public static func primary(safeCount: Int, safeBytes: Int64, reviewBytes: Int64) -> Primary {
        guard safeCount > 0 else {
            let title = reviewBytes > 0 ? "Nothing to clean now · \(ByteText.string(reviewBytes)) to review" : "Nothing to clean now"
            return Primary(title: title, subtitle: nil, enabled: false)
        }
        let items = safeCount == 1 ? "1 safe item." : "\(safeCount) safe items."
        return Primary(title: "Free up \(ByteText.string(safeBytes))…",
                       subtitle: reviewBytes > 0 ? items + " Review items stay." : items, enabled: true)
    }

    /// The titles of one list. When two rows have the same title, each gets the first part of its path that is different:
    /// "pnpm store · Library". `locations` has one path for each title.
    public static func distinct(titles: [String], locations: [String]) -> [String] {
        precondition(titles.count == locations.count)
        func parts(_ location: String) -> [String] {
            let path = location.components(separatedBy: " · ")[0]
            return path.split(separator: "/").map(String.init).filter { $0 != "~" }
        }
        var out = titles
        for indexes in Dictionary(grouping: titles.indices, by: { titles[$0] }).values where indexes.count > 1 {
            let paths = indexes.map { parts(locations[$0]) }
            let longest = paths.map(\.count).max() ?? 0
            guard let at = (0..<longest).first(where: { p in Set(paths.map { p < $0.count ? $0[p] : "" }).count > 1 }) else { continue }
            for (k, i) in indexes.enumerated() where at < paths[k].count { out[i] = titles[i] + " · " + paths[k][at] }
        }
        return out
    }

    /// A title that fits in `room` points: the middle becomes "…" and the start and the end stay.
    /// `measure` gives the width of a text in points. A title that fits is not changed.
    public static func middleTruncated(_ title: String, toFit room: Double, measure: (String) -> Double) -> String {
        if measure(title) <= room { return title }
        let chars = Array(title)
        func kept(_ n: Int) -> String {
            let head = (n + 1) / 2, tail = n / 2
            return String(chars.prefix(head)) + "…" + String(chars.suffix(tail))
        }
        // The widest text is the longest one that fits: look for it by halving.
        var low = 0, high = chars.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if measure(kept(mid)) <= room { low = mid } else { high = mid - 1 }
        }
        return kept(low)
    }

    // MARK: Rows of a group submenu

    /// The longest title that a row shows. A longer one gets a middle ellipsis. The tooltip has the full text.
    public static let maxTitle = 44

    /// "abcdefghij…vwxyz": the start and the end stay, the middle goes. A short text is not changed.
    public static func capped(_ text: String, max limit: Int = maxTitle) -> String {
        guard text.count > limit, limit >= 3 else { return text }
        let keep = limit - 1
        return String(text.prefix((keep + 1) / 2)) + "…" + String(text.suffix(keep / 2))
    }

    private static let domainStarts: Set<String> = ["com", "org", "net", "io", "dev", "app", "co", "me", "edu"]
    /// The last parts of a name that tell nothing about its owner.
    private static let emptyParts: Set<String> = ["helper", "cache", "caches", "shipit", "updater", "agent", "service", "services", "daemon", "xpc"]

    /// A folder name that is a reverse domain name, such as `com.example.tool`. Plain names and file names are not.
    private static func domainParts(_ name: String) -> [String]? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, domainStarts.contains(parts[0]) else { return nil }
        let ok = parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
        return ok ? parts : nil
    }

    /// A short name for a folder that is named like a reverse domain: the last part that says something.
    /// `com.apple.<x>` is a macOS name, so it gets "(macOS)". Any other name is not changed. No product name is made up.
    public static func friendlyName(_ name: String) -> String {
        guard let parts = domainParts(name) else { return name }
        let meaningful = parts.dropFirst(2).last { !emptyParts.contains($0.lowercased()) } ?? parts[parts.count - 1]
        return parts[1] == "apple" ? "\(meaningful) (macOS)" : meaningful
    }

    /// The title of an item as a row shows it. The first part (before " · ") gets a friendly name, and the id of an
    /// anonymous Docker volume is hidden. The full title stays in the tooltip.
    public static func friendlyTitle(_ title: String) -> String {
        if title.hasPrefix("Unused anonymous volume · ") { return "Unused anonymous volume" }
        let parts = title.components(separatedBy: " · ")
        let friendly = friendlyName(parts[0])
        return friendly == parts[0] ? title : ([friendly] + parts.dropFirst()).joined(separator: " · ")
    }

    /// What the rebuild labels of one section say. `sectionSuffix` goes once into the section header.
    /// `rowLabels` is the label that a row keeps for itself: nil when the header already says it.
    public struct RebuildNotes: Equatable, Sendable {
        public let sectionSuffix: String?
        public let rowLabels: [String?]
    }

    /// A label shows on a row only when it adds information. When most rows have the same label, it goes once into the header.
    /// "Cannot be recovered" is never moved: each row that has it keeps it. One row alone keeps its label.
    public static func rebuildNotes(_ list: [Rebuild]) -> RebuildNotes {
        let own = list.map { Optional($0.label) }
        let alone = RebuildNotes(sectionSuffix: nil, rowLabels: own)
        guard list.count >= 2 else { return alone }
        let counts = Dictionary(grouping: list.filter { $0 != .never }, by: { $0 }).mapValues(\.count)
        guard let top = counts.max(by: { $0.value < $1.value }), top.value * 2 > list.count else { return alone }
        let suffix: String
        switch top.key {
        case .seconds: suffix = "they come back in seconds"
        case .minutes: suffix = "they rebuild in a few minutes"
        case .download: suffix = "they download again when needed"
        case .recreate: suffix = "you would need to recreate them"
        case .never: return alone
        }
        return RebuildNotes(sectionSuffix: suffix, rowLabels: list.map { $0 == top.key ? nil : $0.label })
    }

    /// The parts of the place line of a Docker item. The engine goes into the header, so it is not repeated on a row.
    /// An image name stays in the tooltip only. A volume id never shows: the title says "1 volume".
    public static func dockerPlace(_ location: String) -> (engine: String?, tooltip: String, subtitle: String?) {
        var parts = location.components(separatedBy: " · ")
        var engine: String?
        if let first = parts.first, first.hasPrefix("Docker engine: ") {
            engine = String(first.dropFirst("Docker engine: ".count))
            parts.removeFirst()
        }
        parts.removeAll { $0.hasPrefix("volumes: ") }
        let sub = parts.filter { !$0.hasPrefix("image ") }.joined(separator: " · ")
        return (engine, parts.joined(separator: " · "), sub.isEmpty ? nil : sub)
    }

    public static let helpURL = URL(string: "https://github.com/chaitanya-ramji/trashpanda#readme")!

    /// The page for a new issue. The text holds only the two versions: no path, no log line.
    public static func reportURL(appVersion: String, osVersion: String) -> URL {
        var parts = URLComponents(string: "https://github.com/chaitanya-ramji/trashpanda/issues/new")!
        parts.queryItems = [URLQueryItem(name: "body", value: "Trash Panda: \(appVersion)\nmacOS: \(osVersion)")]
        return parts.url!
    }

    /// "Last scan: 12 minutes ago". A scan less than one minute old is "Last scan: just now".
    public static func lastScan(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Last scan: just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return "Last scan: " + formatter.localizedString(for: date, relativeTo: now)
    }
}
