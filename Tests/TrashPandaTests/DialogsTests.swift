import AppKit
import XCTest
import PandaCore
@testable import TrashPanda

final class DialogsTests: XCTestCase {
    private func finding(_ action: Action) -> Finding {
        Finding(id: "1", ecosystem: .javascript, title: "node_modules · app", location: "~/Projects", bytes: 1_000_000,
                tier: .safe, rebuild: .minutes, action: action)
    }

    private func box(_ f: Finding, cancelIsDefault: Bool = false) -> FindingBox {
        FindingBox([f], title: "Free up?", body: "Body", cancelIsDefault: cancelIsDefault, revealURL: f.revealURL)
    }

    func testAnItemWithAFolderHasTheKeepBoxAndTheThirdButton() {
        let (alert, confirmed) = Dialogs.makeAlert(for: box(finding(.removeArtifact(URL(fileURLWithPath: "/tmp/none")))))
        XCTAssertTrue(alert.showsSuppressionButton)
        XCTAssertEqual(alert.suppressionButton?.title, "Always keep this item")
        XCTAssertEqual(alert.buttons.map(\.title), ["Free up 1 MB", "Not now", "Show in Finder"])
        XCTAssertEqual(confirmed, .alertFirstButtonReturn)
    }

    func testTheKeepFirstDialogKeepsItsOrder() {
        let (alert, confirmed) = Dialogs.makeAlert(for: box(finding(.removeArtifact(URL(fileURLWithPath: "/tmp/none"))), cancelIsDefault: true))
        XCTAssertEqual(alert.buttons.map(\.title), ["Keep it", "Free up 1 MB", "Show in Finder"])
        XCTAssertEqual(confirmed, .alertSecondButtonReturn)
        XCTAssertTrue(alert.showsSuppressionButton)
    }

    func testADockerItemHasNeitherTheBoxNorTheThirdButton() {
        let (alert, _) = Dialogs.makeAlert(for: box(finding(.docker(.removeVolume(name: "data")))))
        XCTAssertFalse(alert.showsSuppressionButton)
        XCTAssertEqual(alert.buttons.map(\.title), ["Free up 1 MB", "Not now"])
    }
}
