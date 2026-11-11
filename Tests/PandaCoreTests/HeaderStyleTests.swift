import XCTest
@testable import PandaCore

/// The header follows the accessibility settings. The decisions and the layout are here. The drawing only reads them.
final class HeaderStyleTests: XCTestCase {
    func testDefaultSettingsKeepTheUsualLook() {
        let style = HeaderStyle(HeaderSettings())
        XCTAssertEqual(style.stripeFillAlpha, 0.30)
        XCTAssertEqual(style.stripeLineAlpha, 0.85)
        XCTAssertFalse(style.separatorsBetweenParts)
        XCTAssertFalse(style.patternForReview)
        XCTAssertTrue(style.dimOtherParts)
        XCTAssertFalse(style.outlineHoveredPart)
        XCTAssertTrue(style.showSpinner)
    }

    func testIncreaseContrastAddsLinesAndStrongerStripes() {
        let style = HeaderStyle(HeaderSettings(increaseContrast: true))
        XCTAssertTrue(style.separatorsBetweenParts)
        XCTAssertEqual(style.stripeFillAlpha, 0.6)
        XCTAssertEqual(style.stripeLineAlpha, 1)
        XCTAssertEqual(HeaderStyle(HeaderSettings(increaseContrast: true, darkMode: true)).stripeFillAlpha, 0.6)
    }

    func testDifferentiateWithoutColorUsesAPatternForReview() {
        XCTAssertTrue(HeaderStyle(HeaderSettings(differentiateWithoutColor: true)).patternForReview)
        XCTAssertFalse(HeaderStyle(HeaderSettings(increaseContrast: true)).patternForReview)
    }

    func testReduceTransparencyOutlinesTheHoveredPartInsteadOfDimmingTheOthers() {
        let style = HeaderStyle(HeaderSettings(reduceTransparency: true))
        XCTAssertFalse(style.dimOtherParts)
        XCTAssertTrue(style.outlineHoveredPart)
    }

    func testReduceMotionHidesTheSpinner() {
        XCTAssertFalse(HeaderStyle(HeaderSettings(reduceMotion: true)).showSpinner)
    }

    func testDarkModeMakesTheLightFillOfTheStripesStronger() {
        XCTAssertEqual(HeaderStyle(HeaderSettings(darkMode: true)).stripeFillAlpha, 0.40)
    }

    // MARK: Layout

    func testRowsDoNotOverlapAndTheHeightHoldsThem() {
        for scale in [CGFloat(1), 1.3, 2] {
            let title = ceil(16 * scale), detail = ceil(14 * scale), legend = ceil(12 * scale)
            let layout = SplitBar.headerLayout(titleHeight: title, detailHeight: detail, legendHeight: legend, barHeight: 14, hasBar: true)
            let barY = layout.barY ?? -1, legendY = layout.legendY ?? -1
            XCTAssertGreaterThanOrEqual(barY, legendY + legend, "The bar is above the legend")
            XCTAssertGreaterThanOrEqual(layout.detailY, barY + 14, "The detail line is above the bar")
            XCTAssertGreaterThanOrEqual(layout.titleY, layout.detailY + detail, "The title is above the detail line")
            XCTAssertGreaterThanOrEqual(layout.height, layout.titleY + title, "The view holds the title")
            XCTAssertEqual(legendY, 10)
        }
    }

    func testALargerFontGivesATallerHeader() {
        func height(_ scale: CGFloat, bar: Bool) -> CGFloat {
            SplitBar.headerLayout(titleHeight: 16 * scale, detailHeight: 14 * scale, legendHeight: 12 * scale, barHeight: 14,
                                  hasBar: bar).height
        }
        XCTAssertLessThan(height(1, bar: true), height(1.5, bar: true))
        XCTAssertLessThan(height(1, bar: false), height(1.5, bar: false))
        XCTAssertLessThan(height(1, bar: false), height(1, bar: true), "The bar needs more room")
    }

    func testWithoutABarThereIsNoBarOrLegendRow() {
        let layout = SplitBar.headerLayout(titleHeight: 16, detailHeight: 14, legendHeight: 12, barHeight: 14, hasBar: false)
        XCTAssertNil(layout.barY)
        XCTAssertNil(layout.legendY)
        XCTAssertEqual(layout.detailY, 8)
        XCTAssertEqual(layout.titleY, 8 + 14 + 2)
    }

    // MARK: Review share

    private func part(bytes: Int64, safe: Int64, blocked: Int64) -> SplitSegment {
        SplitSegment(ecosystems: [.swift], name: "Xcode", shortName: "Xcode", bytes: bytes, safeBytes: safe, share: 1, isOther: false,
                     blockedBytes: blocked, blockingApps: blocked > 0 ? ["Xcode"] : [])
    }

    func testThePartWidthsAddUpAndFollowTheBytes() {
        let w = SplitBar.partWidths(part(bytes: 1_000, safe: 500, blocked: 100), width: 200)
        XCTAssertEqual(w.blocked, 20)
        XCTAssertEqual(w.review, 80)
        XCTAssertEqual(w.safe, 100)
        XCTAssertEqual(w.safe + w.review + w.blocked, 200)
    }

    func testAPartWithOnlySafeDataHasNoReviewWidth() {
        let w = SplitBar.partWidths(part(bytes: 1_000, safe: 1_000, blocked: 0), width: 120)
        XCTAssertEqual(w, PartWidths(safe: 120, review: 0, blocked: 0))
    }

    func testABlockedOnlyPartIsAllBlocked() {
        let w = SplitBar.partWidths(part(bytes: 1_000, safe: 0, blocked: 1_000), width: 50)
        XCTAssertEqual(w, PartWidths(safe: 0, review: 0, blocked: 50))
    }

    func testPartWidthsNeverGoBelowZero() {
        for (bytes, safe, blocked, width) in [(Int64(10), Int64(10), Int64(10), CGFloat(3)), (0, 0, 0, 5), (7, 0, 0, 0.4)] {
            let w = SplitBar.partWidths(part(bytes: bytes, safe: safe, blocked: blocked), width: width)
            XCTAssertGreaterThanOrEqual(min(w.safe, w.review, w.blocked), 0)
            XCTAssertEqual(w.safe + w.review + w.blocked, width, accuracy: 1e-9)
        }
    }

    func testFractionalWidthsNeverMakeASliverOrANegativeShare() {
        // Slot widths are fractional. A blocked part must be all blocked, and no share may be wider than the part.
        for width in stride(from: CGFloat(100), through: 130, by: 0.3) {
            let blocked = SplitBar.partWidths(part(bytes: 1_000, safe: 0, blocked: 1_000), width: width)
            XCTAssertEqual(blocked, PartWidths(safe: 0, review: 0, blocked: width))
            let review = SplitBar.partWidths(part(bytes: 1_000, safe: 0, blocked: 0), width: width)
            XCTAssertEqual(review.review, width, accuracy: 1e-9)
            XCTAssertEqual(review.safe, 0, accuracy: 1e-9)
            let mixed = SplitBar.partWidths(part(bytes: 1_000, safe: 300, blocked: 200), width: width)
            XCTAssertGreaterThanOrEqual(min(mixed.safe, mixed.review, mixed.blocked), 0)
            XCTAssertEqual(mixed.safe + mixed.review + mixed.blocked, width, accuracy: 1e-9)
        }
    }

    func testTheReviewShareIsLighterThanTheSafeShareInEveryStyle() {
        for settings in [HeaderSettings(), HeaderSettings(increaseContrast: true), HeaderSettings(darkMode: true)] {
            let style = HeaderStyle(settings)
            XCTAssertLessThan(style.reviewFillAlpha, 1)
            XCTAssertGreaterThan(style.reviewFillAlpha, 0.3, "still easy to see")
        }
    }

    func testTheLegendAlwaysSaysHowManyPartsAreNotNamed() {
        let more: (Int) -> CGFloat = { _ in 40 }
        // Five entries of 100 points, room for 360: three entries (300) plus "+2 more" (40) fit, four (400) do not.
        XCTAssertEqual(SplitBar.legendCount(entryWidths: Array(repeating: 100, count: 5), moreWidth: more, room: 360), 3)
        // Everything fits: no "+k more" is needed.
        XCTAssertEqual(SplitBar.legendCount(entryWidths: [100, 100], moreWidth: more, room: 200), 2)
        // Three entries of 100 in 330 points: all three (300) fit, so all are named.
        XCTAssertEqual(SplitBar.legendCount(entryWidths: [100, 100, 100], moreWidth: more, room: 330), 3)
        // Three entries in 250 points: two (200) and "+1 more" (40) fit.
        XCTAssertEqual(SplitBar.legendCount(entryWidths: [100, 100, 100], moreWidth: more, room: 250), 2)
        // Nothing fits.
        XCTAssertEqual(SplitBar.legendCount(entryWidths: [100, 100], moreWidth: more, room: 50), 0)
        XCTAssertEqual(SplitBar.legendCount(entryWidths: [], moreWidth: more, room: 300), 0)
    }
}
