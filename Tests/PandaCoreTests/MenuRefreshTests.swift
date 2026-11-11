import XCTest
@testable import PandaCore

final class MenuRefreshTests: XCTestCase {
    func testAChangeWhileClosedBuildsAtOnce() {
        var gate = MenuRefreshGate()
        XCTAssertEqual(gate.changed(), .rebuild)
        XCTAssertFalse(gate.needsRebuild)
    }

    func testAChangeWhileOpenKeepsTheRowsAndBuildsAfterTheClose() {
        var gate = MenuRefreshGate()
        gate.opened()
        XCTAssertEqual(gate.changed(), .updateLiveRows)
        XCTAssertEqual(gate.changed(), .updateLiveRows)
        XCTAssertTrue(gate.needsRebuild)
        XCTAssertTrue(gate.closed())
        XCTAssertFalse(gate.isOpen)
        XCTAssertFalse(gate.needsRebuild)
    }

    func testClosingWithNoChangeBuildsNothing() {
        var gate = MenuRefreshGate()
        gate.opened()
        XCTAssertFalse(gate.closed())
    }

    func testTheNextOpenStartsClean() {
        var gate = MenuRefreshGate()
        gate.opened()
        _ = gate.changed()
        gate.opened()
        XCTAssertFalse(gate.needsRebuild)
    }
}
