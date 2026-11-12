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
        /// The folder that the dialog can show in Finder. nil: the dialog has no such button.
        public let revealURL: URL?

        public init(findings: [Finding], title: String, body: String, footer: String? = nil, confirmTitle: String? = nil,
                    cancelIsDefault: Bool = false, cancelTitle: String? = nil, revealURL: URL? = nil) {
            self.revealURL = revealURL
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
                && a.revealURL == b.revealURL
        }
    }

    /// What a row does when the user chooses it.
    public enum Action: Equatable, Sendable {
        /// Ask, then clean the items of the prompt.
        case clean(Prompt)
        /// Ask, then quit the open owner app politely, then clean the one item of the prompt.
        case quitAndClean(Prompt)
        case openUpdate, rescan, stopClean, showLog, checkForUpdates, toggleUpdateCheck, toggleLogin, toggleTrashMode, quit
        case openKeepList, openRootsList, openHelp, reportProblem, showAbout
        /// Show one item in Finder. Nothing is deleted.
        case reveal(URL)
    }

    /// The small icon of a row. The app finds the picture.
    public enum Icon: Equatable, Sendable {
        /// The icon of the owner app. When there is none, the icon of the AI agent product with that title, if any.
        case item(owner: AppOwner?, agentTitle: String?)
        /// The icon of an AI agent product. It has a symbol when the product is not in the table.
        case product(String)
        /// A dot in the color of the group in the bar of the header. `slot` is the color slot.
        case groupColor(slot: Int)
    }

    public enum Kind: Equatable, Sendable {
        case header
        case separator
        /// A label above a list of rows. A system before macOS 14 shows it as a grey row.
        case sectionHeader
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
        /// Shown only while the Option key is held. It has the same key as the row before it.
        public var isOptionAlternate: Bool

        public init(kind: Kind = .text, title: String = "", size: String? = nil, enabled: Bool = true, action: Action? = nil,
                    submenu: Submenu? = nil, tooltip: String? = nil, subtitle: String? = nil, icon: Icon? = nil, checked: Bool? = nil,
                    isOptionAlternate: Bool = false) {
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
            self.isOptionAlternate = isOptionAlternate
        }

        static let separator = Row(kind: .separator)
        static func note(_ title: String) -> Row { Row(title: title, enabled: false) }
        /// A label above a list. It cannot be chosen.
        static func section(_ title: String) -> Row { Row(kind: .sectionHeader, title: title, enabled: false) }
    }

    /// What the storage header at the top shows.
    public struct Header: Equatable, Sendable {
        public let disk: DiskUsage
        public let totals: SplitTotals
        public let activity: Activity
        public let segments: [SplitSegment]
        /// What the header shows: the bar or the skeleton, the detail text, and how strong the bar is drawn.
        public let content: HeaderContent
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

    /// The least space between a title and its size.
    public static let minTitleGap: Double = 12

    /// How much room a title has before the size column starts: the tab, minus the size and the minimum gap.
    public static func titleRoom(tab: Double, sizeWidth: Double, minGap: Double = minTitleGap) -> Double {
        max(0, tab - sizeWidth - minGap)
    }

    /// The smallest tab of the main menu. The menu is as wide as its tab plus the icon and the chevron columns.
    public static let minTab: Double = 220

    /// The tab of the main menu: as small as the widest row allows (`widestRow` is title + minimum gap + size, in points),
    /// so that the menu is not wider than its content. It never goes below `minTab`.
    public static func mainTab(widestRow: Double) -> Double {
        max(minTab, widestRow.rounded(.up))
    }

    /// The rows with a size that use the tab of the main menu: the group rows, and the groups inside "Smaller groups".
    /// A submenu with its own `widthTitles` has its own tab.
    public var sharedColumnRows: [Row] { Self.columnRows(in: rows) }

    private static func columnRows(in rows: [Row]) -> [Row] {
        rows.flatMap { row -> [Row] in
            var found = row.kind == .columns ? [row] : []
            if let sub = row.submenu, sub.widthTitles == nil { found += columnRows(in: sub.rows) }
            return found
        }
    }

    public static func make(_ input: MenuInput) -> MenuModel {
        let findings = input.findings
        let cleaning = input.cleaning, scanning = input.scanning
        let usableSafe = findings.filter { $0.isActionable && $0.tier == .safe && input.blockers($0).isEmpty }
        let safeBytes = usableSafe.reduce(Int64(0)) { $0 + $1.countedBytes }
        // The bar has one part for each group row that shows a size. An item of an open app stays in the bar.
        // The bar stays while the app cleans, so the header keeps its height. The view draws it lighter.
        let segments = SplitBar.segments(from: findings, blockers: input.blockers)
        let header = Header(disk: input.disk, totals: SplitBar.totals(from: findings, blockers: input.blockers),
                            activity: input.activity, segments: segments,
                            content: HeaderContent.make(activity: input.activity, hasResult: input.hasResult, hasParts: !segments.isEmpty,
                                                        progress: input.cleaningTitle))

        var rows: [Row] = [Row(kind: .header), .separator]
        if cleaning {
            // The progress text is in the header, under the title. The row says only what happens.
            rows.append(.note("Cleaning…"))
            rows.append(Row(title: input.stopRequested ? "Stopping after this item…" : "Stop after this item",
                            enabled: !input.stopRequested, action: .stopClean))
        } else if input.hasResult {
            if usableSafe.isEmpty && scanning {
                rows.append(.note("Scanning…"))
            } else {
                let main = MenuText.primary(safeCount: usableSafe.count, safeBytes: safeBytes, reviewBytes: header.totals.review,
                                            deleteMode: input.deleteMode)
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
            rows += goodToKnowRows(input.infoRows)
        } else {
            rows.append(.note("Scanning…"))
        }

        rows.append(.separator)
        rows.append(Row(title: scanning ? "Scanning…" : "Scan again", enabled: !scanning && !cleaning, action: .rescan,
                        subtitle: scanning ? nil : input.result.map { MenuText.lastScan($0.date, now: input.now) }))
        if let version = input.updateVersion {
            rows.append(Row(title: "Update available: \(version)…", action: .openUpdate))
        }
        rows.append(Row(title: "Settings", submenu: Submenu(rows: settingsRows(input))))
        rows.append(Row(title: "Quit Trash Panda", action: .quit))
        return MenuModel(header: header, rows: rows)
    }

    /// The rows of the Settings submenu.
    private static func settingsRows(_ input: MenuInput) -> [Row] {
        [
            Row(title: "Check for updates…", action: .checkForUpdates),
            Row(title: "Check for updates every day", action: .toggleUpdateCheck, checked: input.updateCheckEnabled),
            Row(title: "Open at login", action: .toggleLogin, checked: input.loginEnabled),
            Row(title: MenuText.trashModeTitle, action: .toggleTrashMode, tooltip: MenuText.trashModeTooltip,
                checked: input.deleteMode == .trash),
            .separator,
            Row(title: "Open the keep list", action: .openKeepList),
            Row(title: "Open the project folders list", action: .openRootsList),
            .separator,
            Row(title: "Show log in Finder", action: .showLog),
            Row(title: "Help", action: .openHelp),
            Row(title: "Report a problem", action: .reportProblem),
            Row(title: "About Trash Panda", action: .showAbout),
        ]
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

    /// The short section at the bottom: facts that cannot be cleaned here. At most 3 rows. Each one is off and has no action.
    private static func goodToKnowRows(_ info: [InfoRow]) -> [Row] {
        guard !info.isEmpty else { return [] }
        return [.separator, .section("Good to know · can't be cleaned here")] + info.prefix(StorageFacts.maxRows).map {
            Row(title: $0.title, enabled: false, tooltip: $0.tooltip, subtitle: $0.detail)
        }
    }

    // MARK: Groups

    private static func groupRows(_ findings: [Finding], _ input: MenuInput) -> [Row] {
        let grouped = Dictionary(grouping: findings, by: \.ecosystem)
        // The rows follow the number that each row shows, like the parts of the bar. A tie is broken by name.
        // A group with no item that can be cleaned has no row.
        let (main, folded) = SplitBar.fold(grouped.compactMap { eco, items in
            let size = SplitBar.rowBytes(items)
            return size > 0 ? (eco, size) : nil
        })
        // The same slots as the named parts of the bar, so a row and its part have one color.
        let slots = SplitBar.colorSlots(for: main.map { (ecosystem: $0.0, bytes: $0.1) })
        var rows = main.enumerated().map { i, row in
            var r = groupRow(row.0, grouped[row.0] ?? [], input)
            r.icon = .groupColor(slot: slots[i])
            return r
        }
        if !folded.isEmpty {
            // The same groups as the "Other" part of the bar.
            let sum = folded.reduce(Int64(0)) { $0 + $1.1 }
            rows.append(Row(kind: .columns, title: "Smaller groups", size: ByteText.string(sum),
                            submenu: Submenu(rows: folded.map { groupRow($0.0, grouped[$0.0] ?? [], input) })))
        }
        return rows
    }

    /// One row for a group, with its items as a submenu.
    private static func groupRow(_ ecosystem: Ecosystem, _ items: [Finding], _ input: MenuInput) -> Row {
        // An item of an open app is still an item. Its size shows here, like any other.
        let amount = SplitBar.rowBytes(items)
        return Row(kind: .columns, title: ecosystem.name, size: ByteText.string(amount),
                   submenu: submenu(for: ecosystem, items: items, input))
    }

    /// The AI agents group, split by product. One row for each product, with its own "Free up" line.
    private static func nestedAgentSubmenu(_ items: [Finding], _ input: MenuInput) -> Submenu {
        var rows: [Row] = []
        let safe = items.filter { $0.isActionable && $0.tier == .safe && input.blockers($0).isEmpty }
        if !safe.isEmpty {
            let total = safe.reduce(Int64(0)) { $0 + $1.countedBytes }
            rows.append(Row(title: DeleteModeText.bulkRow(ByteText.string(total), mode: input.deleteMode), action: .clean(Prompt(
                findings: safe, title: "Free up \(ByteText.string(total)) of AI agents files?",
                body: "Trash Panda will clear old build files and caches."))))
            rows.append(.separator)
        }
        for group in AgentMenu.groups(items) where group.bytes > 0 {
            rows.append(Row(kind: .columns, title: group.product, size: ByteText.string(group.bytes),
                            submenu: submenu(for: .aiAgents, items: group.items, input, nest: false),
                            icon: .product(group.product)))
        }
        return Submenu(rows: rows)
    }

    private static func submenu(for ecosystem: Ecosystem, items: [Finding], _ input: MenuInput, nest: Bool = true) -> Submenu {
        if nest, ecosystem == .aiAgents, AgentMenu.shouldNest(items) { return nestedAgentSubmenu(items, input) }
        var rows: [Row] = []
        let actionable = items.filter(\.isActionable)
        // The bulk "Free up" line takes only items that need no quit. It never quits an app.
        let safeAll = actionable.filter { $0.tier == .safe }.sorted { $0.bytes > $1.bytes }
        let safe = safeAll.filter { input.blockers($0).isEmpty }
        let review = actionable.filter { $0.tier == .review }.sorted { $0.bytes > $1.bytes }
        let groupBytes = SplitBar.rowBytes(items)

        if !safe.isEmpty {
            let total = safe.reduce(Int64(0)) { $0 + $1.countedBytes }
            rows.append(Row(title: DeleteModeText.bulkRow(ByteText.string(total), mode: input.deleteMode), action: .clean(Prompt(
                findings: safe, title: "Free up \(ByteText.string(total)) of \(ecosystem.name) files?",
                body: "Trash Panda will clear old build files and caches."))))
        }
        var widths: [String] = []
        func section(_ list: [Finding], _ name: String, _ first: Bool) {
            if !first { rows.append(.separator) }
            let notes = MenuText.rebuildNotes(list.map(\.rebuild))
            let title = header(name, notes)
            rows.append(.section(title))
            rows += listRows(list, input, groupBytes: groupBytes, labels: notes.rowLabels, header: title, widths: &widths)
        }
        if !safeAll.isEmpty { section(safeAll, "Safe to clean", safe.isEmpty) }
        if ecosystem == .cacheExplorer {
            // The system caches of macOS have their own section. The header says what they are, so a row does not repeat it.
            let system = review.filter { $0.title.hasSuffix(" · system cache") }
            let other = review.filter { !$0.title.hasSuffix(" · system cache") }
            if !other.isEmpty { section(other, "Review first", safeAll.isEmpty) }
            if !system.isEmpty {
                if !safeAll.isEmpty || !other.isEmpty { rows.append(.separator) }
                rows.append(.section("Apple caches · empty with care"))
                rows += listRows(system, input, groupBytes: groupBytes, labels: system.map { _ in nil },
                                 header: "Apple caches · empty with care", widths: &widths)
            }
        } else if ecosystem == .docker, case let images = review.filter({ $0.id.hasPrefix("docker.image:") }),
                  !images.isEmpty, images.allSatisfy({ $0.rebuild == .download }) {
            // Images come back by download, so they have their own section. The other items keep their own labels.
            let other = review.filter { !$0.id.hasPrefix("docker.image:") }
            if !other.isEmpty { section(other, "Review first", safeAll.isEmpty) }
            if !safeAll.isEmpty || !other.isEmpty { rows.append(.separator) }
            rows.append(.section("Images · re-download when needed"))
            rows += listRows(images, input, groupBytes: groupBytes, labels: images.map { _ in nil },
                             header: "Images · re-download when needed", widths: &widths, dropImagePrefix: true)
        } else if !review.isEmpty {
            section(review, "Review first", safeAll.isEmpty)
        }
        return Submenu(rows: rows, widthTitles: widths, alignIcons: true)
    }

    /// "Review first · re-download when needed"
    private static func header(_ name: String, _ notes: MenuText.RebuildNotes) -> String {
        notes.sectionSuffix.map { "\(name) · \($0)" } ?? name
    }

    /// The first rows of a list, and then the rest in a "N more… · size" submenu, so that no row is hidden.
    /// The first list has at most 12 rows. It stops earlier at the first row that is below 50 MB and below 1 percent of the group.
    private static func listRows(_ list: [Finding], _ input: MenuInput, groupBytes: Int64, labels: [String?],
                                 header: String, widths: inout [String], dropImagePrefix: Bool = false) -> [Row] {
        var friendly = list.map { MenuText.rowTitle($0.title, ecosystem: $0.ecosystem) }
        // In a list of images only, the section header says "Images", so a row does not repeat it.
        if dropImagePrefix { friendly = friendly.map { $0.hasPrefix("Image · ") ? String($0.dropFirst("Image · ".count)) : $0 } }
        // Two anonymous volumes would look the same. Then each one shows the start of its id.
        let anonymous = "Unused anonymous volume · "
        for indexes in Dictionary(grouping: friendly.indices, by: { friendly[$0] }).values where indexes.count > 1 {
            for i in indexes where list[i].title.hasPrefix(anonymous) {
                friendly[i] += " · " + list[i].title.dropFirst(anonymous.count).prefix(8)
            }
        }
        let titles = MenuText.distinct(titles: friendly, locations: list.map(\.location))
        // The width of the submenu comes from the titles as they are drawn, with the id or the folder that was added.
        widths += list.indices.map { MenuText.capTitle(titles[$0], ecosystem: list[$0].ecosystem) }
        func row(_ i: Int) -> [Row] { findingRows(list[i], input, title: titles[i], label: labels[i]) }
        var shown = 0
        while shown < min(12, list.count) {
            let f = list[shown]
            if f.bytes < 50_000_000 && Double(f.bytes) < Double(groupBytes) / 100 { break }
            shown += 1
        }
        var rows = (0..<shown).flatMap(row)
        if shown < list.count {
            let rest = Array(shown..<list.count)
            let size = rest.reduce(Int64(0)) { $0 + list[$1].countedBytes }
            rows.append(Row(title: "\(rest.count) more… · \(ByteText.string(size))",
                            submenu: Submenu(rows: [.section(header)] + rest.flatMap(row), alignIcons: true)))
        }
        return rows
    }

    /// The row of one item. When Finder can show it, an alternate row follows: "Show in Finder", while Option is held.
    private static func findingRows(_ f: Finding, _ input: MenuInput, title: String, label: String?) -> [Row] {
        let row = findingRow(f, input, title: title, label: label)
        guard let url = f.revealURL else { return [row] }
        return [row, Row(title: "Show in Finder", action: .reveal(url), isOptionAlternate: true)]
    }

    private static func findingRow(_ f: Finding, _ input: MenuInput, title fullTitle: String, label: String?) -> Row {
        let title = MenuText.capTitle(fullTitle, ecosystem: f.ecosystem)
        var subtitle = label
        var place = f.location
        if f.ecosystem == .docker, f.location.hasPrefix("Docker engine: ") {
            // The engine is in the tooltip. The row says what is new: its state, and that a running one is stopped first.
            // Its own rebuild label stays when it differs from the header, and "Cannot be recovered" always stays.
            let docker = MenuText.dockerPlace(f.location)
            place = docker.tooltip
            let joined = [docker.subtitle, label].compactMap { $0 }.joined(separator: " · ")
            subtitle = joined.isEmpty ? nil : joined
        }
        var row = Row(kind: .columns, title: title, size: f.sizeText, subtitle: subtitle,
                      icon: .item(owner: f.owner, agentTitle: f.ecosystem == .aiAgents ? f.title : nil))
        let open = input.blockers(f)
        let c = Confirmation.forOne(f, staleDays: input.staleDays, now: input.now)
        if open.isEmpty {
            row.action = .clean(Prompt(findings: [f], title: c.title, body: c.body, footer: c.footer,
                                       confirmTitle: c.confirmTitle, cancelIsDefault: c.cancelIsDefault,
                                       revealURL: f.revealURL))
        } else {
            // The app is open. The row looks like any other. The click asks, then quits the app politely, then cleans.
            let names = open.joined(separator: " and ")
            row.action = .quitAndClean(Prompt(
                findings: [f], title: c.title,
                body: c.body + "\n\n\(names) is open. Trash Panda will ask it to quit first. If it asks to save your work, answer it.",
                footer: c.footer, confirmTitle: DeleteModeText.quitAndClean(apps: names, bytes: f.bytes, finding: f, mode: input.deleteMode),
                cancelIsDefault: true, cancelTitle: "Not now", revealURL: f.revealURL))
        }
        // The tooltip keeps the full name and the rebuild label, even when the row shows less.
        // A system cache does not say that it comes back: its dialog warns that data that is not synced yet can be lost.
        let system = f.ecosystem == .cacheExplorer && f.title.hasSuffix(" · system cache")
        var reason = "Empty with care. Data that is not synced yet can be lost."
        if system, case .removeCacheFolderContents(let name) = f.action, let why = CacheExplorer.keepReason(name) {
            // The reason of the dialog, and the warning that the dialog also gives: never a text that sounds harmless.
            reason = why.contains("not synced") ? why : why + " Data that is not synced yet can be lost."
        }
        let rebuild = system ? reason : f.rebuild.label
        var tip = (title == f.title ? "" : "\(f.title)\n") + "\(place)\n\(rebuild)"
        // (the full title above is the original one; the dialogs use it too)
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
    /// What a clean does with files: delete for good (the default) or move to the Trash.
    public var deleteMode: DeleteMode = .permanent
    /// The text of the first row during a clean. nil: "Cleaning…".
    public var cleaningTitle: String?
    /// True after the user chose to stop. The clean ends after the item that runs.
    public var stopRequested = false

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
    public var infoRows: [InfoRow] { result?.infoRows ?? [] }
    public var hasResult: Bool { result != nil }
    public var activity: MenuModel.Activity { cleaning ? .cleaning : (scanning ? .scanning : .idle) }

    /// The programs that block this item right now. An empty list means that it can be cleaned.
    public func blockers(_ f: Finding) -> [String] {
        f.owner.map { running.running($0) } ?? []
    }
}
