import Foundation

/// One part of the bar that shows where the reclaimable data is. It is one group, or "Other".
public struct SplitSegment: Equatable, Sendable {
    /// The groups in this part. One group, or several when it is "Other".
    public let ecosystems: [Ecosystem]
    public let name: String
    /// A short name for the legend.
    public let shortName: String
    public let bytes: Int64
    /// The part of `bytes` that "Free up" takes without asking. The rest is review.
    public let safeBytes: Int64
    /// Between 0 and 1. All shares add up to 1.
    public let share: Double
    public let isOther: Bool

    public var percentText: String {
        share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }

    /// What the user reads when the mouse is over the part: "Xcode & Swift · 10 GB · 31%".
    public var hoverText: String {
        var text = "\(name) · \(ByteText.string(bytes)) · \(percentText)"
        if safeBytes > 0 && safeBytes < bytes { text += " · \(ByteText.string(safeBytes)) safe" }
        return text
    }

    /// What VoiceOver says.
    public var accessibilityLabel: String {
        let pct = share < 0.01 ? "less than 1 percent" : "\(Int((share * 100).rounded())) percent"
        return "\(name), \(ByteText.string(bytes)), \(pct) of what you can clean"
    }
}

public struct SplitSlot: Equatable, Sendable {
    public let x: CGFloat
    public let width: CGFloat
}

public enum SplitBar {
    /// Groups the findings that can be cleaned now. An item of a running app, and an information line, is not in it.
    /// The largest `maxNamed` groups are named. The rest are joined as "Other". The parts add up to the total.
    public static func segments(from findings: [Finding], isBlocked: (Finding) -> Bool = { _ in false },
                                maxNamed: Int = 5) -> [SplitSegment] {
        var bytes: [Ecosystem: Int64] = [:], safe: [Ecosystem: Int64] = [:]
        for f in findings where f.isActionable && f.bytes > 0 && !isBlocked(f) {
            bytes[f.ecosystem, default: 0] += f.bytes
            if f.tier == .safe { safe[f.ecosystem, default: 0] += f.bytes }
        }
        let total = bytes.values.reduce(0, +)
        guard total > 0 else { return [] }

        // The largest first. A tie is broken by name, so that the order does not change between scans.
        let ordered = bytes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.name < $1.key.name }
        func part(_ list: [(key: Ecosystem, value: Int64)], other: Bool) -> SplitSegment {
            let sum = list.reduce(Int64(0)) { $0 + $1.value }
            return SplitSegment(
                ecosystems: list.map(\.key),
                name: other ? "Other" : list[0].key.name,
                shortName: other ? "Other" : list[0].key.shortName,
                bytes: sum, safeBytes: list.reduce(Int64(0)) { $0 + (safe[$1.key] ?? 0) },
                share: Double(sum) / Double(total), isOther: other)
        }

        // If only one group is left over, it keeps its own name.
        let named = ordered.count - maxNamed == 1 ? ordered.count : min(maxNamed, ordered.count)
        var out = ordered.prefix(named).map { part([$0], other: false) }
        if ordered.count > named { out.append(part(Array(ordered.dropFirst(named)), other: true)) }
        return out
    }

    /// Places the parts across `width`. Each part is at least `minWidth` wide, so that it can be seen and chosen.
    /// The widths and the gaps add up to `width`.
    public static func layout(_ segments: [SplitSegment], width: CGFloat, gap: CGFloat = 1.5,
                              minWidth: CGFloat = 4) -> [SplitSlot] {
        guard !segments.isEmpty else { return [] }
        let available = max(0, width - gap * CGFloat(segments.count - 1))
        var widths = segments.map { CGFloat($0.share) * available }

        // Raise the parts that are too small, and take the same space from the large ones.
        let small = widths.indices.filter { widths[$0] < minWidth }
        let deficit = small.reduce(CGFloat(0)) { $0 + (minWidth - widths[$1]) }
        if deficit > 0 {
            let largeTotal = widths.indices.filter { !small.contains($0) }.reduce(CGFloat(0)) { $0 + widths[$1] }
            let scale = largeTotal > deficit ? (largeTotal - deficit) / largeTotal : 0
            for i in widths.indices { widths[i] = small.contains(i) ? minWidth : widths[i] * scale }
            if scale == 0 { widths = Array(repeating: available / CGFloat(segments.count), count: segments.count) }
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
