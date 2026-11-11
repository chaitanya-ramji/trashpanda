import XCTest
import AppKit
import PandaCore
@testable import TrashPanda

/// The split bar is drawn, so these tests draw it into a bitmap and look at the pixels.
/// A test of the numbers alone cannot see a part that is not drawn.
final class HeaderRenderTests: XCTestCase {
    private func finding(_ id: String, _ eco: Ecosystem, _ mb: Int64, _ tier: Tier, owner: AppOwner? = nil) -> Finding {
        Finding(id: id, ecosystem: eco, title: id, location: "/x/\(id)", bytes: mb * 1_000_000, tier: tier, rebuild: .download,
                action: .removeContents(URL(fileURLWithPath: "/x/\(id)")), owner: owner)
    }

    /// Draws the header and returns the bitmap and the view.
    private func render(_ findings: [Finding], blocked: Set<Ecosystem>, width: CGFloat = 372, settings: HeaderSettings = HeaderSettings(),
                        name: String? = nil, hover: Int? = nil)
        -> (NSBitmapImageRep, StorageHeaderView, [SplitSegment]) {
        let segments = SplitBar.segments(from: findings, blockers: { blocked.contains($0.ecosystem) ? ["Some App"] : [] })
        let totals = SplitBar.totals(from: findings, blockers: { blocked.contains($0.ecosystem) ? ["Some App"] : [] })
        let view = StorageHeaderView(frame: .zero)
        // The picture must not depend on the accessibility settings or on the appearance of the machine.
        view.settingsOverride = settings
        view.appearance = NSAppearance(named: settings.darkMode ? .darkAqua : .aqua)
        view.update(disk: DiskUsage(total: 245_000_000_000, free: 137_000_000_000), totals: totals, activity: .idle, segments: segments)
        view.setFrameSize(NSSize(width: width, height: view.preferredHeight))
        view.setHovered(hover)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        RenderSupport.writePNG(rep, name: name, dark: settings.darkMode)
        return (rep, view, segments)
    }

    /// The alpha of the pixel at (x, y), where y counts from the top of the picture.
    private func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }

    /// The pixel row (from the top of the picture) through the middle of the bar.
    private func barRow(_ rep: NSBitmapImageRep, view: StorageHeaderView) -> Int {
        Int((view.bounds.height - view.splitBarRect.midY) * CGFloat(rep.pixelsWide) / view.bounds.width)
    }

    /// The numbers of the screenshot of the owner: two groups that open apps block, and three groups that wait for a look.
    private var ownerCase: [Finding] {
        [finding("a", .aiAgents, 679, .review), finding("b", .browsers, 464, .safe), finding("c", .javascript, 384, .review),
         finding("d", .cacheExplorer, 253, .review), finding("e", .docker, 161, .review)]
    }

    func testEveryPartOfTheBarIsDrawnAcrossItsWholeWidth() {
        let (rep, view, segments) = render(ownerCase, blocked: [.aiAgents, .browsers], name: "owner-light")
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        XCTAssertEqual(segments.count, 5)
        let bar = SplitBar.layout(segments, width: view.splitBarRect.width)
        let row = barRow(rep, view: view)
        for (i, slot) in bar.enumerated() {
            // Three points in each part: near the left end, the middle, and near the right end.
            for f in [0.15, 0.5, 0.85] {
                let x = Int((view.splitBarRect.minX + slot.x + slot.width * CGFloat(f)) * scale)
                XCTAssertGreaterThan(alpha(rep, x, row), 0.2, "part \(i) (\(segments[i].name)) is not drawn at \(f) of its width")
            }
        }
    }

    func testThePartsFillTheBarFromEdgeToEdge() throws {
        let (rep, view, segments) = render(ownerCase, blocked: [.aiAgents, .browsers])
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let bar = SplitBar.layout(segments, width: view.splitBarRect.width)
        let row = barRow(rep, view: view)
        let last = try XCTUnwrap(bar.last)
        // Just inside the right end of the last part there is color. Just outside the bar there is none.
        XCTAssertGreaterThan(alpha(rep, Int((view.splitBarRect.minX + last.x + last.width - 3) * scale), row), 0.2)
        XCTAssertLessThan(alpha(rep, Int((view.splitBarRect.minX + last.x + last.width + 8) * scale), row), 0.05)
    }

    func testAPartThatNothingBlocksIsSolidAndABlockedPartIsStriped() throws {
        // One free part and one blocked part of the same size. They can come in either order.
        let (rep, view, segments) = render([finding("a", .docker, 500, .safe), finding("b", .browsers, 500, .safe)], blocked: [.browsers])
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let bar = SplitBar.layout(segments, width: view.splitBarRect.width)
        let row = barRow(rep, view: view)
        let freeIndex = try XCTUnwrap(segments.firstIndex { $0.blockedBytes == 0 })
        let blockedIndex = try XCTUnwrap(segments.firstIndex { $0.blockedBytes > 0 })
        let solid = try XCTUnwrap(rep.colorAt(x: Int((view.splitBarRect.minX + bar[freeIndex].x + bar[freeIndex].width / 2) * scale), y: row))
        XCTAssertGreaterThan(solid.alphaComponent, 0.95, "a free part is a solid color")
        // Along the blocked part, the alpha changes: the stripes are lines on a light fill.
        var alphas = Set<Int>()
        let start = Int((view.splitBarRect.minX + bar[blockedIndex].x + 4) * scale), end = Int((view.splitBarRect.minX + bar[blockedIndex].x + bar[blockedIndex].width - 4) * scale)
        for x in start..<end { alphas.insert(Int(alpha(rep, x, row) * 20)) }
        XCTAssertGreaterThan(alphas.count, 1, "a blocked part has stripes")
        XCTAssertLessThan(try XCTUnwrap(alphas.min()), 14, "the fill of a blocked part is light")
    }

    func testTheReviewShareIsLighterThanTheSafeShare() throws {
        // A free part and a part that waits for a look, of the same size.
        let (rep, view, segments) = render([finding("a", .docker, 500, .safe), finding("b", .javascript, 500, .review)], blocked: [], name: "mixed-light")
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let bar = SplitBar.layout(segments, width: view.splitBarRect.width)
        let row = barRow(rep, view: view)
        let safeIndex = try XCTUnwrap(segments.firstIndex { $0.safeBytes > 0 })
        let reviewIndex = try XCTUnwrap(segments.firstIndex { $0.safeBytes == 0 })
        let safeAlpha = alpha(rep, Int((view.splitBarRect.minX + bar[safeIndex].x + bar[safeIndex].width / 2) * scale), row)
        let reviewAlpha = alpha(rep, Int((view.splitBarRect.minX + bar[reviewIndex].x + bar[reviewIndex].width / 2) * scale), row)
        XCTAssertGreaterThan(safeAlpha, 0.95, "the safe part is solid")
        XCTAssertLessThan(reviewAlpha, safeAlpha - 0.2, "the review part is lighter than the safe part")
        XCTAssertGreaterThan(reviewAlpha, 0.3, "and it can still be seen")
    }

    /// With "Increase contrast" or "Differentiate without color", the review share has a line pattern: its pixels change along the part.
    func testTheReviewShareHasALinePatternWhenTheSettingsAskForIt() throws {
        for settings in [HeaderSettings(increaseContrast: true), HeaderSettings(differentiateWithoutColor: true)] {
            let (rep, view, segments) = render([finding("a", .javascript, 500, .review)], blocked: [], settings: settings)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            let bar = SplitBar.layout(segments, width: view.splitBarRect.width)
            let x = Int((view.splitBarRect.minX + bar[0].x + bar[0].width / 2) * scale)
            let top = Int((view.bounds.height - view.splitBarRect.maxY + 2) * scale), bottom = Int((view.bounds.height - view.splitBarRect.minY - 2) * scale)
            var alphas = Set<Int>()
            for y in top..<bottom { alphas.insert(Int(alpha(rep, x, y) * 20)) }
            XCTAssertGreaterThan(alphas.count, 1, "\(settings) gives a line pattern")
        }
    }

    /// In dark mode the review share is lighter than the solid share of the SAME color, not darker.
    /// One group has both: 500 MB safe (solid) and 300 MB to look through (pale).
    func testInDarkModeTheReviewShareIsLighterThanTheSolidShareOfTheSameColor() throws {
        let (rep, view, segments) = render([finding("a", .docker, 500, .safe), finding("b", .docker, 300, .review)], blocked: [],
                                           settings: HeaderSettings(darkMode: true), name: "same-hue-dark")
        XCTAssertEqual(segments.count, 1)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let widths = SplitBar.partWidths(segments[0], width: view.splitBarRect.width)
        XCTAssertGreaterThan(widths.safe, 20)
        XCTAssertGreaterThan(widths.review, 20)
        let row = barRow(rep, view: view)
        func pixel(_ x: CGFloat) throws -> NSColor { try XCTUnwrap(rep.colorAt(x: Int((view.splitBarRect.minX + x) * scale), y: row)?.usingColorSpace(.sRGB)) }
        func brightness(_ c: NSColor) -> CGFloat { (c.redComponent + c.greenComponent + c.blueComponent) / 3 }
        let solid = try pixel(widths.safe / 2)
        let pale = try pixel(widths.safe + widths.review / 2)
        XCTAssertGreaterThan(brightness(pale), brightness(solid) + 0.15, "the review share is lighter than the solid share")
        XCTAssertGreaterThan(pale.alphaComponent, 0.95, "in dark mode the pale color is made with white, not with a lower alpha")
    }

    /// Dark mode with a line pattern: the pale fill is lighter than the solid color too, and the lines keep the full color.
    func testInDarkModeWithAPatternTheReviewFillIsLighterThanTheSolidShare() throws {
        let (rep, view, segments) = render([finding("a", .docker, 500, .safe), finding("b", .docker, 300, .review)], blocked: [],
                                           settings: HeaderSettings(increaseContrast: true, darkMode: true), name: "pattern-dark")
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let widths = SplitBar.partWidths(segments[0], width: view.splitBarRect.width)
        let row = barRow(rep, view: view)
        func brightness(_ x: CGFloat, _ y: Int) throws -> CGFloat {
            let c = try XCTUnwrap(rep.colorAt(x: Int((view.splitBarRect.minX + x) * scale), y: y)?.usingColorSpace(.sRGB))
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3
        }
        let solid = try brightness(widths.safe / 2, row)
        // The brightest pixel in a column of the pale share is the fill between two lines.
        let x = widths.safe + widths.review / 2
        let top = Int((view.bounds.height - view.splitBarRect.maxY + 2) * scale), bottom = Int((view.bounds.height - view.splitBarRect.minY - 2) * scale)
        let brightest = try (top..<bottom).map { try brightness(x, $0) }.max() ?? 0
        XCTAssertGreaterThan(brightest, solid + 0.15, "the fill between the lines is lighter than the solid color")
    }

    /// While the mouse is on one part, the pale part and the solid part that are not under it stay visible.
    func testPartsThatAreNotHoveredStayVisible() throws {
        // Part 0 is the largest (solid, safe). Another is review only. Another has blocked data (stripes).
        let findings = [finding("a", .docker, 600, .safe), finding("b", .javascript, 300, .review), finding("c", .browsers, 200, .safe)]
        for dark in [false, true] {
            let (rep, view, segments) = render(findings, blocked: [.browsers], settings: HeaderSettings(darkMode: dark),
                                               name: "hover-\(dark ? "dark" : "light")", hover: 0)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            let bar = SplitBar.layout(segments, width: view.splitBarRect.width)
            let row = barRow(rep, view: view)
            func a(_ i: Int) -> CGFloat { alpha(rep, Int((view.splitBarRect.minX + bar[i].x + bar[i].width / 2) * scale), row) }
            let review = try XCTUnwrap(segments.firstIndex { $0.safeBytes == 0 && $0.blockedBytes == 0 })
            XCTAssertGreaterThanOrEqual(a(review), 0.21, "a pale part under another hover is visible (dark \(dark))")
            XCTAssertGreaterThanOrEqual(a(0), 0.95, "the hovered part is solid")
            let blocked = try XCTUnwrap(segments.firstIndex { $0.blockedBytes > 0 })
            var most: CGFloat = 0
            let from = Int((view.splitBarRect.minX + bar[blocked].x + 2) * scale)
            let to = Int((view.splitBarRect.minX + bar[blocked].x + bar[blocked].width - 2) * scale)
            for x in from..<to { most = max(most, alpha(rep, x, row)) }
            XCTAssertGreaterThanOrEqual(most, 0.22, "the stripes of a part under another hover are visible")
        }
        // A solid part that is not hovered is clearly visible too.
        let (rep, view, segments) = render(findings, blocked: [], name: "hover-solid", hover: 1)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let bar = SplitBar.layout(segments, width: view.splitBarRect.width)
        let solid = try XCTUnwrap(segments.firstIndex { $0.safeBytes > 0 })
        XCTAssertGreaterThanOrEqual(alpha(rep, Int((view.splitBarRect.minX + bar[solid].x + bar[solid].width / 2) * scale), barRow(rep, view: view)), 0.29)
    }

    /// With "Reduce transparency" the hovered part has an outline. At the round end of the bar, nothing sticks out.
    func testTheHoverOutlineStaysInsideTheRoundedEnds() throws {
        let (rep, view, _) = render(ownerCase, blocked: [], settings: HeaderSettings(reduceTransparency: true), name: "outline-first", hover: 0)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let bar = view.splitBarRect
        // The very corner of the bar, outside the 5 point radius: nothing is drawn there.
        for (cx, cy) in [(bar.minX + 0.6, bar.maxY - 0.6), (bar.minX + 0.6, bar.minY + 0.6)] {
            XCTAssertLessThan(alpha(rep, Int(cx * scale), Int((view.bounds.height - cy) * scale)), 0.05, "the outline sticks out at the corner")
        }
        XCTAssertGreaterThan(alpha(rep, Int((bar.minX + 40) * scale), Int((view.bounds.height - bar.maxY + 0.5) * scale)), 0.5, "the outline is drawn along the top")
    }

    /// The legend ends with "+N more" when parts are not named: the pixels right of the last entry are not empty.
    func testTheLegendSaysHowManyPartsAreNotNamed() throws {
        let (rep, view, segments) = render(ownerCase, blocked: [.aiAgents, .browsers], name: "owner-legend")
        XCTAssertEqual(segments.count, 5)
        let plan = view.legendPlan
        XCTAssertGreaterThan(plan.left, 0)
        XCTAssertLessThan(plan.shown, 5)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let y = Int((view.bounds.height - view.legendY - 6) * scale)
        var found = false
        for x in Int(plan.endX * scale)..<Int((plan.endX + 40) * scale) {
            for dy in -3...3 where alpha(rep, x, y + dy) > 0.2 { found = true }
        }
        XCTAssertTrue(found, "the text +\(plan.left) more is drawn right of the last entry")
    }

    /// The dot of a part that has only review data is pale in the middle and has a full ring.
    /// The dot of a part that has only data of open apps is a ring with an empty middle.
    func testLegendDotsOfReviewOnlyAndBlockedOnlyParts() throws {
        let (rep, view, segments) = render([finding("a", .docker, 600, .safe), finding("b", .javascript, 300, .review),
                                            finding("c", .browsers, 200, .safe)], blocked: [.browsers], name: "legend-dots")
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        XCTAssertEqual(view.legendPlan.shown, 3)
        func sample(_ i: Int) -> (center: CGFloat, ring: CGFloat) {
            let r = view.legendDotRect(i)
            let y = Int((view.bounds.height - r.midY) * scale)
            let center = alpha(rep, Int(r.midX * scale), y)
            var ring: CGFloat = 0
            for dx in -2...2 { ring = max(ring, alpha(rep, Int(r.minX * scale) + dx, y)) }
            return (center, ring)
        }
        let review = try XCTUnwrap(segments.firstIndex { $0.safeBytes == 0 && $0.blockedBytes == 0 })
        let blocked = try XCTUnwrap(segments.firstIndex { $0.isBlockedOnly })
        let solid = try XCTUnwrap(segments.firstIndex { $0.safeBytes > 0 && $0.blockedBytes == 0 })
        let r = sample(review), b = sample(blocked), s = sample(solid)
        XCTAssertEqual(r.center, 0.5, accuracy: 0.12, "the middle of a review dot is pale")
        XCTAssertGreaterThan(r.ring, 0.8, "a review dot has a full ring")
        XCTAssertLessThan(b.center, 0.05, "a blocked dot is empty in the middle")
        XCTAssertGreaterThan(b.ring, 0.8, "a blocked dot has a ring")
        XCTAssertGreaterThan(s.center, 0.95, "a solid dot is full")
    }

    // MARK: Hosted in a menu

    private func ink(_ rep: NSBitmapImageRep, rows: Range<Int>) -> Int {
        var n = 0
        for y in rows { for x in 0..<rep.pixelsWide where alpha(rep, x, y) > 0.1 { n += 1 } }
        return n
    }

    private func model(scanning: Bool, cleaning: Bool) -> MenuModel {
        let disk = DiskUsage(total: 245_000_000_000, free: 137_000_000_000)
        return MenuModel.make(MenuInput(result: ScanResult(findings: ownerCase, disk: disk), disk: disk, scanning: scanning,
                                        cleaning: cleaning, running: RunningSnapshot(apps: []), staleDays: 90))
    }

    private func feed(_ view: StorageHeaderView, _ model: MenuModel) {
        view.update(disk: model.header.disk, totals: model.header.totals, activity: model.header.activity, segments: model.header.segments)
    }

    /// The owner saw the whole header empty while the app scanned. The spinner was an NSProgressIndicator. When it animated,
    /// AppKit made the header layer-backed in the middle of the open menu, and the menu showed it empty.
    /// The menu hosts the header in its own item view (`NSMenu.size` does it without a window). In every state the header must
    /// have no layer and no subview. (A bitmap render makes a layer by itself, so the layer is read before any render.)
    func testTheHeaderIsNeverLayerBackedWhileTheAppIsBusy() throws {
        let view = StorageHeaderView(frame: .zero)
        view.settingsOverride = HeaderSettings()
        let menu = NSMenu()
        let builder = MenuBuilder { _ in }
        func step(_ label: String, scanning: Bool, cleaning: Bool, rebuild: Bool) throws {
            let m = model(scanning: scanning, cleaning: cleaning)
            feed(view, m)
            if rebuild { builder.populate(menu, model: m, header: view) }
            _ = menu.size
            XCTAssertNotNil(view.superview, "\(label): the menu hosts the header")
            XCTAssertNil(view.layer, "\(label): the header has no layer")
            XCTAssertTrue(view.subviews.isEmpty, "\(label): the header has no subview")
        }
        try step("idle", scanning: false, cleaning: false, rebuild: true)
        try step("scan starts", scanning: true, cleaning: false, rebuild: true)
        try step("scan runs, menu open", scanning: true, cleaning: false, rebuild: false)
        try step("scan ends", scanning: false, cleaning: false, rebuild: false)
        try step("cleaning", scanning: false, cleaning: true, rebuild: true)
        try step("idle again", scanning: false, cleaning: false, rebuild: true)
    }

    /// What the menu item view draws, in each state: the title, and the bar and the legend below it.
    func testTheMenuItemDrawsTheHeaderInEveryState() throws {
        for (label, scanning, cleaning) in [("idle", false, false), ("scanning", true, false), ("cleaning", false, true)] {
            let view = StorageHeaderView(frame: .zero)
            view.settingsOverride = HeaderSettings()
            let menu = NSMenu()
            let m = model(scanning: scanning, cleaning: cleaning)
            feed(view, m)
            MenuBuilder { _ in }.populate(menu, model: m, header: view)
            _ = menu.size
            let host = try XCTUnwrap(view.superview)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let h = rep.pixelsHigh
            XCTAssertGreaterThan(ink(rep, rows: 0..<h / 3), 500, "\(label): the title is drawn")
            XCTAssertGreaterThan(ink(rep, rows: h / 3..<h), 2000, "\(label): the rest is drawn")
        }
    }
}
