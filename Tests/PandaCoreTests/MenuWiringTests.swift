import XCTest
@testable import PandaCore

/// The decisions of the open-menu wiring of the app delegate. They were written from the behaviour of the delegate before
/// the decisions moved out of it, so they keep that behaviour. Nothing here uses AppKit: a model change while the menu is
/// closed returns actions, and there is no object that the actions could touch.
final class MenuWiringTests: XCTestCase {
    private let disk = DiskUsage(total: 500_000_000_000, free: 100_000_000_000)
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func finding(_ id: String, _ bytes: Int64) -> Finding {
        Finding(id: id, ecosystem: .javascript, title: "node_modules · \(id)", location: "~/Projects", bytes: bytes,
                tier: .safe, rebuild: .minutes, action: .owner(.brewCleanup))
    }

    /// A model for a state. `findings` nil: no scan has finished (the skeleton).
    private func model(_ findings: [Finding]? = [], scanning: Bool = false, cleaning: Bool = false) -> MenuModel {
        MenuModel.make(MenuInput(result: findings.map { ScanResult(findings: $0, disk: disk, date: now) }, disk: disk,
                                 scanning: scanning, cleaning: cleaning, running: RunningSnapshot(apps: []),
                                 staleDays: 90, now: now, updateVersion: nil, updateCheckEnabled: true, loginEnabled: false))
    }

    private var skeleton: MenuModel { model(nil, scanning: true) }
    private var idle: MenuModel { model([finding("a", 1_000_000_000)]) }
    private var idleOther: MenuModel { model([finding("a", 1_000_000_000), finding("b", 2_000_000_000)]) }
    private var scanningWithResult: MenuModel { model([finding("a", 1_000_000_000)], scanning: true) }

    private func builds(_ actions: [MenuWiring.Action]) -> Int {
        actions.filter { if case .buildMenu = $0 { return true } else { return false } }.count
    }
    private func isLive(_ actions: [MenuWiring.Action]) -> Bool {
        actions.contains { if case .updateLiveRows = $0 { return true } else { return false } }
    }

    /// An open menu that shows `shown`.
    private func opened(_ shown: MenuModel) -> MenuWiring {
        var w = MenuWiring()
        w.openingBegan()
        _ = w.openingFinished(model: shown)
        return w
    }

    func testTheFixturesAreDifferentModels() {
        XCTAssertNotEqual(idle, idleOther)
        XCTAssertNotEqual(idle, scanningWithResult)
        XCTAssertTrue(scanningWithResult.header.content.busy)
        XCTAssertFalse(idle.header.content.busy)
        XCTAssertTrue(skeleton.header.content.showsSkeleton)
    }

    // MARK: Open

    func testTheOpenBuildsTheMenuOnceAndTellsTheHeaderItIsOpen() {
        var w = MenuWiring()
        w.openingBegan()
        let actions = w.openingFinished(model: idle)
        XCTAssertEqual(actions, [.buildMenu(idle, headerIsOpen: false), .setHeaderOpen(true)])
        XCTAssertTrue(w.isOpen)
        XCTAssertFalse(w.isOpening)
    }

    func testAChangeDuringTheOpenBuildsNothing() {
        // `menuWillOpen` starts a scan, and the scan calls `busyChanged`: no second build.
        var w = MenuWiring()
        w.openingBegan()
        XCTAssertTrue(w.isOpening)
        XCTAssertEqual(w.modelChanged(scanningWithResult), [])
        XCTAssertEqual(builds(w.openingFinished(model: scanningWithResult)), 1)
    }

    func testTheOpenSkipsAnEqualModel() {
        var w = MenuWiring()
        _ = w.modelChanged(idle)   // built while closed
        w.openingBegan()
        XCTAssertEqual(w.openingFinished(model: idle), [.skipEqualModel, .setHeaderOpen(true)])
    }

    func testTheOpeningFlagDoesNotLeak() {
        var w = MenuWiring()
        w.openingBegan()
        _ = w.openingFinished(model: idle)
        XCTAssertFalse(w.modelChanged(scanningWithResult).isEmpty)
    }

    // MARK: Closed menu

    func testAChangeWhileClosedBuildsAtOnce() {
        var w = MenuWiring()
        XCTAssertEqual(w.modelChanged(idle), [.buildMenu(idle, headerIsOpen: false)])
        XCTAssertFalse(w.rebuildWaits)
    }

    func testAnEqualModelSkipsTheRebuild() {
        var w = MenuWiring()
        _ = w.modelChanged(idle)
        XCTAssertEqual(w.modelChanged(idle), [.skipEqualModel])
        XCTAssertEqual(builds(w.modelChanged(idleOther)), 1)
        XCTAssertEqual(w.modelChanged(idleOther), [.skipEqualModel])
    }

    func testAChangeWhileClosedOnlyReturnsBuildActions() {
        // The wiring holds no AppKit object: the menu, the header and the timers change only when the delegate runs an action.
        var w = MenuWiring()
        let actions = w.modelChanged(idle)
        XCTAssertEqual(actions, [.buildMenu(idle, headerIsOpen: false)])
        XCTAssertFalse(actions.contains(.setHeaderOpen(true)))
        XCTAssertFalse(isLive(actions))
        XCTAssertFalse(w.isOpen)
    }

    // MARK: Open menu

    func testAnOpenMenuUpdatesLiveRowsAndWaitsForTheClose() {
        var w = opened(idle)
        let actions = w.modelChanged(scanningWithResult)
        XCTAssertTrue(isLive(actions))
        XCTAssertEqual(builds(actions), 0)
        XCTAssertTrue(w.rebuildWaits)
        XCTAssertEqual(builds(w.modelChanged(idle)), 0)
    }

    func testTheDeferredRebuildAppliesAtTheClose() {
        var w = opened(idle)
        _ = w.modelChanged(idleOther)
        XCTAssertEqual(w.menuClosed(model: idleOther), [.setHeaderOpen(false), .buildMenu(idleOther, headerIsOpen: false)])
        XCTAssertFalse(w.rebuildWaits)
        w.openingBegan()
        XCTAssertEqual(w.openingFinished(model: idleOther), [.skipEqualModel, .setHeaderOpen(true)], "the next open has it already")
    }

    func testCloseWithoutAChangeBuildsNothing() {
        var w = opened(idle)
        XCTAssertEqual(w.menuClosed(model: idle), [.setHeaderOpen(false)])
    }

    func testBusyToIdleWhileOpenTriggersOneRebuild() {
        var w = opened(scanningWithResult)
        XCTAssertEqual(w.modelChanged(idle), [.buildMenu(idle, headerIsOpen: true)])
        XCTAssertTrue(isLive(w.modelChanged(idle)), "a second change updates the rows only: no second rebuild")
    }

    func testTheFirstResultWhileOpenBuildsTheWholeMenu() {
        var w = opened(skeleton)
        XCTAssertEqual(builds(w.modelChanged(idle)), 1)
    }

    func testALiveUpdateForgetsTheLastBuild() {
        var w = opened(idle)
        XCTAssertTrue(isLive(w.modelChanged(scanningWithResult)))
        XCTAssertNil(w.builtModel)
        // The open menu shows live rows of another model, so the close builds, also for a model equal to the old build.
        XCTAssertEqual(builds(w.menuClosed(model: idle)), 1)
    }

    func testManyChangesWhileOpenBuildOnceAtTheClose() {
        var w = opened(idle)
        _ = w.modelChanged(scanningWithResult)
        _ = w.modelChanged(idleOther)
        _ = w.modelChanged(idle)
        let actions = w.menuClosed(model: idle)
        XCTAssertEqual(builds(actions), 1)
        XCTAssertEqual(actions.first, .setHeaderOpen(false))
    }

    // MARK: Timers

    func testTheHeaderTimerIsAllowedOnlyWhileOpen() {
        var w = MenuWiring()
        XCTAssertFalse(w.isOpen)
        w.openingBegan()
        XCTAssertTrue(w.openingFinished(model: skeleton).contains(.setHeaderOpen(true)))
        XCTAssertTrue(w.isOpen)
        XCTAssertTrue(w.menuClosed(model: skeleton).contains(.setHeaderOpen(false)))
        XCTAssertFalse(w.isOpen)
    }

    func testABuildWhileClosedGivesAHeaderThatIsNotOpen() {
        var w = MenuWiring()
        XCTAssertEqual(w.modelChanged(skeleton), [.buildMenu(skeleton, headerIsOpen: false)])
    }

    func testABuildWhileOpenGivesAHeaderThatIsOpen() {
        var w = opened(skeleton)
        XCTAssertEqual(w.modelChanged(idle), [.buildMenu(idle, headerIsOpen: true)])
    }

    func testTheStatusSpinnerStartsOnceAndStopsWhenIdle() {
        var w = MenuWiring()
        XCTAssertEqual(w.activityChanged(.scanning), [.startSpinner])
        XCTAssertEqual(w.activityChanged(.scanning), [])
        XCTAssertEqual(w.activityChanged(.cleaning), [], "a clean after a scan keeps the same timer")
        XCTAssertEqual(w.activityChanged(.idle), [.stopSpinner])
        XCTAssertFalse(w.spinnerRuns)
        XCTAssertEqual(w.activityChanged(.cleaning), [.startSpinner])
    }

    func testTheStatusSpinnerDoesNotDependOnTheMenu() {
        var w = opened(idle)
        XCTAssertEqual(w.activityChanged(.scanning), [.startSpinner])
        _ = w.menuClosed(model: idle)
        XCTAssertTrue(w.spinnerRuns)
    }

    // MARK: Sequences

    func testRapidOpenCloseOpen() {
        var w = MenuWiring()
        w.openingBegan()
        XCTAssertEqual(builds(w.openingFinished(model: idle)), 1)
        XCTAssertEqual(w.menuClosed(model: idle), [.setHeaderOpen(false)])
        w.openingBegan()
        XCTAssertEqual(w.openingFinished(model: idle), [.skipEqualModel, .setHeaderOpen(true)])
        XCTAssertTrue(w.isOpen)
        XCTAssertFalse(w.rebuildWaits)
        XCTAssertEqual(w.menuClosed(model: idle), [.setHeaderOpen(false)])
        XCTAssertFalse(w.isOpen)
    }

    func testAChangeBetweenCloseAndOpenIsBuiltOnce() {
        var w = opened(idle)
        _ = w.menuClosed(model: idle)
        XCTAssertEqual(builds(w.modelChanged(idleOther)), 1, "closed: built at once")
        w.openingBegan()
        XCTAssertEqual(w.openingFinished(model: idleOther), [.skipEqualModel, .setHeaderOpen(true)])
    }
}
