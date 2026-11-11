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
    /// Drives the spinner. It runs only while the header is in a window and the app is busy.
    private var animationTimer: Timer?

    /// Called when the user clicks a part of the split bar.
    var onSelect: ((SplitSegment) -> Void)?

    // MARK: Layout

    private static let width: CGFloat = 300
    static let inset: CGFloat = 16
    /// The chevrons of the rows below end about 20 points from the right edge of the menu. The bar ends there too.
    private static let rightInset: CGFloat = 20
    private static let splitBarHeight: CGFloat = 14

    /// The menu is wider than the first size of this view, so the bar follows the real width.
    private var barWidth: CGFloat { max(40, bounds.width - Self.inset - Self.rightInset) }

    // The fonts follow the text styles of the system. The rows of the header follow the heights of the fonts.
    private static var titleFont: NSFont { .preferredFont(forTextStyle: .headline) }
    private static var detailFont: NSFont { .preferredFont(forTextStyle: .subheadline) }
    private static var legendFont: NSFont { .preferredFont(forTextStyle: .caption1) }

    private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    private static func layout(hasBar: Bool) -> HeaderLayout {
        SplitBar.headerLayout(titleHeight: lineHeight(titleFont), detailHeight: lineHeight(detailFont),
                              legendHeight: lineHeight(legendFont), barHeight: splitBarHeight, hasBar: hasBar)
    }

    private var rows: HeaderLayout { Self.layout(hasBar: !segments.isEmpty) }
    var preferredHeight: CGFloat { rows.height }

    /// The bar. Internal, so that a test can look at the pixels inside it.
    var splitBarRect: NSRect {
        NSRect(x: Self.inset, y: rows.barY ?? 0, width: barWidth, height: Self.splitBarHeight)
    }

    /// What the system settings say now. The core decides how to draw for them.
    /// A test sets this, so that the picture does not depend on the settings of the machine.
    var settingsOverride: HeaderSettings?

    private var style: HeaderStyle {
        if let settings = settingsOverride { return HeaderStyle(settings) }
        let workspace = NSWorkspace.shared
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return HeaderStyle(HeaderSettings(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
            darkMode: dark))
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.layout(hasBar: false).height))
        autoresizingMask = [.width]
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { return nil }

    deinit {
        animationTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// The user changed "Increase contrast", "Reduce motion" or a similar setting: draw again.
    @objc private func accessibilityOptionsChanged() {
        applyActivity()
        needsDisplay = true
    }

    // MARK: Spinner

    // The spinner is drawn here, not with an NSProgressIndicator. An animating NSProgressIndicator makes the header layer-backed
    // in the middle of an open menu, and the menu then shows the header empty. Nothing in this view has a layer.

    private static let spinnerSize: CGFloat = 14
    private static let spinnerSpokes = 12

    private var showsSpinner: Bool { activity != .idle && style.showSpinner }

    /// Where the spinner is: at the right end of the title row.
    private var spinnerRect: NSRect {
        NSRect(x: bounds.width - Self.rightInset - Self.spinnerSize, y: rows.titleY + 1, width: Self.spinnerSize, height: Self.spinnerSize)
    }

    /// Starts or stops the timer. It runs only while something moves, and only while the view is in a window.
    private func applyActivity() {
        let needed = showsSpinner && window != nil
        if needed, animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.setNeedsDisplay(self.spinnerRect.insetBy(dx: -1, dy: -1))
            }
            RunLoop.main.add(timer, forMode: .common)   // keeps turning while the menu is open
            animationTimer = timer
        } else if !needed {
            animationTimer?.invalidate()
            animationTimer = nil
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyActivity()
    }

    /// Each rebuild of the menu puts this one view into a new menu item. Draw it again each time, so that a new item never shows it empty.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        needsDisplay = true
    }

    private func drawSpinner() {
        guard showsSpinner else { return }
        let step = Int(Date().timeIntervalSinceReferenceDate * 12) % Self.spinnerSpokes
        let rect = spinnerRect
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let inner = rect.width * 0.28, outer = rect.width / 2
        for spoke in 0..<Self.spinnerSpokes {
            // The newest spoke is the darkest. The others fade behind it.
            let age = (step - spoke + Self.spinnerSpokes) % Self.spinnerSpokes
            let angle = -CGFloat(spoke) * 2 * .pi / CGFloat(Self.spinnerSpokes) + .pi / 2
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            NSColor.secondaryLabelColor.withAlphaComponent(max(0.15, 1 - CGFloat(age) * 0.08)).setStroke()
            path.stroke()
        }
    }

    func update(disk: DiskUsage, totals: SplitTotals, activity: MenuModel.Activity, segments: [SplitSegment]) {
        self.disk = disk
        self.totals = totals
        self.activity = activity
        self.segments = segments
        self.colorSlots = SplitBar.colorSlots(for: segments)
        self.hovered = nil
        setFrameSize(NSSize(width: max(bounds.width, Self.width), height: preferredHeight))
        relayout()
        applyActivity()
    }

    /// Called when the width changes: the bar, the hit areas, and the spinner follow the menu width.
    private func relayout() {
        slots = SplitBar.layout(segments, width: barWidth)
        rebuildAccessibility()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { relayout() }
    }

    // MARK: Words

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

    /// The color of the review share of part `index`: paler than the safe share. Dark mode mixes in white instead of lowering the alpha.
    private func reviewColor(_ index: Int, style: HeaderStyle) -> NSColor {
        let base = color(index)
        let mixed = style.reviewWhiteMix > 0 ? (base.blended(withFraction: style.reviewWhiteMix, of: .white) ?? base) : base
        return mixed.withAlphaComponent(style.reviewFillAlpha)
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
        let layout = rows
        "\(Format.bytes(disk.free)) free of \(Format.bytes(disk.total))"
            .draw(at: NSPoint(x: inset, y: layout.titleY), withAttributes: [
                .font: Self.titleFont,
                .foregroundColor: NSColor.labelColor,
            ])
        let truncate = NSMutableParagraphStyle()
        truncate.lineBreakMode = .byTruncatingTail
        detail.draw(in: NSRect(x: inset, y: layout.detailY, width: bounds.width - inset - Self.rightInset, height: Self.lineHeight(Self.detailFont)), withAttributes: [
            .paragraphStyle: truncate,
            .font: Self.detailFont,
            .foregroundColor: hovered == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])

        drawSplitBar()
        drawLegend()
        drawSpinner()
    }

    /// The second bar. Its whole width is the data of the group rows below it, split by group.
    /// The data of an open app is drawn lighter, with stripes, at the end of its part. The hover text says why.
    private func drawSplitBar() {
        guard !segments.isEmpty else { return }
        let bar = splitBarRect
        let style = self.style
        let rounded = NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        rounded.addClip()
        for (i, slot) in slots.enumerated() {
            let s = segments[i]
            // A part that is not under the mouse gets lighter. The floor is on the final alpha of each fill,
            // so a pale part (a review share, or stripes) stays visible.
            let dimmed = style.dimOtherParts && hovered != nil && hovered != i
            let fade: (CGFloat) -> CGFloat = dimmed ? { SplitBar.dimmedAlpha($0 * SplitBar.hoverDimFactor) } : { $0 }
            let rect = NSRect(x: bar.minX + slot.x, y: bar.minY, width: slot.width, height: bar.height)
            let widths = SplitBar.partWidths(s, width: rect.width)
            // `divided` returns the slice first and the remainder second.
            let (open, rest) = rect.divided(atDistance: widths.blocked, from: .maxXEdge)
            let (review, solid) = rest.divided(atDistance: widths.review, from: .maxXEdge)
            color(i).withAlphaComponent(fade(1)).setFill()
            solid.fill()
            if widths.review > 0 {
                if style.patternForReview {
                    drawLines(in: review, index: i, fade: fade, style: style)
                } else {
                    reviewColor(i, style: style).withAlphaComponent(fade(style.reviewFillAlpha)).setFill()
                    review.fill()
                }
            }
            if widths.blocked > 0 { drawStripes(in: open, color: color(i), fade: fade, style: style) }
            // With "Increase contrast", a thin line sets two parts apart.
            if style.separatorsBetweenParts, i > 0 {
                NSColor.separatorColor.setFill()
                NSRect(x: rect.minX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
            }
        }
        // The outline is drawn inside the rounded bar, so its corners do not stick out of the round ends.
        if style.outlineHoveredPart, let i = hovered, slots.indices.contains(i) {
            let rect = NSRect(x: bar.minX + slots[i].x, y: bar.minY, width: slots[i].width, height: bar.height)
            NSColor.labelColor.setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 2
            outline.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A light fill with diagonal stripes. It marks data that waits for an app to quit.
    private func drawStripes(in rect: NSRect, color: NSColor, fade: (CGFloat) -> CGFloat, style: HeaderStyle) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        color.withAlphaComponent(fade(style.stripeFillAlpha)).setFill()
        rect.fill()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: NSPoint(x: x, y: rect.minY))
            path.line(to: NSPoint(x: x + rect.height, y: rect.maxY))
            x += 4
        }
        color.withAlphaComponent(fade(style.stripeLineAlpha)).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A light fill with horizontal lines. It marks data that you should look at first, without a change of color.
    /// The lines are not the stripes of data that waits for an app.
    private func drawLines(in rect: NSRect, index: Int, fade: (CGFloat) -> CGFloat, style: HeaderStyle) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        // The same pale fill as the review share without a pattern (white mixed in dark mode), with lines in the full color.
        reviewColor(index, style: style).withAlphaComponent(fade(style.reviewFillAlpha)).setFill()
        rect.fill()
        let path = NSBezierPath()
        path.lineWidth = 1
        var y = rect.minY + 1.5
        while y < rect.maxY {
            path.move(to: NSPoint(x: rect.minX, y: y))
            path.line(to: NSPoint(x: rect.maxX, y: y))
            y += 3
        }
        color(index).withAlphaComponent(fade(style.stripeLineAlpha)).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// What the legend shows: the text and width of each entry, how many fit, and where the last shown entry ends.
    /// Internal, so that a test can look at the pixels around the entries.
    struct LegendPlan {
        var texts: [String]
        var widths: [CGFloat]
        var shown: Int
        /// The x where the "+N more" text starts, or the end of the last entry when no part is left out.
        var endX: CGFloat
        var left: Int
        func dotRect(_ i: Int, y: CGFloat, lineHeight: CGFloat) -> NSRect {
            let x = StorageHeaderView.inset + widths[..<i].reduce(0, +)
            return NSRect(x: x + 0.5, y: y + (lineHeight - GroupColors.dotSize) / 2, width: GroupColors.dotSize, height: GroupColors.dotSize)
        }
    }

    private var moreAttributes: [NSAttributedString.Key: Any] { [.font: Self.legendFont, .foregroundColor: NSColor.tertiaryLabelColor] }

    var legendPlan: LegendPlan {
        let font = Self.legendFont
        let room = bounds.width - Self.inset - Self.rightInset
        let dotSize = GroupColors.dotSize
        let texts = segments.map { "\($0.shortName) \(Format.bytes($0.bytes))" }
        let widths = texts.map { dotSize + 5 + $0.size(withAttributes: [.font: font]).width + 8 }
        let more = moreAttributes
        let shown = SplitBar.legendCount(entryWidths: widths, separator: 8, moreWidth: { "+\($0) more".size(withAttributes: more).width }, room: room)
        return LegendPlan(texts: texts, widths: widths, shown: shown, endX: Self.inset + widths[..<shown].reduce(0, +),
                          left: segments.count - shown)
    }

    /// The square of the dot of legend entry `i`. Internal for the tests.
    func legendDotRect(_ i: Int) -> NSRect { legendPlan.dotRect(i, y: legendY, lineHeight: Self.lineHeight(Self.legendFont)) }

    /// The bottom of the legend row. Internal for the tests.
    var legendY: CGFloat { rows.legendY ?? 10 }

    /// The largest groups that fit, with a dot of the color of each part. The color is never the only clue.
    /// A group that does not fit is left out, and the "more" count tells how many parts are not named.
    private func drawLegend() {
        guard !segments.isEmpty else { return }
        let font = Self.legendFont
        let y = legendY
        let plan = legendPlan
        func attributes(_ i: Int) -> [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: hovered == i ? NSColor.labelColor : NSColor.secondaryLabelColor]
        }
        var x = Self.inset
        for i in 0..<plan.shown {
            let s = segments[i]
            // A part that waits for an app to quit has a ring, not a dot, like its light part in the bar.
            let dot = NSBezierPath(ovalIn: plan.dotRect(i, y: y, lineHeight: Self.lineHeight(font)))
            if s.isBlockedOnly {
                color(i).setStroke()
                dot.lineWidth = 1
                dot.stroke()
            } else if s.safeBytes == 0 {
                // A part with only review data is pale in the bar, so its dot is pale too, with a ring in the full color.
                reviewColor(i, style: style).setFill()
                dot.fill()
                color(i).setStroke()
                dot.lineWidth = 1
                dot.stroke()
            } else {
                color(i).setFill()
                dot.fill()
            }
            plan.texts[i].draw(at: NSPoint(x: x + GroupColors.dotSize + 5, y: y), withAttributes: attributes(i))
            x += plan.widths[i]
        }
        if plan.left > 0, x + "+\(plan.left) more".size(withAttributes: moreAttributes).width <= bounds.width - Self.rightInset {
            "+\(plan.left) more".draw(at: NSPoint(x: x, y: y), withAttributes: moreAttributes)
        }
    }
}
