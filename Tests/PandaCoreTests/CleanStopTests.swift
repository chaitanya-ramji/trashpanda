import XCTest
@testable import PandaCore

/// U-06: a stop ends a clean between two items. It never cuts an item, and it reports what was not done.
final class CleanStopTests: XCTestCase {
    /// Says "go on" for the first `allowed` questions and "stop" after that.
    private final class StopAfter: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        private let allowed: Int
        init(_ allowed: Int) { self.allowed = allowed }
        var asks: Int { lock.lock(); defer { lock.unlock() }; return asked }
        func ask() -> Bool {
            lock.lock(); defer { lock.unlock() }
            asked += 1
            return asked > allowed
        }
    }

    private func setup(_ box: Sandbox) throws -> (items: [Finding], files: [URL]) {
        var items: [Finding] = []
        var files: [URL] = []
        for name in ["one", "two", "three"] {
            let file = try box.file(".cache/\(name)/blob", bytes: 3_000_000)
            files.append(file)
            items.append(Finding(id: name, ecosystem: .swift, title: "Item \(name)", location: file.deletingLastPathComponent().path,
                                 bytes: 3_000_000, tier: .safe, rebuild: .seconds,
                                 action: .removeContents(file.deletingLastPathComponent())))
        }
        return (items, files)
    }

    private func cleaner(_ box: Sandbox) -> Cleaner {
        Cleaner(guardian: PathGuard(home: box.home), runningApps: FakeRunning(apps: []).provider)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testAStopBeforeTheFirstItemDeletesNothing() throws {
        let box = try Sandbox()
        let (items, files) = try setup(box)
        let c = cleaner(box)
        var deletes = 0
        c.deleteItem = { url in deletes += 1; try FileManager.default.removeItem(at: url) }
        var shown: [String] = []
        c.shouldStop = { true }
        let report = c.clean(items, progress: { shown.append($0) })
        XCTAssertEqual(deletes, 0)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertTrue(files.allSatisfy(exists), "Every file is still there")
        XCTAssertEqual(report.skipped.count, 3)
        XCTAssertTrue(report.skipped.allSatisfy { $0.hasSuffix(": Stopped by you") }, "\(report.skipped)")
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertTrue(shown.isEmpty, "No item started")
    }

    func testAStopAfterTheFirstOfThreeRemovesOneAndSkipsTwo() throws {
        let box = try Sandbox()
        let (items, files) = try setup(box)
        let c = cleaner(box)
        let stop = StopAfter(1)
        c.shouldStop = { stop.ask() }
        var shown: [String] = []
        let report = c.clean(items, progress: { shown.append($0) })
        XCTAssertEqual(report.removed, 1)
        XCTAssertGreaterThan(report.freed, 0)
        XCTAssertFalse(exists(files[0]), "The first item is done")
        XCTAssertTrue(exists(files[1]) && exists(files[2]), "The other two are untouched")
        XCTAssertEqual(report.skipped, [items[1].location + ": Stopped by you", items[2].location + ": Stopped by you"])
        XCTAssertEqual(shown, ["Item one"], "Only the first item started")
        XCTAssertEqual(stop.asks, 2, "The question is asked once for each item that started, and once for the stop")
        // The freed bytes are the bytes of the one item that was deleted.
        XCTAssertEqual(report.freed, 3_000_000)
    }

    func testWithoutAStopTheResultIsTheSameAsBefore() throws {
        let box = try Sandbox()
        let (items, files) = try setup(box)
        let c = cleaner(box)
        let stop = StopAfter(Int.max)
        c.shouldStop = { stop.ask() }
        let report = c.clean(items)
        XCTAssertEqual(report.removed, 3)
        XCTAssertEqual(report.freed, 9_000_000)
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertTrue(files.allSatisfy { !exists($0) })

        // The default needs no setting.
        let box2 = try Sandbox()
        let (items2, files2) = try setup(box2)
        let report2 = cleaner(box2).clean(items2)
        XCTAssertEqual(report2.removed, 3)
        XCTAssertEqual(report2.freed, 9_000_000)
        XCTAssertTrue(files2.allSatisfy { !exists($0) })
    }

    /// The stop request is set while an item is being deleted through `removeEach`. That item still ends in the normal way:
    /// the guard runs, the bytes are counted, and only the next items are left.
    func testAStopDuringAnItemLetsThatItemFinish() throws {
        let box = try Sandbox()
        var items: [Finding] = []
        var folders: [URL] = []
        for name in ["a", "b", "c"] {
            let file = try box.file("code/\(name)/node_modules/x/blob", bytes: 3_000_000)
            let folder = box.home.appendingPathComponent("code/\(name)/node_modules")
            folders.append(folder)
            _ = file
            items.append(Finding(id: name, ecosystem: .swift, title: "Item \(name)", location: folder.path, bytes: 3_000_000,
                                 tier: .safe, rebuild: .download, action: .removeArtifact(folder)))
        }
        let c = cleaner(box)
        c.activeDirectories = { [] }
        let flag = StopRequest()
        var deletes = 0
        c.shouldStop = { flag.isRequested }
        c.deleteItem = { url in
            deletes += 1
            flag.request()                       // the user presses stop in the middle of the first delete
            try FileManager.default.removeItem(at: url)
        }
        let report = c.clean(items)
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(report.removed, 1)
        XCTAssertGreaterThan(report.freed, 0, "The finished item is counted")
        XCTAssertFalse(exists(folders[0]))
        XCTAssertTrue(exists(folders[1]) && exists(folders[2]))
        XCTAssertEqual(report.skipped, [items[1].location + ": Stopped by you", items[2].location + ": Stopped by you"])
    }

    /// The same as above for `.removeContents`, which has its own delete loop. Every entry of the running item goes.
    func testAStopDuringARemoveContentsItemLetsThatItemFinish() throws {
        let box = try Sandbox()
        let (items, files) = try setup(box)
        let first = files[0].deletingLastPathComponent()
        let extra = ["b", "c", "d"].map { first.appendingPathComponent($0) }
        for url in extra { try Data(repeating: 1, count: 1000).write(to: url) }
        let c = cleaner(box)
        let flag = StopRequest()
        c.shouldStop = { flag.isRequested }
        // This loop does not use `deleteItem`. The flag is set when the first item starts, so it is set while that item runs.
        let report = c.clean(items, progress: { _ in flag.request() })
        XCTAssertFalse(exists(files[0]))
        XCTAssertTrue(extra.allSatisfy { !exists($0) }, "Every entry of the running item is gone")
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(exists(files[1]) && exists(files[2]))
        XCTAssertEqual(report.skipped.count, 2, "\(report.skipped)")
        XCTAssertTrue(report.skipped.allSatisfy { $0.hasSuffix(": Stopped by you") })
    }

    /// A stop that is set before the clean runs (for example while an app quits) is kept. The item is not deleted.
    func testAStopSetBeforeTheCleanIsKeptAndReset() throws {
        let box = try Sandbox()
        let (items, files) = try setup(box)
        let flag = StopRequest()
        flag.request()
        let c = cleaner(box)
        c.shouldStop = { flag.isRequested }
        let report = c.clean([items[0]])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(files[0]))
        XCTAssertEqual(report.skipped, [items[0].location + ": Stopped by you"])
        flag.reset()                                  // the start of the next clean
        XCTAssertEqual(c.clean([items[0]]).removed, 1)
        XCTAssertFalse(exists(files[0]))
    }

    func testTheProgressThrottleLetsThroughFourEachSecondAndTheLast() {
        var now: TimeInterval = 100
        let t = ProgressThrottle(interval: 0.25, clock: { now })
        XCTAssertTrue(t.shouldShow(number: 1, total: 10))
        now += 0.01
        XCTAssertFalse(t.shouldShow(number: 2, total: 10))
        now += 0.3
        XCTAssertTrue(t.shouldShow(number: 3, total: 10))
        now += 0.01
        XCTAssertFalse(t.shouldShow(number: 4, total: 10))
        XCTAssertTrue(t.shouldShow(number: 10, total: 10), "The last one always shows")
    }

    func testTheGuardStillRefusesAnItemBeforeAStop() throws {
        let box = try Sandbox()
        let (items, files) = try setup(box)
        let outside = Finding(id: "bad", ecosystem: .swift, title: "Outside", location: "/", bytes: 1, tier: .safe,
                              rebuild: .seconds, action: .removeContents(URL(fileURLWithPath: "/usr")))
        let c = cleaner(box)
        let stop = StopAfter(2)
        c.shouldStop = { stop.ask() }
        let report = c.clean([outside] + items)
        XCTAssertEqual(report.removed, 1, "The item that the guard refused is not counted")
        XCTAssertTrue(exists(URL(fileURLWithPath: "/usr")))
        XCTAssertFalse(exists(files[0]))
        XCTAssertTrue(exists(files[1]) && exists(files[2]))
        XCTAssertEqual(report.skipped.count, 3, "\(report.skipped)")
    }

    func testProgressTextAndStopRequest() {
        XCTAssertEqual(CleanProgress.text(number: 3, total: 38, title: "Xcode build data"), "Cleaning 3 of 38 · Xcode build data")
        let r = StopRequest()
        XCTAssertFalse(r.isRequested)
        r.request()
        XCTAssertTrue(r.isRequested)
        r.reset()
        XCTAssertFalse(r.isRequested)
    }
}
