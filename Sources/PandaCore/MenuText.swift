import Foundation

/// Small texts of the menu and of the menu bar item, built here so that tests can check each case.
public enum MenuText {
    /// The Settings row for the delete mode. Checked means trash mode.
    public static let trashModeTitle = "Move files to the Trash"
    public static let trashModeTooltip =
        "On: files go to the Trash, and the space is free when you empty the Trash. Off: files are deleted for good. Items that a tool removes (Docker, Homebrew) are always removed by the tool."

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
    public static func primary(safeCount: Int, safeBytes: Int64, reviewBytes: Int64, deleteMode: DeleteMode = .permanent) -> Primary {
        guard safeCount > 0 else {
            let title = reviewBytes > 0 ? "Nothing to clean now · \(ByteText.string(reviewBytes)) to review" : "Nothing to clean now"
            return Primary(title: title, subtitle: nil, enabled: false)
        }
        let items = safeCount == 1 ? "1 safe item." : "\(safeCount) safe items."
        return Primary(title: DeleteModeText.bulkRow(ByteText.string(safeBytes), mode: deleteMode),
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
    /// When the short name could mislead, the original name stays: a long name, a part that says nothing,
    /// a part that is a number or an id, or a part that is a common word.
    public static func friendlyName(_ name: String) -> String {
        guard let parts = domainParts(name), parts.count <= 4 else { return name }
        guard let meaningful = parts.dropFirst(2).last(where: { !emptyParts.contains($0.lowercased()) }) else { return name }
        let letters = meaningful.filter(\.isLetter).count, digits = meaningful.filter(\.isNumber).count
        guard meaningful.count >= 3, letters > digits, !genericParts.contains(meaningful.lowercased()) else { return name }
        return parts[1] == "apple" ? "\(meaningful) (macOS)" : meaningful
    }

    /// Common words. A name that ends with one of them says nothing about its owner.
    private static let genericParts: Set<String> = ["client", "chat", "app", "desktop", "mac", "main", "agent", "helper", "service",
                                                    "services", "networking", "daemon", "xpc", "cache", "caches", "web", "core",
                                                    "common", "mobile", "macos", "osx", "electron", "browser", "ui", "shared", "default"]

    /// The title of an item as a row shows it. The first part (before " · ") gets a friendly name. In the cache folders list the
    /// kind ("system cache", "cache folder") and "(macOS)" are dropped, because the section header says it.
    /// A Docker title is short: "Running · web + 1 volume". The full title stays in the tooltip.
    public static func rowTitle(_ title: String, ecosystem: Ecosystem) -> String {
        if title.hasPrefix("Unused anonymous volume · ") { return "Unused anonymous volume" }
        if ecosystem == .docker { return dockerTitle(title) }
        var parts = title.components(separatedBy: " · ")
        let friendly = friendlyName(parts[0])
        if ecosystem == .cacheExplorer, parts.count == 2, ["system cache", "cache folder"].contains(parts[1]) {
            return friendly.hasSuffix(" (macOS)") ? String(friendly.dropLast(" (macOS)".count)) : friendly
        }
        parts[0] = friendly
        return parts.joined(separator: " · ")
    }

    /// The text for a row's second line on a system that has none (before macOS 14.4): it joins the tooltip, on top.
    public static func tooltip(withSecondLine subtitle: String?, tooltip: String?) -> String? {
        let text = [subtitle, tooltip].compactMap { $0 }.joined(separator: "\n")
        return text.isEmpty ? nil : text
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
        let own = list.map { Optional(rowLabel($0)) }
        let alone = RebuildNotes(sectionSuffix: nil, rowLabels: own)
        // A section with an item that cannot be recovered has a plain header. Each row says its own label.
        guard list.count >= 2, !list.contains(.never) else { return alone }
        let counts = Dictionary(grouping: list.filter { $0 != .never }, by: { $0 }).mapValues(\.count)
        guard let top = counts.max(by: { $0.value < $1.value }), top.value * 2 > list.count else { return alone }
        let suffix: String
        switch top.key {
        case .seconds: suffix = "back in seconds"
        case .minutes: suffix = "rebuild in minutes"
        case .download: suffix = "re-download when needed"
        case .recreate: suffix = "must be recreated"
        case .never: return alone
        }
        return RebuildNotes(sectionSuffix: suffix, rowLabels: list.map { $0 == top.key ? nil : rowLabel($0) })
    }

    /// The label on a row. The tooltip and the dialogs keep the longer `Rebuild.label`.
    private static func rowLabel(_ r: Rebuild) -> String { r == .recreate ? "Must be recreated" : r.label }

    /// The parts of the place line of a Docker item. The row shows a short second line. The tooltip has the engine first,
    /// then the image and the state, then the volumes that a person named. An id of an anonymous volume (it ends with "…") never shows:
    /// the title says "1 volume". A running container says "Stopped first"; "Up 22 hours" is in the tooltip.
    public static func dockerPlace(_ location: String) -> (tooltip: String, subtitle: String?) {
        var parts = location.components(separatedBy: " · ")
        var engine: String?
        if let first = parts.first, first.hasPrefix("Docker engine: ") {
            engine = String(first.dropFirst("Docker engine: ".count))
            parts.removeFirst()
        }
        var tip = parts.compactMap { part -> String? in
            guard part.hasPrefix("volumes: ") else { return part }
            let named = part.dropFirst("volumes: ".count).components(separatedBy: ", ").filter { !$0.hasSuffix("…") }
            return named.isEmpty ? nil : "volumes: " + named.joined(separator: ", ")
        }
        if let engine { tip.insert(engine, at: 0) }
        // "Exited (0) 3 days ago" is shown as "Exited 3 days ago". The exit code stays in the tooltip.
        let shown = parts.filter { !$0.hasPrefix("image ") && !$0.hasPrefix("volumes: ") }
            .map { $0.replacingOccurrences(of: #" \(\d+\)"#, with: "", options: .regularExpression) }
        let sub = shown.contains("will be stopped first") ? "Will be stopped first" : shown.joined(separator: " · ")
        return (tip.joined(separator: " · "), sub.isEmpty ? nil : sub.prefix(1).uppercased() + sub.dropFirst())
    }

    /// The first part of a Docker title says what it is. A row says it in one word: "Running · web + 1 volume".
    private static func dockerTitle(_ title: String) -> String {
        var t = title
        for (long, short) in [("Running container · ", "Running · "), ("Stopped container · ", "Stopped · ")] where t.hasPrefix(long) {
            t = short + t.dropFirst(long.count)
        }
        return t.replacingOccurrences(of: #" and (\d+ volumes?)$"#, with: " + $1", options: .regularExpression)
    }

    /// Cuts a row title to `maxTitle`. In a Docker title the name of a container is not cut while a shorter form fits:
    /// the part that gets the ellipsis is the long image reference, or else the name itself.
    public static func capTitle(_ title: String, ecosystem: Ecosystem) -> String {
        guard title.count > maxTitle, ecosystem == .docker, let dot = title.range(of: " · ") else { return capped(title) }
        let head = String(title[..<dot.upperBound])
        var name = String(title[dot.upperBound...])
        var tail = ""
        if let plus = name.range(of: #" \+ \d+ volumes?$"#, options: .regularExpression) {
            tail = String(name[plus.lowerBound...])
            name = String(name[..<plus.lowerBound])
        }
        let room = maxTitle - head.count - tail.count
        guard room >= 8 else { return capped(title) }
        return head + capped(name, max: room) + tail
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
