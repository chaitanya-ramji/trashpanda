import XCTest
@testable import PandaCore

final class HeaderContentTests: XCTestCase {
    func testIdleShowsThePartsAndTheSummary() {
        let c = HeaderContent.make(activity: .idle, hasResult: true, hasParts: true)
        XCTAssertEqual(c.bar, .parts)
        XCTAssertNil(c.detail, "nil means the summary of the totals")
        XCTAssertEqual(c.barAlpha, 1)
        XCTAssertFalse(c.busy)
    }

    func testIdleWithNothingToCleanShowsAnEmptyTrack() {
        let c = HeaderContent.make(activity: .idle, hasResult: true, hasParts: false)
        XCTAssertEqual(c.bar, .emptyTrack)
        XCTAssertEqual(c.barAlpha, 1)
    }

    func testTheFirstScanShowsASkeletonAndNoNumbers() {
        let c = HeaderContent.make(activity: .scanning, hasResult: false, hasParts: false)
        XCTAssertEqual(c.bar, .skeleton)
        XCTAssertTrue(c.showsSkeleton)
        XCTAssertEqual(c.detail, "Looking for things to clean…")
        XCTAssertTrue(c.busy)
    }

    func testANewScanKeepsTheOldBarAndDrawsItLighter() {
        let c = HeaderContent.make(activity: .scanning, hasResult: true, hasParts: true)
        XCTAssertEqual(c.bar, .parts)
        XCTAssertEqual(c.detail, "Checking again…")
        XCTAssertEqual(c.barAlpha, HeaderContent.refreshingAlpha)
        XCTAssertLessThan(c.barAlpha, 1)
        XCTAssertFalse(c.showsSkeleton, "a skeleton only shows before the first result")
    }

    func testANewScanOfAnEmptyResultKeepsTheEmptyTrack() {
        XCTAssertEqual(HeaderContent.make(activity: .scanning, hasResult: true, hasParts: false).bar, .emptyTrack)
    }

    func testCleaningKeepsTheBarAndShowsTheProgressText() {
        let c = HeaderContent.make(activity: .cleaning, hasResult: true, hasParts: true, progress: "Cleaning Xcode caches…")
        XCTAssertEqual(c.bar, .parts)
        XCTAssertEqual(c.detail, "Cleaning Xcode caches…")
        XCTAssertEqual(c.barAlpha, HeaderContent.refreshingAlpha)
        XCTAssertEqual(HeaderContent.make(activity: .cleaning, hasResult: true, hasParts: true).detail, "Cleaning up…")
        XCTAssertEqual(HeaderContent.make(activity: .cleaning, hasResult: true, hasParts: true, progress: "").detail, "Cleaning up…")
    }

    func testTheSkeletonNeverShowsWhenAResultExists() {
        for activity in [MenuModel.Activity.idle, .scanning, .cleaning] {
            for parts in [true, false] {
                XCTAssertFalse(HeaderContent.make(activity: activity, hasResult: true, hasParts: parts).showsSkeleton)
            }
        }
    }

    func testTheShimmerRepeatsAndStaysInRange() {
        for i in 0..<200 {
            let p = HeaderContent.shimmerPhase(at: Double(i) * 0.137 - 3)
            XCTAssertGreaterThanOrEqual(p, 0)
            XCTAssertLessThan(p, 1)
        }
        XCTAssertEqual(HeaderContent.shimmerPhase(at: 0.45, period: 1.8), 0.25, accuracy: 1e-9)
        XCTAssertEqual(HeaderContent.shimmerPhase(at: 0.45 + 1.8, period: 1.8), 0.25, accuracy: 1e-9)
        XCTAssertEqual(HeaderContent.shimmerPhase(at: 5, period: 0), 0)
    }
}
