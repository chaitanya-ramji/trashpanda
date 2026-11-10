import XCTest
@testable import PandaCore

final class TrashTests: XCTestCase {
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func trashURL(_ box: Sandbox) -> URL { box.home.appendingPathComponent(".Trash") }
    private func fill(_ box: Sandbox) throws {
        try box.file(".Trash/old-report.pdf", bytes: 3_000_000)
        try box.file(".Trash/Folder/a.bin", bytes: 2_000_000)
    }
    private func cleaner(_ s: DiskScanner, _ empty: @escaping () -> Result<Void, TrashRefusal>) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider, emptyTrash: empty)
    }

    // MARK: The item

    func testAFullTrashIsOneReviewItem() throws {
        let box = try Sandbox()
        try fill(box)
        let items = scanner(box).scanTrash()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.id, "trash")
        XCTAssertEqual(item.title, "Trash")
        XCTAssertEqual(item.ecosystem, .trash)
        XCTAssertEqual(item.tier, .review, "Emptying is final, so the user must choose it")
        XCTAssertEqual(item.rebuild, .never)
        XCTAssertNil(item.owner)
        XCTAssertTrue(item.bytes >= 5_000_000 && item.bytes < 6_000_000, "\(item.bytes)")
        if case .emptyTrash = item.action {} else { XCTFail("wrong action") }
    }

    func testAnEmptyTrashShowsNothing() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: trashURL(box), withIntermediateDirectories: true)
        XCTAssertTrue(scanner(box).scanTrash().isEmpty)
        XCTAssertTrue(scanner(box).scan().findings.filter { $0.ecosystem == .trash }.isEmpty)
    }

    func testAMissingTrashShowsNothing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanTrash().isEmpty)
    }

    func testAnEmptyFolderInsideTheTrashShowsNothing() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: trashURL(box).appendingPathComponent("Empty Folder"), withIntermediateDirectories: true)
        XCTAssertTrue(scanner(box).scanTrash().isEmpty, "A folder with no data frees no space")
    }

    func testATinyTrashIsHiddenByTheMenuLimit() throws {
        let box = try Sandbox()
        try box.file(".Trash/note.txt", bytes: 2_000)
        XCTAssertTrue(scanner(box).scan().findings.filter { $0.ecosystem == .trash }.isEmpty)
    }

    func testATrashThatCannotBeReadShowsNothingAndDoesNotCrash() throws {
        let box = try Sandbox()
        try fill(box)
        let folder = trashURL(box)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertFalse(TrashBin.readable(folder))
        XCTAssertTrue(scanner(box).scanTrash().isEmpty)
        XCTAssertEqual(TrashBin.bytes(home: box.home), 0)
    }

    func testTheTrashIsNeverPartOfTheOneClickTotal() throws {
        let box = try Sandbox()
        try fill(box)
        let result = scanner(box).scan()
        XCTAssertEqual(result.reclaimable, 0, "Reclaim now only counts safe items")
        XCTAssertTrue(result.reviewable >= 5_000_000)
    }

    func testALinkInTheTrashIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/big.bin", bytes: 9_000_000)
        try box.file(".Trash/small.bin", bytes: 1_500_000)
        try FileManager.default.createSymbolicLink(at: trashURL(box).appendingPathComponent("link"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        let bytes = try XCTUnwrap(scanner(box).scanTrash().first).bytes
        XCTAssertTrue(bytes < 3_000_000, "The size of what a link points to must not count: \(bytes)")
    }

    // MARK: The clean

    func testFinderEmptiesItAndTheReportShowsWhatLeft() throws {
        let box = try Sandbox()
        try fill(box)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanTrash().first)
        var asked = 0
        let report = cleaner(s) {
            asked += 1
            try? FileManager.default.removeItem(at: self.trashURL(box))      // what Finder does
            return .success(())
        }.clean([item])
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, item.bytes)
        XCTAssertTrue(report.failed.isEmpty && report.skipped.isEmpty)
        XCTAssertEqual(s.remainingBytes(of: item), 0)
    }

    func testTheCleanerNeverDeletesTheFilesItself() throws {
        let box = try Sandbox()
        try fill(box)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanTrash().first)
        let report = cleaner(s) { .success(()) }.clean([item])        // a Finder that does nothing
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL(box).appendingPathComponent("old-report.pdf").path),
                      "Only Finder may delete these files")
        XCTAssertEqual(report.freed, 0, "The report counts what really left, not the estimate")
        XCTAssertFalse(report.skipped.isEmpty, "The user must be told that the Trash is not empty")
    }

    func testAPartialEmptyIsReportedHonestly() throws {
        let box = try Sandbox()
        try fill(box)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanTrash().first)
        let report = cleaner(s) {
            try? FileManager.default.removeItem(at: self.trashURL(box).appendingPathComponent("old-report.pdf"))
            return .success(())
        }.clean([item])
        XCTAssertTrue(report.freed >= 2_900_000 && report.freed < 3_500_000, "\(report.freed)")
        XCTAssertEqual(report.skipped.count, 1)
    }

    func testARefusedControlOfFinderChangesNothingAndSaysWhy() throws {
        let box = try Sandbox()
        try fill(box)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanTrash().first)
        let report = cleaner(s) { .failure(.notAllowed) }.clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(report.failed[0].contains("Automation"), report.failed[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL(box).appendingPathComponent("old-report.pdf").path))
    }

    func testTheTrashIsEmptiedOnlyForItsOwnItem() throws {
        let box = try Sandbox()
        try fill(box)
        let s = scanner(box)
        var asked = 0
        let other = Finding(id: "x", ecosystem: .go, title: "Go build cache", location: "~/x", bytes: 5_000_000,
                            tier: .safe, rebuild: .minutes, action: .inform)
        _ = cleaner(s) { asked += 1; return .success(()) }.clean([other])
        XCTAssertEqual(asked, 0)
    }

    // MARK: Finder

    func testTheOnlyCommandIsEmptyTheTrash() {
        XCTAssertEqual(TrashBin.finderCommand, "tell application \"Finder\" to empty the trash")
    }

    func testResultsOfTheCommandAreTranslated() {
        func refusal(_ status: Int32, _ err: String, _ timedOut: Bool = false) -> TrashRefusal? {
            if case .failure(let r) = TrashBin.classify(status: status, stderr: err, timedOut: timedOut) { return r }
            return nil
        }
        XCTAssertNil(refusal(0, ""))
        XCTAssertEqual(refusal(1, "execution error: Not authorized to send Apple events to Finder. (-1743)"), .notAllowed)
        XCTAssertEqual(refusal(1, "x", true), .timedOut)
        XCTAssertEqual(refusal(1, " odd error \n"), .failed("odd error"))
        XCTAssertTrue(TrashRefusal.failed("").text.contains("could not empty"))
    }

    func testTheAppExplainsTheFinderPermission() throws {
        let plist = try String(contentsOfFile: "scripts/Info.plist", encoding: .utf8)
        XCTAssertTrue(plist.contains("NSAppleEventsUsageDescription"), "macOS needs this text for the Finder prompt")
    }

    // MARK: The dialog

    func testTheDialogWarnsAndKeepsTheTrashByDefault() throws {
        let box = try Sandbox()
        try fill(box)
        let item = try XCTUnwrap(scanner(box).scanTrash().first)
        XCTAssertEqual(Confirmation.kind(of: item), .trash)
        let c = Confirmation.forOne(item, staleDays: 30)
        XCTAssertEqual(c.title, "Empty the Trash?")
        XCTAssertEqual(c.confirmTitle, "Empty Trash")
        XCTAssertTrue(c.cancelIsDefault, "Return must not empty the Trash")
        XCTAssertTrue(c.footer?.contains("Finder") == true)
        XCTAssertTrue(c.footer?.contains("can't be undone") == true)
    }
}
