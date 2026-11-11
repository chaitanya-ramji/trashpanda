import XCTest
import PandaCore
@testable import TrashPanda

/// Q-11: the demo code lives in its own files. The demo data must still make a good menu.
final class DemoTests: XCTestCase {
    func testTheDemoDataMakesAMenuModel() {
        let data = DemoData.result()
        let result = ScanResult(findings: data.findings.filter(\.isActionable), disk: data.disk)
        XCTAssertFalse(result.findings.isEmpty)
        let input = MenuInput(result: result, disk: data.disk, scanning: false, cleaning: false,
                              running: RunningSnapshot(apps: [RunningApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")]), staleDays: 90)
        let model = MenuModel.make(input)
        XCTAssertFalse(model.header.segments.isEmpty)
        XCTAssertEqual(model.header.activity, .idle)
    }

    func testDemoModeStartsOnlyWithTheFlag() {
        XCTAssertNil(DemoController(arguments: ["trashpanda"]))
        XCTAssertEqual(DemoController(arguments: ["trashpanda", "--demo"])?.style, "light")
        XCTAssertEqual(DemoController(arguments: ["trashpanda", "--demo", "dark", "--backdrop"])?.style, "dark")
    }
}
