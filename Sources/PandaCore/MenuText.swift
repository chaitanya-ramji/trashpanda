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
