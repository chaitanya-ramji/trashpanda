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

    func testBeforeTheFirstScanTheHeaderIsASkeletonAndNeverTheDoneLook() {
        let c = HeaderContent.make(activity: .idle, hasResult: false, hasParts: false)
        XCTAssertTrue(c.showsSkeleton)
        XCTAssertFalse(c.isDone)
    }

    /// What an open menu does for each pair of states: only the end of a busy state, or the first result, builds the whole menu.
    func testTheLiveUpdateRuleForEveryPairOfStates() {
        func content(_ s: String) -> HeaderContent {
            switch s {
            case "skeleton": return HeaderContent.make(activity: .scanning, hasResult: false, hasParts: false)
            case "rescan": return HeaderContent.make(activity: .scanning, hasResult: true, hasParts: true)
            case "cleaning": return HeaderContent.make(activity: .cleaning, hasResult: true, hasParts: true, progress: "Cleaning 1 of 3")
            default: return HeaderContent.make(activity: .idle, hasResult: true, hasParts: true)
            }
        }
        let states = ["skeleton", "rescan", "cleaning", "idle"]
        for built in states {
            for now in states {
                let result = HeaderContent.liveUpdate(built: content(built), now: content(now))
                let rebuild = (built == "skeleton" && now != "skeleton") || ((built == "rescan" || built == "cleaning") && now == "idle")
                if rebuild {
                    XCTAssertEqual(result, .rebuildMenu, "\(built) to \(now) builds the whole menu")
                } else if case .detailOnly(let c) = result {
                    // The parts and the numbers of the built menu stay.
                    if built != "skeleton" && now != "skeleton" { XCTAssertEqual(c.bar, content(built).bar, "\(built) to \(now)") }
                } else {
                    XCTFail("\(built) to \(now) must be a detail-only update")
                }
            }
        }
    }
}
