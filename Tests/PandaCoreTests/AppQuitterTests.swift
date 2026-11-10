import XCTest
@testable import PandaCore

final class AppQuitterTests: XCTestCase {
    private let arc = AppOwner(name: "Arc", bundleIDs: ["company.thebrowser.Browser", "company.thebrowser.Browser.helper*"])
    private let main = RunningApp(bundleID: "company.thebrowser.Browser", name: "Arc")
    private let helper = RunningApp(bundleID: "company.thebrowser.Browser.helper.Renderer", name: "Arc Helper (Renderer)")

    /// A fake Mac: the apps leave after `leavesAfter` snapshots. The log shows what was asked.
    private final class World: @unchecked Sendable {
        var apps: [RunningApp]; var leavesAfter: Int?; var takes = 0; var asked: [[String]] = []; var pauses: [TimeInterval] = []
        init(_ apps: [RunningApp], leavesAfter: Int?) { self.apps = apps; self.leavesAfter = leavesAfter }
    }
    private func quitter(_ w: World) -> AppQuitter {
        AppQuitter(running: RunningApps { [w] in
            w.takes += 1
            if let n = w.leavesAfter, w.takes > n { w.apps = [] }
            return RunningSnapshot(apps: w.apps)
        }, ask: { w.asked.append($0) }, pause: { w.pauses.append($0) })
    }

    func testNothingRunningMeansNoAsk() {
        let w = World([], leavesAfter: nil)
        XCTAssertEqual(quitter(w).quit(arc), .quit)
        XCTAssertTrue(w.asked.isEmpty)
        XCTAssertTrue(w.pauses.isEmpty)
    }

    func testAsksTheMainAppOnlyNotTheHelpersAndWaitsUntilItIsGone() {
        let w = World([main, helper], leavesAfter: 3)
        XCTAssertEqual(quitter(w).quit(arc), .quit)
        XCTAssertEqual(w.asked, [["company.thebrowser.Browser"]], "One polite ask, main app only")
        XCTAssertEqual(w.pauses.count, 3)
    }

    func testAnAppThatStaysOpenIsReportedAndNeverForced() {
        let w = World([main], leavesAfter: nil)
        XCTAssertEqual(quitter(w).quit(arc, timeout: 2, poll: 0.5), .stillOpen(["Arc"]))
        XCTAssertEqual(w.asked.count, 1, "Asked once. No repeated asks and no force")
        XCTAssertEqual(w.pauses.count, 4)
    }

    func testAnotherAppIsNeverAsked() {
        let other = RunningApp(bundleID: "com.google.Chrome", name: "Chrome")
        let w = World([main, other], leavesAfter: 1)
        _ = quitter(w).quit(arc)
        XCTAssertEqual(w.asked, [["company.thebrowser.Browser"]])
    }

    func testAProgramWithoutAnAppStaysOpen() {
        let xcode = AppOwner(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"], processNames: ["xcodebuild"])
        let w = RunningApps { RunningSnapshot(apps: [], processes: ["xcodebuild"]) }
        var asked = false
        let q = AppQuitter(running: w, ask: { _ in asked = true }, pause: { _ in })
        XCTAssertEqual(q.quit(xcode, timeout: 1, poll: 0.5), .stillOpen(["xcodebuild"]))
        XCTAssertFalse(asked, "A command line program cannot be asked, and is not killed")
    }

    /// The source must never force a quit or kill a process.
    func testNoForcedQuitAnywhereInTheSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20)
        let banned = ["forceTerminate", "SIGKILL", "kill(", "killall", "pkill", "NSRunningApplication.forceTerminate", "/bin/kill"]
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for word in banned { XCTAssertFalse(text.contains(word), "\(f.lastPathComponent) contains \(word)") }
        }
    }
}
