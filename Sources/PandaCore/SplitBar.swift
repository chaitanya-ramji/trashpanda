import Foundation

/// One part of the bar that shows where the data of the menu rows is. It is one group, or "Other".
public struct SplitSegment: Equatable, Sendable {
    /// The groups in this part. One group, or several when it is "Other".
    public let ecosystems: [Ecosystem]
    public let name: String
    /// A short name for the legend.
    public let shortName: String
    /// The same number as the group row in the menu.
    public let bytes: Int64
    /// The part of `bytes` that "Free up" takes without asking. An item of an open app is not in it.
    public let safeBytes: Int64
    /// Between 0 and 1. All shares add up to 1.
    public let share: Double
    public let isOther: Bool
    /// The part of `bytes` that belongs to an open app. It can be cleaned only after the app quits.
    public var blockedBytes: Int64 = 0
    /// The open apps that block `blockedBytes`, sorted by name.
    public var blockingApps: [String] = []

    /// The part of `bytes` that you should look at first, and that can be cleaned now.
    public var reviewBytes: Int64 { max(0, bytes - blockedBytes - safeBytes) }

    /// True when every item of the part belongs to an open app. The bar draws it lighter, with stripes.
    public var isBlockedOnly: Bool { bytes > 0 && blockedBytes >= bytes }

    public var percentText: String {
        share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }

    /// "Safari", "Safari and Arc", or "the open apps".
    private var appsText: String {
        switch blockingApps.count {
        case 1: return blockingApps[0]
        case 2: return "\(blockingApps[0]) and \(blockingApps[1])"
        default: return "the open apps"
        }
    }

    /// "quit Safari to clean", or "quit Claude to clean 100 MB" when only some of the part is blocked.
    private var blockedText: String? {
        guard blockedBytes > 0 else { return nil }
        return isBlockedOnly ? "quit \(appsText) to clean" : "quit \(appsText) to clean \(ByteText.string(blockedBytes))"
    }

    /// What the user reads when the mouse is over the part: "Xcode & Swift · 10 GB · 31%".
    public var hoverText: String { hoverText(shortName: false) }

    /// The hover text. With `shortName`, it uses the short name, for a narrow menu.
    public func hoverText(shortName short: Bool) -> String {
        var text = "\(short ? shortName : name) · \(ByteText.string(bytes)) · \(percentText)"
        if safeBytes > 0 && safeBytes < bytes { text += " · \(ByteText.string(safeBytes)) safe" }
        // The pale share of the bar: say what it is.
        if reviewBytes > 0 { text += reviewBytes == bytes ? " · look through first" : " · \(ByteText.string(reviewBytes)) to look through" }
        if let blocked = blockedText { text += " · \(blocked)" }
        return text
    }

    /// What VoiceOver says.
    public var accessibilityLabel: String {
        let pct = share < 0.01 ? "less than 1 percent" : "\(Int((share * 100).rounded())) percent"
        var text = "\(name), \(ByteText.string(bytes)), \(pct) of what you can clean"
        if reviewBytes > 0 { text += reviewBytes == bytes ? ", look through first" : ", \(ByteText.string(reviewBytes)) to look through" }
        if let blocked = blockedText { text += ", \(blocked)" }
        return text
    }
}

public struct SplitSlot: Equatable, Sendable {
    public let x: CGFloat
    public let width: CGFloat
}

/// The totals of the line under the title of the menu. Together they are the whole bar.
public struct SplitTotals: Equatable, Sendable {
    /// Safe items that "Free up" takes now.
    public let free: Int64
    /// Items that the user must look at first, and that can be cleaned now.
    public let review: Int64
    /// Items of open apps. They can be cleaned only after the app quits.
    public let waiting: Int64

    public init(free: Int64, review: Int64, waiting: Int64) {
        self.free = free
        self.review = review
        self.waiting = waiting
    }

    public var all: Int64 { free + review + waiting }

    /// "You can free 1.5 GB now · 1.4 GB to look through · 491 MB when apps quit".
    /// With `compact`, the words are shorter, for a narrow menu.
    public func summary(compact: Bool = false) -> String {
        guard all > 0 else { return "All tidy. Nothing to clean." }
        var parts: [String] = []
        if free > 0 { parts.append(compact ? "Free \(ByteText.string(free)) now" : "You can free \(ByteText.string(free)) now") }
        if review > 0 { parts.append(compact ? "\(ByteText.string(review)) to review" : "\(ByteText.string(review)) to look through") }
        if waiting > 0 { parts.append(compact ? "\(ByteText.string(waiting)) in open apps" : "\(ByteText.string(waiting)) when apps quit") }
        return parts.joined(separator: " · ")
    }
}

public enum SplitBar {
    /// The size that a group row of the menu shows: all the items that have an action.
    /// An item of an open app is in it. An information line is not. Zero means that the row says "info".
    public static func rowBytes(_ items: [Finding]) -> Int64 {
        items.filter(\.isActionable).reduce(Int64(0)) { $0 + $1.countedBytes }
    }

    /// The totals of the line under the title.
    /// An item of an open app cannot be freed now, so it is not in "free" or "review". It is in "waiting".
    /// So the three totals add up to the bar, and to the sum of the group rows. No item is lost.
    public static func totals(from findings: [Finding], blockers: (Finding) -> [String] = { _ in [] }) -> SplitTotals {
        var free: Int64 = 0, review: Int64 = 0, waiting: Int64 = 0
        for f in findings where f.isActionable {
            if !blockers(f).isEmpty { waiting += f.countedBytes } else if f.tier == .safe { free += f.countedBytes } else { review += f.countedBytes }
        }
        return SplitTotals(free: free, review: review, waiting: waiting)
    }

    /// Splits the group rows into the ones that stay in the main list and the small ones that go into "Smaller groups".
    /// A row stays in `main` when it is one of the largest `limit` rows, and it has at least `minimumBytes` or at least
    /// 1 percent of the total. Both lists are sorted from the largest. A tie is broken by name.
    public static func fold(_ rows: [(Ecosystem, Int64)], limit: Int = 8, minimumBytes: Int64 = 100_000_000)
        -> (main: [(Ecosystem, Int64)], folded: [(Ecosystem, Int64)]) {
        let ordered = rows.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
        let total = ordered.reduce(Int64(0)) { $0 + $1.1 }
        var main: [(Ecosystem, Int64)] = [], folded: [(Ecosystem, Int64)] = []
        for (rank, row) in ordered.enumerated() {
            let big = row.1 >= minimumBytes || (total > 0 && Double(row.1) / Double(total) >= 0.01)
            if rank < limit && big { main.append(row) } else { folded.append(row) }
        }
        return (main, folded)
    }

    /// The color slot of each group in one bar, in the order of `groups`. A group first wants the slot of its place in
    /// `Ecosystem.allCases`, modulo `slots`, so it keeps its color when the other groups change. When two groups want
    /// the same slot, the larger one keeps it and the smaller one takes the next free slot. The order of `groups` does
    /// not change any slot. With more groups than slots, the slots repeat.
    public static func colorSlots(for groups: [(ecosystem: Ecosystem, bytes: Int64)], slots: Int = 8) -> [Int] {
        guard slots > 0 else { return groups.map { _ in 0 } }
        let order = Ecosystem.allCases
        func wanted(_ e: Ecosystem) -> Int { (order.firstIndex(of: e) ?? 0) % slots }
        var result = Array(repeating: 0, count: groups.count)
        var taken = Set<Int>()
        let ranked = groups.indices.sorted {
            let a = groups[$0], b = groups[$1]
            return a.bytes != b.bytes ? a.bytes > b.bytes : a.ecosystem.name < b.ecosystem.name
        }
        // First, each slot goes to the largest group that wants it. A group that nobody beats keeps its own slot.
        // (If the smaller groups took a free slot at once, they could take the slot of a group that comes later,
        // and that group would change color for no reason.)
        var losers: [Int] = []
        for i in ranked {
            let slot = wanted(groups[i].ecosystem)
            if taken.contains(slot) { losers.append(i) } else {
                taken.insert(slot)
                result[i] = slot
            }
        }
        // Then, the others take the next free slot after the one they wanted, the larger ones first.
        for i in losers {
            var slot = wanted(groups[i].ecosystem)
            if taken.count < slots { while taken.contains(slot) { slot = (slot + 1) % slots } }
            taken.insert(slot)
            result[i] = slot
        }
        return result
    }

    /// The slots for the named parts of a bar. "Other" has no slot: it is grey.
    public static func colorSlots(for segments: [SplitSegment], slots: Int = 8) -> [Int?] {
        let named = segments.filter { !$0.isOther }.map { (ecosystem: $0.ecosystems[0], bytes: $0.bytes) }
        var next = colorSlots(for: named, slots: slots).makeIterator()
        return segments.map { $0.isOther ? nil : next.next() }
    }

    /// One part for each group row that shows a size. The size of a part is the number on its row.
    /// An item of an open app is in its part, and `blockers` gives the names of the apps that block it.
    /// A row that only says "info" has no part.
    /// The groups that `fold` keeps in the main list are named. The rest are joined as "Other", the same groups as the
    /// "Smaller groups" row. The parts add up to the total.
    public static func segments(from findings: [Finding], blockers: (Finding) -> [String] = { _ in [] },
                                limit: Int = 8, minimumBytes: Int64 = 100_000_000) -> [SplitSegment] {
        var bytes: [Ecosystem: Int64] = [:], safe: [Ecosystem: Int64] = [:], blocked: [Ecosystem: Int64] = [:]
        var apps: [Ecosystem: Set<String>] = [:]
        for f in findings where f.isActionable && f.countedBytes > 0 {
            bytes[f.ecosystem, default: 0] += f.countedBytes
            let open = blockers(f)
            if !open.isEmpty {
                blocked[f.ecosystem, default: 0] += f.countedBytes
                apps[f.ecosystem, default: []].formUnion(open)
            } else if f.tier == .safe {
                safe[f.ecosystem, default: 0] += f.countedBytes
            }
        }
        let total = bytes.values.reduce(0, +)
        guard total > 0 else { return [] }

        let (main, folded) = fold(bytes.map { ($0.key, $0.value) }, limit: limit, minimumBytes: minimumBytes)
        let ordered = main.map { (key: $0.0, value: $0.1) }
        let rest = folded.map { (key: $0.0, value: $0.1) }
        func part(_ list: [(key: Ecosystem, value: Int64)], other: Bool) -> SplitSegment {
            let sum = list.reduce(Int64(0)) { $0 + $1.value }
            return SplitSegment(
                ecosystems: list.map(\.key),
                name: other ? "Other" : list[0].key.name,
                shortName: other ? "Other" : list[0].key.shortName,
                bytes: sum, safeBytes: list.reduce(Int64(0)) { $0 + (safe[$1.key] ?? 0) },
                share: Double(sum) / Double(total), isOther: other,
                blockedBytes: list.reduce(Int64(0)) { $0 + (blocked[$1.key] ?? 0) },
                blockingApps: list.reduce(into: Set<String>()) { $0.formUnion(apps[$1.key] ?? []) }.sorted())
        }

        var out = ordered.map { part([$0], other: false) }
        if !rest.isEmpty { out.append(part(rest, other: true)) }
        return out
    }

    /// Places the parts across `width`. Each part is at least `minWidth` wide, so that it can be seen and chosen.
    /// The widths and the gaps add up to `width`.
    public static func layout(_ segments: [SplitSegment], width: CGFloat, gap: CGFloat = 1.5,
                              minWidth: CGFloat = 4) -> [SplitSlot] {
        guard !segments.isEmpty else { return [] }
        let available = max(0, width - gap * CGFloat(segments.count - 1))
        let count = CGFloat(segments.count)
        var widths = segments.map { CGFloat($0.share) * available }
        if available < minWidth * count {
            // There is no room for the minimum: all parts get the same width.
            widths = Array(repeating: available / count, count: segments.count)
        } else {
            // Parts that are too small get the minimum. The others share what is left, in the ratio of their shares.
            // Taking space from them can make another part too small, so this repeats until no part is.
            var fixed = Set<Int>()
            while true {
                let free = segments.indices.filter { !fixed.contains($0) }
                let freeShare = free.reduce(0.0) { $0 + segments[$1].share }
                let room = available - minWidth * CGFloat(fixed.count)
                guard freeShare > 0 else { break }
                for i in segments.indices { widths[i] = fixed.contains(i) ? minWidth : CGFloat(segments[i].share / freeShare) * room }
                let thin = free.filter { widths[$0] < minWidth }
                if thin.isEmpty { break }
                fixed.formUnion(thin)
            }
        }

        var x: CGFloat = 0
        return widths.map { w in
            defer { x += w + gap }
            return SplitSlot(x: x, width: w)
        }
    }

    /// The part under a point. A point a little outside a part still counts, so that thin parts can be chosen.
    public static func hit(_ slots: [SplitSlot], x: CGFloat, tolerance: CGFloat = 2) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, s) in slots.enumerated() {
            let distance = x < s.x ? s.x - x : (x > s.x + s.width ? x - (s.x + s.width) : 0)
            if distance <= tolerance, best == nil || distance < best!.distance { best = (i, distance) }
        }
        return best?.index
    }
}
