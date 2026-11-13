import XCTest
@testable import PandaCore

/// The one delete helper of `Cleaner`: measure first, check last, then delete.
final class CleanerDeleteTests: XCTestCase {
    private func finding() -> Finding {
        Finding(id: "t", ecosystem: .browsers, title: "Test", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                action: .inform)
    }

    private func isPlain(_ url: URL) -> Bool { UpdateDownloads.isPlainPath(url) }

    final class Events {
        var list: [String] = []
        func add(_ s: String) { list.append(s) }
    }

    struct Boom: Error {}

    /// A cleaner whose measuring and deleting are recorded. Deleting does nothing.
    private func recorder(_ box: Sandbox, events: Events, bytes: Int64 = 100,
                          whileMeasuring: (() -> Void)? = nil) -> Cleaner {
        let cleaner = Cleaner(guardian: PathGuard(home: box.home))
        cleaner.sizeOf = { _ in events.add("sizeOf"); whileMeasuring?(); return bytes }
        cleaner.deleteItem = { _ in events.add("delete") }
        return cleaner
    }

    // MARK: Order

    func testTheOrderIsShapeMeasureShapeKeepGuardDelete() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let events = Events()
        let cleaner = recorder(box, events: events)
        var report = CleanReport()
        let done = cleaner.removeEach([folder], of: finding(), into: &report, notTarget: "no",
                                      isTarget: { _ in events.add("isTarget"); return true },
                                      keepReason: { _, _ in events.add("keep"); return nil })
        XCTAssertEqual(events.list, ["isTarget", "sizeOf", "isTarget", "keep", "delete"])
        XCTAssertEqual(done, .init(removed: 1, failures: 0))
        XCTAssertEqual(report.freed, 100)
    }

    /// The guard runs after the measuring. A last folder that becomes a link while we measure is refused by the guard,
    /// even when the shape check of the caller says yes.
    func testTheGuardRunsAfterTheMeasuring() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let other = try box.file("Library/Caches/Demo/Other/b", bytes: 10).deletingLastPathComponent()
        let events = Events()
        let cleaner = recorder(box, events: events) {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createSymbolicLink(at: folder, withDestinationURL: other)
        }
        var report = CleanReport()
        cleaner.removeEach([folder], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true })
        XCTAssertEqual(events.list, ["sizeOf"], "nothing is deleted")
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue((report.skipped.first ?? "").contains("symbolic link"), (report.skipped.first ?? ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("b").path))
    }

    // MARK: removeContents: the check after the measuring

    private func contentsFinding(_ dir: URL) -> Finding {
        Finding(id: "t", ecosystem: .python, title: "Test", location: "~/x", bytes: 1, tier: .safe, rebuild: .download,
                action: .removeContents(dir))
    }

    /// A parent folder is swapped for a link inside the measuring. The guard looks at the last part only, so the check of the whole
    /// path after the measuring (`isPlain`) must catch it. Nothing is deleted, and the reason is honest.
    func testRemoveContentsChecksTheWholePathAgainAfterTheMeasuring() throws {
        let box = try Sandbox()
        let leak = try box.file("Other/pip/leak.bin", bytes: 10)
        let target = try box.file(".cache/pip/a.bin", bytes: 10).deletingLastPathComponent()
        let cache = box.home.appendingPathComponent(".cache")
        let events = Events()
        let cleaner = recorder(box, events: events) {
            try? FileManager.default.moveItem(at: cache, to: box.home.appendingPathComponent(".cache-real"))
            try? FileManager.default.createSymbolicLink(at: cache, withDestinationURL: box.home.appendingPathComponent("Other"))
        }
        cleaner.activeDirectories = { [] }
        let report = cleaner.clean([contentsFinding(target)])
        XCTAssertEqual(events.list, ["sizeOf"], "nothing is deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leak.path), "a file behind the link is never touched")
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertTrue(report.skipped.first?.hasSuffix("a folder in the path is a link") == true, "\(report.skipped)")
    }

    /// The last folder is swapped for a link inside the measuring: the guard after the measuring refuses it.
    func testRemoveContentsRunsTheGuardAgainAfterTheMeasuring() throws {
        let box = try Sandbox()
        let target = try box.file("Library/Caches/Demo/a.bin", bytes: 10).deletingLastPathComponent()
        let other = try box.file("Library/Caches/Other/b.bin", bytes: 10).deletingLastPathComponent()
        let events = Events()
        let cleaner = recorder(box, events: events) {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        }
        cleaner.activeDirectories = { [] }
        let report = cleaner.clean([contentsFinding(target)])
        XCTAssertEqual(events.list, ["sizeOf"], "nothing is deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("b.bin").path))
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue((report.skipped.first ?? "").contains("link"), "\(report.skipped)")
    }

    /// The guard after the measuring is a check of its own. Here the last folder becomes a link that points to ITSELF: the shape check
    /// of the whole path (`isPlain`) accepts it (the path is equal to its resolved path, because nothing can be resolved), and only the
    /// guard refuses it. If the second `guardian.check` is removed, the run goes on, cannot read the folder, and the report has a
    /// failure and no guard reason. The test fails then.
    func testRemoveContentsSecondGuardRefusesWhatIsPlainAcceptsAfterTheMeasuring() throws {
        let box = try Sandbox()
        let target = try box.file("Library/Caches/Demo/a.bin", bytes: 10).deletingLastPathComponent()
        let keep = try box.file("Documents/letter.txt", bytes: 10)
        let events = Events()
        let cleaner = recorder(box, events: events) {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "Demo")
        }
        cleaner.activeDirectories = { [] }
        let report = cleaner.clean([contentsFinding(target)])
        XCTAssertTrue(isPlain(target), "isPlain accepts this link, so only the guard can refuse it")
        XCTAssertEqual(events.list, ["sizeOf"], "nothing is deleted")
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertEqual(report.skipped.count, 1, "\(report.skipped)")
        XCTAssertTrue(report.skipped.first?.hasSuffix("path is a symbolic link") == true, "\(report.skipped)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    // MARK: A target that becomes a link

    /// A parent folder becomes a link while we measure. The path now leads somewhere else in the home folder. The guard cannot tell,
    /// so the shape check after the measuring must.
    func testATargetThatBecomesALinkDuringTheMeasuringIsRefused() throws {
        let box = try Sandbox()
        let parent = box.home.appendingPathComponent("Library/Caches/Demo")
        let target = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let moved = box.home.appendingPathComponent("Library/Caches/Moved")
        let events = Events()
        let cleaner = recorder(box, events: events) {
            try? FileManager.default.moveItem(at: parent, to: moved)
            try? FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
        }
        var report = CleanReport()
        let done = cleaner.removeEach([target], of: finding(), into: &report, notTarget: "not a cache folder", isTarget: isPlain)
        XCTAssertEqual(events.list, ["sizeOf"], "nothing is deleted")
        XCTAssertEqual(done, .init(removed: 0, failures: 0))
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue((report.skipped.first ?? "").contains("not a cache folder"), (report.skipped.first ?? ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Cache/a").path))
    }

    // MARK: The guard

    func testTheGuardStopsAFolderThatMustStay() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Demo/a", bytes: 10)
        let caches = box.home.appendingPathComponent("Library/Caches")
        let events = Events()
        let cleaner = recorder(box, events: events)
        var report = CleanReport()
        cleaner.removeEach([caches], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true })
        XCTAssertFalse(events.list.contains("delete"))
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue((report.skipped.first ?? "").contains("protected"), (report.skipped.first ?? ""))
    }

    func testTheSystemCacheNameReachesTheGuard() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/com.apple.demo/a", bytes: 10).deletingLastPathComponent()
        var report = CleanReport()
        let events = Events()
        recorder(box, events: events).removeEach([folder], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true })
        XCTAssertFalse(events.list.contains("delete"), "the guard protects a macOS folder")
        let events2 = Events()
        var report2 = CleanReport()
        recorder(box, events: events2).removeEach([folder], of: finding(), into: &report2, notTarget: "no", isTarget: { _ in true },
                                                  allowingSystemCache: "com.apple.demo")
        XCTAssertTrue(events2.list.contains("delete"), "the owner named this one folder")
    }

    // MARK: Errors and gone targets

    func testADeleteThatThrowsIsAFailureAndAddsNoBytes() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let cleaner = Cleaner(guardian: PathGuard(home: box.home))
        cleaner.sizeOf = { _ in 500 }
        cleaner.deleteItem = { _ in throw Boom() }
        var report = CleanReport()
        let done = cleaner.removeEach([folder], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true })
        XCTAssertEqual(done, .init(removed: 0, failures: 1))
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue((report.failed.first ?? "").hasPrefix("~/Library/Caches/Demo/Cache"), (report.failed.first ?? ""))
    }

    func testAFailureDoesNotStopTheNextTarget() throws {
        let box = try Sandbox()
        let a = try box.file("Library/Caches/Demo/A/x", bytes: 10).deletingLastPathComponent()
        let b = try box.file("Library/Caches/Demo/B/x", bytes: 10).deletingLastPathComponent()
        let cleaner = Cleaner(guardian: PathGuard(home: box.home))
        cleaner.sizeOf = { _ in 7 }
        cleaner.deleteItem = { url in
            if url.lastPathComponent == "A" { throw Boom() }
            try FileManager.default.removeItem(at: url)
        }
        var report = CleanReport()
        let done = cleaner.removeEach([a, b], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true })
        XCTAssertEqual(done, .init(removed: 1, failures: 1))
        XCTAssertEqual(report.freed, 7)
    }

    func testATargetThatIsGoneIsASkip() throws {
        let box = try Sandbox()
        let gone = box.home.appendingPathComponent("Library/Caches/Demo/Cache")
        let events = Events()
        let cleaner = recorder(box, events: events)
        var report = CleanReport()
        let done = cleaner.removeEach([gone], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true })
        XCTAssertEqual(events.list, [], "nothing is measured or deleted")
        XCTAssertEqual(done, .init(removed: 0, failures: 0))
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue((report.skipped.first ?? "").contains("not there now"), (report.skipped.first ?? ""))
        XCTAssertTrue(report.failed.isEmpty)
    }

    func testATargetThatGoesAwayDuringTheMeasuringIsASkip() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let events = Events()
        let cleaner = recorder(box, events: events) { try? FileManager.default.removeItem(at: folder) }
        var report = CleanReport()
        cleaner.removeEach([folder], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true })
        XCTAssertEqual(events.list, ["sizeOf"])
        XCTAssertEqual(report.freed, 0)
        XCTAssertTrue((report.skipped.first ?? "").contains("not there now"), (report.skipped.first ?? ""))
    }

    // MARK: The checks of the caller

    func testAShapeThatIsWrongIsRefusedBeforeTheMeasuring() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let events = Events()
        var report = CleanReport()
        recorder(box, events: events).removeEach([folder], of: finding(), into: &report, notTarget: "not a cache folder", isTarget: { _ in false })
        XCTAssertEqual(events.list, [])
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue((report.skipped.first ?? "").hasSuffix("not a cache folder"), (report.skipped.first ?? ""))
    }

    func testAKeepReasonStopsTheDeleteAndShowsItsText() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        let events = Events()
        var report = CleanReport()
        recorder(box, events: events).removeEach([folder], of: finding(), into: &report, notTarget: "no", isTarget: { _ in true },
                                                 keepReason: { _, _ in "a program runs from it" })
        XCTAssertEqual(events.list, ["sizeOf"])
        XCTAssertTrue((report.skipped.first ?? "").hasSuffix("a program runs from it"), (report.skipped.first ?? ""))
    }

    func testTheHomeFolderIsWrittenAsATilde() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 10).deletingLastPathComponent()
        var report = CleanReport()
        recorder(box, events: Events()).removeEach([folder], of: finding(), into: &report, notTarget: "no", isTarget: { _ in false })
        XCTAssertEqual(report.skipped, ["~/Library/Caches/Demo/Cache: no"])
    }

    func testTheRealDeleteRemovesTheFolderAndCountsTheMeasuredBytes() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Caches/Demo/Cache/a", bytes: 4_000_000).deletingLastPathComponent()
        let cleaner = Cleaner(guardian: PathGuard(home: box.home))
        var report = CleanReport()
        cleaner.removeEach([folder], of: finding(), into: &report, notTarget: "no", isTarget: isPlain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(report.freed >= 4_000_000 && report.freed < 5_000_000, "\(report.freed)")
    }
}
