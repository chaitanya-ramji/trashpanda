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
    private func render(_ findings: [Finding], blocked: Set<Ecosystem>, width: CGFloat = 372)
        -> (NSBitmapImageRep, StorageHeaderView, [SplitSegment]) {
        let segments = SplitBar.segments(from: findings, blockers: { blocked.contains($0.ecosystem) ? ["Some App"] : [] })
        let totals = SplitBar.totals(from: findings, blockers: { blocked.contains($0.ecosystem) ? ["Some App"] : [] })
        let view = StorageHeaderView(frame: .zero)
        view.update(disk: DiskUsage(total: 245_000_000_000, free: 137_000_000_000), totals: totals, activity: .idle, segments: segments)
        view.setFrameSize(NSSize(width: width, height: view.preferredHeight))
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        if let path = ProcessInfo.processInfo.environment["HEADER_PNG"], let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
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
        let (rep, view, segments) = render(ownerCase, blocked: [.aiAgents, .browsers])
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
        let (rep, view, segments) = render([finding("a", .docker, 500, .safe), finding("b", .javascript, 500, .review)], blocked: [])
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
}
