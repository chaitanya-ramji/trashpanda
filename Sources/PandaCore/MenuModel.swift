import Foundation

/// What the menu looks like, as plain values. The app turns it into an `NSMenu` and decides nothing.
/// The order of the rows, their texts, the sizes, and which rows are enabled are all decided here, so tests can check them.
public struct MenuModel: Equatable, Sendable {
    public enum Activity: Equatable, Sendable { case idle, scanning, cleaning }

    /// The words of one confirm dialog, and the items that it would clean.
    public struct Prompt: Equatable, Sendable {
        public let findings: [Finding]
        public let title: String
        public let body: String
        /// Text under the body. nil: the dialog says that tools rebuild what they need.
        public let footer: String?
        /// Text of the confirm button. nil: "Free up <size>".
        public let confirmTitle: String?
        /// When true, the first (default) button keeps the item.
        public let cancelIsDefault: Bool
        /// Text of the button that keeps things as they are, when it is first. nil: "Keep it".
        public let cancelTitle: String?

        public init(findings: [Finding], title: String, body: String, footer: String? = nil, confirmTitle: String? = nil,
                    cancelIsDefault: Bool = false, cancelTitle: String? = nil) {
            self.findings = findings
            self.title = title
            self.body = body
            self.footer = footer
            self.confirmTitle = confirmTitle
            self.cancelIsDefault = cancelIsDefault
            self.cancelTitle = cancelTitle
        }

        /// A finding has no equality of its own, so two prompts are equal when they name the same items.
        public static func == (a: Prompt, b: Prompt) -> Bool {
            a.findings.map(\.id) == b.findings.map(\.id) && a.title == b.title && a.body == b.body && a.footer == b.footer
                && a.confirmTitle == b.confirmTitle && a.cancelIsDefault == b.cancelIsDefault && a.cancelTitle == b.cancelTitle
        }
    }

    /// What a row does when the user chooses it.
    public enum Action: Equatable, Sendable {
        /// Ask, then clean the items of the prompt.
        case clean(Prompt)
        /// Ask, then quit the open owner app politely, then clean the one item of the prompt.
        case quitAndClean(Prompt)
        case openUpdate, rescan, showLog, checkForUpdates, toggleUpdateCheck, toggleLogin, quit
    }

    /// The small icon of a row. The app finds the picture.
    public enum Icon: Equatable, Sendable {
        /// The icon of the owner app. When there is none, the icon of the AI agent product with that title, if any.
        case item(owner: AppOwner?, agentTitle: String?)
        /// The icon of an AI agent product. It has a symbol when the product is not in the table.
        case product(String)
    }

    public enum Kind: Equatable, Sendable {
        case header
        case separator
        /// A plain title.
        case text
        /// A title on the left and a size on the right, in one column of sizes.
        case columns
    }

    public struct Submenu: Equatable, Sendable {
        public let rows: [Row]
        /// The titles that set the width of the size column. nil: the column of the menu around it.
        public let widthTitles: [String]?
        /// When any row has an icon, the rows without one get a blank icon, so that the texts line up.
        public let alignIcons: Bool

        public init(rows: [Row], widthTitles: [String]? = nil, alignIcons: Bool = false) {
            self.rows = rows
            self.widthTitles = widthTitles
            self.alignIcons = alignIcons
        }
    }

    public struct Row: Equatable, Sendable {
        public var kind: Kind
        public var title: String
        /// The text on the right of a `.columns` row.
        public var size: String?
        public var enabled: Bool
        public var action: Action?
        public var submenu: Submenu?
        public var tooltip: String?
        /// A second line under the title. An older system shows it as the tooltip.
        public var subtitle: String?
        public var icon: Icon?
        /// A check mark in front of the row.
        public var checked: Bool?
        public var keyEquivalent: String
        /// Shown only while the Option key is held. It has the same key as the row before it.
        public var isOptionAlternate: Bool

        public init(kind: Kind = .text, title: String = "", size: String? = nil, enabled: Bool = true, action: Action? = nil,
                    submenu: Submenu? = nil, tooltip: String? = nil, subtitle: String? = nil, icon: Icon? = nil, checked: Bool? = nil,
                    keyEquivalent: String = "", isOptionAlternate: Bool = false) {
            self.kind = kind
            self.title = title
            self.size = size
            self.enabled = enabled
            self.action = action
            self.submenu = submenu
            self.tooltip = tooltip
            self.subtitle = subtitle
            self.icon = icon
            self.checked = checked
            self.keyEquivalent = keyEquivalent
            self.isOptionAlternate = isOptionAlternate
        }

        static let separator = Row(kind: .separator)
        static func note(_ title: String) -> Row { Row(title: title, enabled: false) }
    }

    /// What the storage header at the top shows.
    public struct Header: Equatable, Sendable {
        public let disk: DiskUsage
        public let totals: SplitTotals
        public let activity: Activity
        public let segments: [SplitSegment]
    }

    public let header: Header
    /// Every row of the menu, in order. The first one is the header.
    public let rows: [Row]

    /// Where the column of sizes ends, in points, before a submenu changes it.
    public static let defaultTab: Double = 268

    /// Where the column of sizes ends in a submenu: wide enough for its longest title, within limits.
    /// `widestTitle` is the width of that title in the menu font.
    public static func tab(forWidestTitle widestTitle: Double) -> Double {
        min(520, max(defaultTab, widestTitle + 90))
    }

    public static func make(_ input: MenuInput) -> MenuModel {
        let findings = input.findings
        let cleaning = input.cleaning, scanning = input.scanning
        let usableSafe = findings.filter { $0.isActionable && $0.tier == .safe && input.blockers($0).isEmpty }
        let safeBytes = usableSafe.reduce(Int64(0)) { $0 + $1.countedBytes }
        // The bar has one part for each group row that shows a size. An item of an open app stays in the bar.
        let segments = cleaning ? [] : SplitBar.segments(from: findings, blockers: input.blockers)
        let header = Header(disk: input.disk, totals: SplitBar.totals(from: findings, blockers: input.blockers),
                            activity: input.activity, segments: segments)

        var rows: [Row] = [Row(kind: .header), .separator]
        if cleaning {
            rows.append(.note("Cleaning…"))
        } else if input.hasResult {
            if usableSafe.isEmpty && scanning {
                rows.append(.note("Scanning…"))
            } else {
                let main = MenuText.primary(safeCount: usableSafe.count, safeBytes: safeBytes, reviewBytes: header.totals.review)
                if usableSafe.isEmpty {
                    rows.append(.note(main.title))
                } else {
                    rows.append(Row(title: main.title, action: .clean(Prompt(
                        findings: usableSafe, title: "Free up \(ByteText.string(safeBytes))?",
                        body: "Trash Panda will clear old build files and caches from \(names(of: usableSafe)).")),
                        subtitle: main.subtitle))
                }
            }
            rows.append(.separator)
            rows += groupRows(findings, input)
        } else {
            rows.append(.note("Scanning…"))
        }

        rows.append(.separator)
        if let version = input.updateVersion {
            rows.append(Row(title: "Update available: \(version)…", action: .openUpdate))
        }
        rows.append(Row(title: scanning ? "Scanning…" : "Scan again", enabled: !scanning && !cleaning, action: .rescan,
                        subtitle: scanning ? nil : input.result.map { MenuText.lastScan($0.date, now: input.now) },
                        keyEquivalent: "r"))
        // Hold Option to see the log item. It is for support, so it stays out of the way.
        rows.append(Row(title: "Show log in Finder", action: .showLog, keyEquivalent: "r", isOptionAlternate: true))
        rows.append(Row(title: "Check for updates…", action: .checkForUpdates))
        rows.append(Row(title: "Check for updates every day", action: .toggleUpdateCheck, checked: input.updateCheckEnabled))
        rows.append(Row(title: "Open at login", action: .toggleLogin, checked: input.loginEnabled))
        rows.append(Row(title: "Quit Trash Panda", action: .quit, keyEquivalent: "q"))
        return MenuModel(header: header, rows: rows)
    }

    /// The menu that a click on a part of the split bar opens.
    /// One group opens its items. "Other" is several groups, and each one is a row.
    public static func popup(for segment: SplitSegment, _ input: MenuInput) -> Submenu {
        let findings = input.findings
        if let only = segment.ecosystems.first, !segment.isOther {
            return submenu(for: only, items: findings.filter { $0.ecosystem == only }, input)
        }
        return Submenu(rows: segment.ecosystems.map { eco in groupRow(eco, findings.filter { $0.ecosystem == eco }, input) })
    }

    // MARK: Groups

    private static func groupRows(_ findings: [Finding], _ input: MenuInput) -> [Row] {
        let grouped = Dictionary(grouping: findings, by: \.ecosystem)
        // The rows follow the number that each row shows, like the parts of the bar. A tie is broken by name.
        // A row that only says "info" has no number, so it goes after the rows with a size.
        let sizes = grouped.mapValues(SplitBar.rowBytes)
        let ordered = grouped.sorted { a, b in
            let x = sizes[a.key] ?? 0, y = sizes[b.key] ?? 0
            return x != y ? x > y : a.key.name < b.key.name
        }
        return ordered.map { groupRow($0.key, $0.value, input) }
    }

    /// One row for a group, with its items as a submenu.
    private static func groupRow(_ ecosystem: Ecosystem, _ items: [Finding], _ input: MenuInput) -> Row {
        // An item of an open app is still an item. Its size shows here, like any other.
        let amount = SplitBar.rowBytes(items)
        return Row(kind: .columns, title: ecosystem.name, size: amount > 0 ? ByteText.string(amount) : "info",
                   submenu: submenu(for: ecosystem, items: items, input))
    }

    /// The AI agents group, split by product. One row for each product, with its own "Free up" line.
    private static func nestedAgentSubmenu(_ items: [Finding], _ input: MenuInput) -> Submenu {
        var rows: [Row] = []
        let safe = items.filter { $0.isActionable && $0.tier == .safe && input.blockers($0).isEmpty }
        if !safe.isEmpty {
            let total = safe.reduce(Int64(0)) { $0 + $1.countedBytes }
            rows.append(Row(title: "Free up \(ByteText.string(total))…", action: .clean(Prompt(
                findings: safe, title: "Free up \(ByteText.string(total)) of AI agents files?",
                body: "Trash Panda will clear old build files and caches."))))
            rows.append(.separator)
        }
        for group in AgentMenu.groups(items) {
            rows.append(Row(kind: .columns, title: group.product, size: group.bytes > 0 ? ByteText.string(group.bytes) : "info",
                            submenu: submenu(for: .aiAgents, items: group.items, input, nest: false),
                            icon: .product(group.product)))
        }
        return Submenu(rows: rows)
    }

    private static func submenu(for ecosystem: Ecosystem, items: [Finding], _ input: MenuInput, nest: Bool = true) -> Submenu {
        if nest, ecosystem == .aiAgents, AgentMenu.shouldNest(items) { return nestedAgentSubmenu(items, input) }
        var rows: [Row] = []
        if ecosystem == .docker, let engine = items.first?.location, engine.hasPrefix("Docker engine: ") {
            rows.append(.note(engine.replacingOccurrences(of: "Docker engine: ", with: "Engine: ") + " (local)"))
            rows.append(.separator)
        }
        let actionable = items.filter(\.isActionable)
        // The bulk "Free up" line takes only items that need no quit. It never quits an app.
        let safeAll = actionable.filter { $0.tier == .safe }.sorted { $0.bytes > $1.bytes }
        let safe = safeAll.filter { input.blockers($0).isEmpty }
        let review = actionable.filter { $0.tier == .review }.sorted { $0.bytes > $1.bytes }

        if !safe.isEmpty {
            let total = safe.reduce(Int64(0)) { $0 + $1.countedBytes }
            rows.append(Row(title: "Free up \(ByteText.string(total))…", action: .clean(Prompt(
                findings: safe, title: "Free up \(ByteText.string(total)) of \(ecosystem.name) files?",
                body: "Trash Panda will clear old build files and caches."))))
        }
        if !safeAll.isEmpty {
            if !safe.isEmpty { rows.append(.separator) }
            rows += listRows(safeAll, input)
        }
        if !review.isEmpty {
            if !safeAll.isEmpty { rows.append(.separator) }
            rows.append(.note("Take a look first"))
            rows += listRows(review, input)
        }
        return Submenu(rows: rows, widthTitles: items.map(\.title), alignIcons: true)
    }

    /// The first 12 rows of a list, and then the rest in a "N more…" submenu, so that no row is hidden.
    private static func listRows(_ list: [Finding], _ input: MenuInput) -> [Row] {
        var rows = list.prefix(12).map { findingRow($0, input) }
        if list.count > 12 {
            let rest = Array(list.dropFirst(12))
            rows.append(Row(title: "\(rest.count) more…",
                            submenu: Submenu(rows: rest.map { findingRow($0, input) }, alignIcons: true)))
        }
        return rows
    }

    private static func findingRow(_ f: Finding, _ input: MenuInput) -> Row {
        var row = Row(kind: .columns, title: f.title, size: f.sizeText,
                      icon: .item(owner: f.owner, agentTitle: f.ecosystem == .aiAgents ? f.title : nil))
        let open = input.blockers(f)
        let c = Confirmation.forOne(f, staleDays: input.staleDays, now: input.now)
        if open.isEmpty {
            row.action = .clean(Prompt(findings: [f], title: c.title, body: c.body, footer: c.footer,
                                       confirmTitle: c.confirmTitle, cancelIsDefault: c.cancelIsDefault))
        } else {
            // The app is open. The row looks like any other. The click asks, then quits the app politely, then cleans.
            let names = open.joined(separator: " and ")
            row.action = .quitAndClean(Prompt(
                findings: [f], title: c.title,
                body: c.body + "\n\n\(names) is open. Trash Panda will ask it to quit first. If it asks to save your work, answer it.",
                footer: c.footer, confirmTitle: "Quit \(names) and free \(ByteText.string(f.bytes))",
                cancelIsDefault: true, cancelTitle: "Not now"))
        }
        var tip = "\(f.location)\n\(f.rebuild.label)"
        if isProject(f), let days = f.lastActivity.map({ max(0, Int(input.now.timeIntervalSince($0) / 86_400)) }) {
            tip += "\nLast worked on \(days == 0 ? "today" : "\(days) days ago")"
        }
        row.tooltip = tip
        return row
    }

    /// Only a project folder has "last worked on". A Docker image has "on this Mac for".
    private static func isProject(_ f: Finding) -> Bool {
        if case .removeArtifact = f.action { return true }
        return false
    }

    /// "JavaScript, Xcode and 2 more"
    static func names(of findings: [Finding]) -> String {
        var seen: [String] = []
        for f in findings.sorted(by: { $0.bytes > $1.bytes }) where !seen.contains(f.ecosystem.name) {
            seen.append(f.ecosystem.name)
        }
        switch seen.count {
        case 0: return "your tools"
        case 1: return seen[0]
        case 2: return "\(seen[0]) and \(seen[1])"
        default: return "\(seen[0]), \(seen[1]) and \(seen.count - 2) more"
        }
    }
}

/// What the menu needs to know to build itself.
public struct MenuInput: Sendable {
    /// nil until the first scan is done.
    public var result: ScanResult?
    public var disk: DiskUsage
    public var scanning: Bool
    public var cleaning: Bool
    /// What runs now. It decides which items are blocked.
    public var running: RunningSnapshot
    public var staleDays: Int
    public var now: Date
    /// The version of a newer release, when there is one.
    public var updateVersion: String?
    public var updateCheckEnabled: Bool
    public var loginEnabled: Bool

    public init(result: ScanResult?, disk: DiskUsage, scanning: Bool, cleaning: Bool, running: RunningSnapshot,
                staleDays: Int, now: Date = Date(), updateVersion: String? = nil,
                updateCheckEnabled: Bool = true, loginEnabled: Bool = false) {
        self.result = result
        self.disk = disk
        self.scanning = scanning
        self.cleaning = cleaning
        self.running = running
        self.staleDays = staleDays
        self.now = now
        self.updateVersion = updateVersion
        self.updateCheckEnabled = updateCheckEnabled
        self.loginEnabled = loginEnabled
    }

    public var findings: [Finding] { result?.findings ?? [] }
    public var hasResult: Bool { result != nil }
    public var activity: MenuModel.Activity { cleaning ? .cleaning : (scanning ? .scanning : .idle) }

    /// The programs that block this item right now. An empty list means that it can be cleaned.
    public func blockers(_ f: Finding) -> [String] {
        f.owner.map { running.running($0) } ?? []
    }
}
