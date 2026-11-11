import XCTest
@testable import PandaCore

/// U-07: one summary dialog after a clean.
final class CleanSummaryTests: XCTestCase {
    private func report(freed: Int64 = 4_200_000_000, removed: Int = 36, skipped: [String] = [], failed: [String] = [],
                        change: Int64 = 4_100_000_000) -> CleanReport {
        var r = CleanReport()
        r.freed = freed
        r.removed = removed
        r.skipped = skipped
        r.failed = failed
        r.volumeChange = change
        return r
    }

    func testAllGoodNeedsNoDialog() {
        let r = report()
        XCTAssertFalse(CleanSummary.needsDialog(r, dockerDiskNote: false))
        let s = CleanSummary.make(r, dockerDiskNote: false)
        XCTAssertEqual(s.title, "Freed 4.2 GB")
        XCTAssertEqual(s.lines.first, "36 items removed.")
        XCTAssertEqual(s.buttons, [.ok])
    }

    func testSkippedOnly() {
        let r = report(skipped: ["/a: Xcode is running. Quit it and try again.", "/b: Xcode is running. Quit it and try again."])
        XCTAssertTrue(CleanSummary.needsDialog(r, dockerDiskNote: false))
        let s = CleanSummary.make(r, dockerDiskNote: false)
        XCTAssertEqual(s.title, "Freed 4.2 GB")
        XCTAssertEqual(s.lines[0], "36 items removed.")
        XCTAssertEqual(s.lines[1], "2 items left alone: Xcode is running. Quit it and try again.")
        XCTAssertEqual(s.buttons, [.ok], "No log button when nothing failed")
    }

    func testFailedOnly() {
        let r = report(removed: 1, failed: ["Docker: Docker did not answer"])
        XCTAssertTrue(CleanSummary.needsDialog(r, dockerDiskNote: false))
        let s = CleanSummary.make(r, dockerDiskNote: false)
        XCTAssertEqual(s.lines[0], "1 item removed.")
        XCTAssertEqual(s.lines[1], "1 item failed: Docker did not answer.")
        XCTAssertEqual(s.buttons, [.ok, .showLog])
        XCTAssertEqual(CleanSummary.Button.showLog.title, "Show Log")
    }

    func testAllThree() {
        let r = report(skipped: ["/a: the app is open (Xcode)."], failed: ["/c: Docker did not answer"])
        let s = CleanSummary.make(r, dockerDiskNote: true)
        XCTAssertEqual(s.title, "Freed 4.2 GB")
        XCTAssertEqual(s.lines[1], "1 item left alone: the app is open (Xcode).")
        XCTAssertEqual(s.lines[2], "1 item failed: Docker did not answer.")
        XCTAssertEqual(s.buttons, [.ok, .showLog, .dockerDiskFile])
        XCTAssertEqual(CleanSummary.Button.dockerDiskFile.title, "About the Docker Disk File")
    }

    func testTheDockerNoteAloneShowsTheDialog() {
        let r = report()
        XCTAssertTrue(CleanSummary.needsDialog(r, dockerDiskNote: true))
        XCTAssertEqual(CleanSummary.make(r, dockerDiskNote: true).buttons, [.ok, .dockerDiskFile])
    }

    func testAtMostThreeReasonsThenTheRestIsCounted() {
        let skipped = (1...7).map { "/p\($0): reason \($0)." }
        let s = CleanSummary.make(report(skipped: skipped), dockerDiskNote: false)
        XCTAssertEqual(s.lines[1], "7 items left alone: reason 1; reason 2; reason 3 and 4 more.")
    }

    func testNothingFreed() {
        let s = CleanSummary.make(report(freed: 0, removed: 0, skipped: ["x: Stopped by you"], change: 0), dockerDiskNote: false)
        XCTAssertEqual(s.title, "Nothing freed")
        XCTAssertEqual(s.lines[0], "0 items removed.")
    }

    /// The check of the real free space is honest: it names the difference and never promises a number.
    func testTheFreeSpaceLineIsHonest() {
        let grew = CleanSummary.make(report(skipped: ["x: y"], change: 3_900_000_000), dockerDiskNote: false).lines.last!
        XCTAssertTrue(grew.hasPrefix("The free space on your Mac grew by 3.9 GB during the clean."), grew)
        XCTAssertTrue(grew.contains("can differ"), grew)
        XCTAssertTrue(grew.contains("clone") && grew.contains("snapshot"), grew)
        XCTAssertFalse(grew.lowercased().contains("will"), "No promise")
        let down = CleanSummary.make(report(skipped: ["x: y"], change: -50_000_000), dockerDiskNote: false).lines.last!
        XCTAssertTrue(down.hasPrefix("The free space on your Mac went down by 50 MB"), down)
        let same = CleanSummary.make(report(skipped: ["x: y"], change: 0), dockerDiskNote: false).lines.last!
        XCTAssertTrue(same.hasPrefix("The free space on your Mac did not change"), same)
    }

    func testTheReasonOfAnEntry() {
        XCTAssertEqual(CleanSummary.reason(of: "/Users/x/.cache/a: project is in use"), "project is in use")
        XCTAssertEqual(CleanSummary.reason(of: "Trash: 5 MB is still in the Trash. Finder left it."), "5 MB is still in the Trash. Finder left it")
        XCTAssertEqual(CleanSummary.reason(of: "no colon here."), "no colon here")
    }
}
