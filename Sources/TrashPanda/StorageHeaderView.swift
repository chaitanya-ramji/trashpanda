import AppKit
import PandaCore

enum Format {
    /// Decimal units, like Finder. The words come from the core, where the dialogs and the bar use them too.
    static func bytes(_ value: Int64) -> String { ByteText.string(value) }
}

/// The colors of the groups. The bar and the group rows of the menu use the same slots.
enum GroupColors {
    /// The palette has no yellow. The disk bar uses it for "review". Orange and brown are far from it.
    static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemGreen, .systemPink, .systemTeal, .systemIndigo,
                                     .systemOrange, .systemBrown]
    static let dotSize: CGFloat = 8

    static func color(slot: Int) -> NSColor { palette[((slot % palette.count) + palette.count) % palette.count] }

    /// A round dot for a menu row, in a square of `side` points so that it lines up with the other icons.
    static func dot(slot: Int, side: CGFloat = 16) -> NSImage {
        let color = color(slot: slot)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let d = dotSize
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)).fill()
            return true
        }
        image.accessibilityDescription = nil
        return image
    }
}

/// One part of the split bar, for VoiceOver. It can be pressed like a button.
final class SegmentElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The top of the menu: free space, what you can free, and one bar that shows where the reclaimable data is. A spinner shows when the app is busy.
final class StorageHeaderView: NSView {
    private var disk = DiskUsage(total: 0, free: 0)
    private var totals = SplitTotals(free: 0, review: 0, waiting: 0)
    private var activity = MenuModel.Activity.scanning
    private var segments: [SplitSegment] = []
    private var slots: [SplitSlot] = []
    /// The color slot of each part. "Other" has none.
    private var colorSlots: [Int?] = []
    private var hovered: Int?
    private var elements: [SegmentElement] = []
    private let spinner = NSProgressIndicator()

    /// Called when the user clicks a part of the split bar.
    var onSelect: ((SplitSegment) -> Void)?

    // MARK: Layout

    private static let width: CGFloat = 300
    private static let inset: CGFloat = 16
    /// The chevrons of the rows below end about 20 points from the right edge of the menu. The bar ends there too.
    private static let rightInset: CGFloat = 20
    private static let plainHeight: CGFloat = 54
    private static let splitHeight: CGFloat = 96
    private static let splitBarHeight: CGFloat = 14

    /// The menu is wider than the first size of this view, so the bar follows the real width.
    private var barWidth: CGFloat { max(40, bounds.width - Self.inset - Self.rightInset) }

    var preferredHeight: CGFloat { segments.isEmpty ? Self.plainHeight : Self.splitHeight }

    private var splitBarRect: NSRect {
        NSRect(x: Self.inset, y: bounds.height - 68, width: barWidth, height: Self.splitBarHeight)
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.plainHeight))
        autoresizingMask = [.width]
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(disk: DiskUsage, totals: SplitTotals, activity: MenuModel.Activity, segments: [SplitSegment]) {
        self.disk = disk
        self.totals = totals
        self.activity = activity
        self.segments = segments
        self.colorSlots = SplitBar.colorSlots(for: segments)
        self.hovered = nil
        setFrameSize(NSSize(width: max(bounds.width, Self.width), height: preferredHeight))
        relayout()
        if activity == .idle { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }

    /// Called when the width changes: the bar, the hit areas, and the spinner follow the menu width.
    private func relayout() {
        slots = SplitBar.layout(segments, width: barWidth)
        spinner.frame = NSRect(x: bounds.width - Self.rightInset - 16, y: bounds.height - 30, width: 16, height: 16)
        rebuildAccessibility()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { relayout() }
    }

    // MARK: Words

    private static let detailFont = NSFont.systemFont(ofSize: 11)

    /// The line under the title. When the long words do not fit the menu, it uses the short words.
    private var detail: String {
        let room = bounds.width - Self.inset - Self.rightInset
        func fit(_ long: String, _ short: String) -> String {
            long.size(withAttributes: [.font: Self.detailFont]).width <= room ? long : short
        }
        if let i = hovered, segments.indices.contains(i) {
            return fit(segments[i].hoverText, segments[i].hoverText(shortName: true))
        }
        switch activity {
        case .scanning: return "Scanning for things to clean…"
        case .cleaning: return "Cleaning up…"
        case .idle: return fit(totals.summary(), totals.summary(compact: true))
        }
    }

    private func color(_ index: Int) -> NSColor {
        guard segments.indices.contains(index) else { return .clear }
        // "Other" is a neutral grey that works in light and dark mode.
        guard colorSlots.indices.contains(index), let slot = colorSlots[index] else { return NSColor.systemGray }
        return GroupColors.color(slot: slot)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// The part under a point in this view, or nil. The point must be on the bar, with a little room above and below.
    private func segment(at point: NSPoint) -> Int? {
        let bar = splitBarRect.insetBy(dx: 0, dy: -5)
        guard !slots.isEmpty, bar.contains(NSPoint(x: bar.midX, y: point.y)) else { return nil }
        return SplitBar.hit(slots, x: point.x - Self.inset)
    }

    func setHovered(_ index: Int?) {
        guard hovered != index else { return }
        hovered = index
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { setHovered(segment(at: convert(event.locationInWindow, from: nil))) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if let i = segment(at: convert(event.locationInWindow, from: nil)) { choose(i) }
    }

    func choose(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        onSelect?(segments[index])
    }

    // MARK: VoiceOver

    private func rebuildAccessibility() {
        elements = segments.enumerated().map { i, s in
            let e = SegmentElement()
            e.setAccessibilityRole(.button)
            e.setAccessibilityLabel(s.accessibilityLabel)
            e.setAccessibilityParent(self)
            let slot = slots[i]
            e.setAccessibilityFrameInParentSpace(NSRect(x: Self.inset + slot.x, y: splitBarRect.minY, width: slot.width,
                                                        height: Self.splitBarHeight))
            e.onPress = { [weak self] in self?.choose(i) }
            return e
        }
    }

    override func accessibilityChildren() -> [Any]? { elements }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        "\(Format.bytes(disk.free)) free of \(Format.bytes(disk.total)). \(detail)"
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let inset = Self.inset
        "\(Format.bytes(disk.free)) free of \(Format.bytes(disk.total))"
            .draw(at: NSPoint(x: inset, y: bounds.height - 28), withAttributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        detail.draw(at: NSPoint(x: inset, y: bounds.height - 46), withAttributes: [
            .font: Self.detailFont,
            .foregroundColor: hovered == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])

        drawSplitBar()
        drawLegend()
    }

    /// The second bar. Its whole width is the data of the group rows below it, split by group.
    /// The data of an open app is drawn lighter, with stripes, at the end of its part. The hover text says why.
    private func drawSplitBar() {
        guard !segments.isEmpty else { return }
        let bar = splitBarRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).addClip()
        for (i, slot) in slots.enumerated() {
            let s = segments[i]
            let alpha: CGFloat = hovered != nil && hovered != i ? 0.30 : 1
            let rect = NSRect(x: bar.minX + slot.x, y: bar.minY, width: slot.width, height: bar.height)
            let blockedShare = s.bytes > 0 ? CGFloat(min(s.blockedBytes, s.bytes)) / CGFloat(s.bytes) : 0
            let blockedWidth = (rect.width * blockedShare).rounded()
            let (open, solid) = rect.divided(atDistance: blockedWidth, from: .maxXEdge)
            color(i).withAlphaComponent(alpha).setFill()
            solid.fill()
            if blockedWidth > 0 { drawStripes(in: open, color: color(i), alpha: alpha) }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A light fill with diagonal stripes. It marks data that waits for an app to quit.
    private func drawStripes(in rect: NSRect, color: NSColor, alpha: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        color.withAlphaComponent(0.30 * alpha).setFill()
        rect.fill()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: NSPoint(x: x, y: rect.minY))
            path.line(to: NSPoint(x: x + rect.height, y: rect.maxY))
            x += 4
        }
        color.withAlphaComponent(0.85 * alpha).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The three largest groups, with a dot of the color of each part. The color is never the only clue.
    /// A group that does not fit is left out, and the "more" count tells how many parts are not named.
    private func drawLegend() {
        guard !segments.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 10)
        var x = Self.inset
        let y: CGFloat = 10
        var shown = 0
        for (i, s) in segments.prefix(3).enumerated() {
            let text = "\(s.shortName) \(Format.bytes(s.bytes))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: hovered == i ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let size = text.size(withAttributes: attributes)
            let dotSize = GroupColors.dotSize
            guard x + dotSize + 5 + size.width <= bounds.width - Self.rightInset else { break }
            // A part that waits for an app to quit has a ring, not a dot, like its light part in the bar.
            let dot = NSBezierPath(ovalIn: NSRect(x: x + 0.5, y: y + 2, width: dotSize, height: dotSize))
            if s.isBlockedOnly {
                color(i).setStroke()
                dot.lineWidth = 1
                dot.stroke()
            } else {
                color(i).setFill()
                dot.fill()
            }
            text.draw(at: NSPoint(x: x + dotSize + 5, y: y), withAttributes: attributes)
            x += dotSize + 5 + size.width + 8
            shown += 1
        }
        let left = segments.count - shown
        if left > 0 {
            let more = "+\(left) more"
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            if x + more.size(withAttributes: attributes).width <= bounds.width - Self.rightInset {
                more.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            }
        }
    }
}
