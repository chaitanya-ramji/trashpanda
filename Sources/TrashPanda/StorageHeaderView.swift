import AppKit
import PandaCore

enum Format {
    /// Decimal units, like Finder. The words come from the core, where the dialogs and the bar use them too.
    static func bytes(_ value: Int64) -> String { ByteText.string(value) }
}

enum Activity { case idle, scanning, cleaning }

/// One part of the split bar, for VoiceOver. It can be pressed like a button.
final class SegmentElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The top of the menu: free space, what you can free, one bar for the disk, and a second bar that
/// shows where the reclaimable data is. A spinner shows when the app is busy.
final class StorageHeaderView: NSView {
    private var disk = DiskUsage(total: 0, free: 0)
    private var reclaimable: Int64 = 0
    private var reviewable: Int64 = 0
    private var activity = Activity.scanning
    private var segments: [SplitSegment] = []
    private var slots: [SplitSlot] = []
    private var hovered: Int?
    private var elements: [SegmentElement] = []
    private let spinner = NSProgressIndicator()

    /// Called when the user clicks a part of the split bar.
    var onSelect: ((SplitSegment) -> Void)?

    // MARK: Layout

    private static let width: CGFloat = 300
    private static let inset: CGFloat = 16
    private static let barWidth: CGFloat = width - inset * 2
    private static let plainHeight: CGFloat = 74
    private static let splitHeight: CGFloat = 116
    private static let splitBarHeight: CGFloat = 14

    /// The palette has no yellow and no orange. The disk bar uses those two for "review" and "safe".
    private static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemGreen, .systemPink, .systemTeal, .systemIndigo]

    var preferredHeight: CGFloat { segments.isEmpty ? Self.plainHeight : Self.splitHeight }

    private var splitBarRect: NSRect {
        NSRect(x: Self.inset, y: bounds.height - 88, width: Self.barWidth, height: Self.splitBarHeight)
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.plainHeight))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(disk: DiskUsage, reclaimable: Int64, reviewable: Int64, activity: Activity, segments: [SplitSegment]) {
        self.disk = disk
        self.reclaimable = reclaimable
        self.reviewable = reviewable
        self.activity = activity
        self.segments = segments
        self.slots = SplitBar.layout(segments, width: Self.barWidth)
        self.hovered = nil
        setFrameSize(NSSize(width: Self.width, height: preferredHeight))
        spinner.frame = NSRect(x: Self.width - 32, y: bounds.height - 30, width: 16, height: 16)
        if activity == .idle { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        rebuildAccessibility()
        needsDisplay = true
    }

    // MARK: Words

    private var detail: String {
        if let i = hovered, segments.indices.contains(i) { return segments[i].hoverText }
        switch activity {
        case .scanning: return "Scanning for things to clean…"
        case .cleaning: return "Cleaning up…"
        case .idle:
            if reclaimable == 0 && reviewable == 0 { return "All tidy. Nothing to clean." }
            if reclaimable == 0 { return "\(Format.bytes(reviewable)) to look through" }
            if reviewable == 0 { return "You can free \(Format.bytes(reclaimable)) now" }
            return "You can free \(Format.bytes(reclaimable)) now · \(Format.bytes(reviewable)) to look through"
        }
    }

    private func color(_ index: Int) -> NSColor {
        guard segments.indices.contains(index) else { return .clear }
        // "Other" is a neutral grey that works in light and dark mode.
        return segments[index].isOther ? NSColor.systemGray : Self.palette[index % Self.palette.count]
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

    private func setHovered(_ index: Int?) {
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

    private func choose(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        onSelect?(segments[index])
    }

    /// For demo mode: act as if the mouse were over, or had clicked, a part.
    func simulateHover(_ index: Int?) { setHovered(index) }
    func simulateClick(_ index: Int) { choose(index) }

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
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: hovered == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])

        drawDiskBar()
        drawSplitBar()
        drawLegend()
    }

    private func drawDiskBar() {
        guard disk.total > 0 else { return }
        let bar = NSRect(x: Self.inset, y: bounds.height - 62, width: Self.barWidth, height: 8)
        let total = Double(disk.total)
        let other = max(0, disk.used - reclaimable - reviewable)
        let parts: [(Int64, NSColor)] = [
            // Used space is clearly darker than free space, in light and dark mode.
            (other, NSColor.labelColor.withAlphaComponent(0.38)),
            (reviewable, NSColor.systemYellow),
            (reclaimable, NSColor.systemOrange),
            (disk.free, NSColor.labelColor.withAlphaComponent(0.10)),
        ]
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).addClip()
        var x = bar.minX
        for (bytes, color) in parts where bytes > 0 {
            let w = bar.width * CGFloat(Double(bytes) / total)
            color.setFill()
            NSRect(x: x, y: bar.minY, width: w, height: bar.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The second bar. Its whole width is the data that can be cleaned now, split by group.
    private func drawSplitBar() {
        guard !segments.isEmpty else { return }
        let bar = splitBarRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).addClip()
        for (i, slot) in slots.enumerated() {
            let dimmed = hovered != nil && hovered != i
            color(i).withAlphaComponent(dimmed ? 0.30 : 1).setFill()
            NSRect(x: bar.minX + slot.x, y: bar.minY, width: slot.width, height: bar.height).fill()
        }
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
            guard x + 10 + size.width <= Self.width - Self.inset else { break }
            color(i).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y + 2.5, width: 6.5, height: 6.5)).fill()
            text.draw(at: NSPoint(x: x + 10, y: y), withAttributes: attributes)
            x += 10 + size.width + 8
            shown += 1
        }
        let left = segments.count - shown
        if left > 0 {
            let more = "+\(left) more"
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            if x + more.size(withAttributes: attributes).width <= Self.width - Self.inset {
                more.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            }
        }
    }
}
