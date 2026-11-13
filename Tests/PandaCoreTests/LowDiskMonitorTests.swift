import XCTest
@testable import PandaCore

/// The busy flag, the once-a-day rule, and the log lines of the low-disk alert (#229).
/// No test uses UserNotifications, the real settings file, or the real log.
final class LowDiskMonitorTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    /// A fake world. The notice does not answer until the test calls `finish`, so the test can check the busy flag in between.
    private final class World {
        var limit: Int? = 10
        var free: Int64? = 4_000_000_000
        var now: Date
        var stored: Date?
        var saves = 0
        var canSave = true
        var calendar: Calendar
        var asked: [(String, String)] = []
        var pending: [(NoticeOutcome) -> Void] = []
        var diskReads = 0
        init(now: Date, calendar: Calendar) { self.now = now; self.calendar = calendar }

        func monitor() -> LowDiskMonitor {
            LowDiskMonitor(limitGB: { self.limit }, freeBytes: { self.diskReads += 1; return self.free }, now: { self.now },
                           lastAlert: { self.stored },
                           saveAlert: { self.saves += 1; if self.canSave { self.stored = $0 } },
                           show: { t, b, done in self.asked.append((t, b)); self.pending.append(done) },
                           calendar: { self.calendar })
        }
        func finish(_ outcome: NoticeOutcome, file: StaticString = #filePath, line: UInt = #line) {
            guard !pending.isEmpty else { XCTFail("no notice is waiting", file: file, line: line); return }
            pending.removeFirst()(outcome)
        }
    }

    private func world(_ day: Int = 5, hour: Int = 9) -> World { World(now: date(day, hour: hour), calendar: utc) }

    private func withTestLog(_ body: (URL) throws -> Void) throws {
        let box = try Sandbox()
        let log = box.home.appendingPathComponent("test.log")
        Log.fileURL = log
        defer { Log.fileURL = TestLog.url }
        try body(log)
    }

    private func logText(_ url: URL) -> String {
        Log.flush()
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: (a) The busy flag

    func testASecondCheckWaitsWhileANoticeIsOnItsWay() {
        let w = world()
        let m = w.monitor()
        m.check()
        XCTAssertTrue(m.busy)
        m.check()
        m.check()
        XCTAssertEqual(w.asked.count, 1, "one notice at a time")
        w.finish(.shown)
        XCTAssertFalse(m.busy)
    }

    func testTheBusyFlagIsFreeAfterEveryEnd() {
        for outcome in [NoticeOutcome.shown, .permissionNotAsked, .permissionDenied, .unavailable] {
            let w = world()
            let m = w.monitor()
            m.check()
            XCTAssertTrue(m.busy, "\(outcome)")
            w.finish(outcome)
            XCTAssertFalse(m.busy, "\(outcome)")
            if outcome != .shown {
                m.check()
                XCTAssertEqual(w.asked.count, 2, "after \(outcome) the next check can ask again")
                w.finish(.shown)
            }
        }
    }

    func testNoBusyFlagWhenNothingIsAsked() {
        let w = world()
        let m = w.monitor()
        w.limit = nil
        m.check()
        w.limit = 10
        w.free = nil
        m.check()
        w.free = 10_000_000_000
        m.check()
        XCTAssertFalse(m.busy)
        XCTAssertTrue(w.asked.isEmpty)
    }

    // MARK: (b) The day is saved only after a real notice

    func testTheDayIsSavedOnlyWhenTheNoticeWasShown() {
        for outcome in [NoticeOutcome.permissionNotAsked, .permissionDenied, .unavailable] {
            let w = world()
            let m = w.monitor()
            m.check()
            XCTAssertEqual(w.saves, 0, "\(outcome): not saved while the notice is on its way")
            w.finish(outcome)
            XCTAssertEqual(w.saves, 0, "\(outcome): not saved when the center refused or failed")
            XCTAssertNil(w.stored)
        }
        let w = world()
        let m = w.monitor()
        m.check()
        XCTAssertEqual(w.saves, 0, "not saved before the notice is shown")
        w.finish(.shown)
        XCTAssertEqual(w.saves, 1)
        XCTAssertEqual(w.stored, date(5, hour: 9), "the time of the check")
    }

    func testASecondCheckInTheSameDayDoesNotNotifyAgain() {
        let w = world()
        let m = w.monitor()
        m.check()
        w.finish(.shown)
        w.now = date(5, hour: 23)
        m.check()
        XCTAssertEqual(w.asked.count, 1)
        w.now = date(6, hour: 1)
        m.check()
        XCTAssertEqual(w.asked.count, 2, "next day")
    }

    func testADayThatChangedBecauseOfTheTimeZoneFollowsTheNewZone() {
        var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var la = Calendar(identifier: .gregorian); la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Tokyo: Nov 6 05:00 and Nov 6 18:00 (one day). Los Angeles: Nov 5 12:00 and Nov 6 01:00 (two days).
        let first = utc.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 20))!
        let second = utc.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9))!
        let w = World(now: first, calendar: tokyo)
        let m = w.monitor()
        m.check()
        w.finish(.shown)
        w.now = second
        m.check()
        XCTAssertEqual(w.asked.count, 1, "same day in Tokyo")
        w.calendar = la   // the Mac moves to Los Angeles
        m.check()
        XCTAssertEqual(w.asked.count, 2, "a new day in Los Angeles")
        w.finish(.shown)
        m.check()
        XCTAssertEqual(w.asked.count, 2, "and once only in that day")
    }

    // MARK: (c) No permission

    func testNeverAskedWarnsOnceInTheLogAndShowsNothing() throws {
        try withTestLog { log in
            let w = world()
            let m = w.monitor()
            for _ in 0..<4 { m.check(); w.finish(.permissionNotAsked) }
            let text = logText(log)
            XCTAssertEqual(text.components(separatedBy: "WARN").count - 1, 1, "one WARN line in the run, not one for each check")
            XCTAssertTrue(text.contains("never asked"), "the line says why")
            XCTAssertFalse(text.contains("alert shown"))
            XCTAssertNil(w.stored, "no day saved")
        }
    }

    func testDeniedWarnsOnceWithItsOwnReason() throws {
        try withTestLog { log in
            let w = world()
            let m = w.monitor()
            for _ in 0..<4 { m.check(); w.finish(.permissionDenied) }
            let text = logText(log)
            XCTAssertEqual(text.components(separatedBy: "WARN").count - 1, 1)
            XCTAssertTrue(text.contains("denied"))
        }
    }

    func testAnswersDoNotStartAChainOfRetries() {
        let w = world()
        let m = w.monitor()
        m.check()
        w.finish(.permissionNotAsked)
        XCTAssertEqual(w.asked.count, 1, "the answer alone starts no new try")
        XCTAssertTrue(w.pending.isEmpty)
        XCTAssertFalse(m.busy)
    }

    // MARK: (d) The free space cannot be read

    func testNoFreeValueGivesNoAlert() {
        let w = world()
        w.free = nil
        let m = w.monitor()
        m.check()
        XCTAssertTrue(w.asked.isEmpty)
        XCTAssertFalse(m.busy)
        XCTAssertEqual(w.saves, 0)
    }

    // MARK: (e) The day cannot be saved

    func testAFailedSaveDoesNotCauseARepeatInTheSameRun() {
        let w = world()
        w.canSave = false
        let m = w.monitor()
        m.check()
        w.finish(.shown)
        XCTAssertNil(w.stored, "the write did not work")
        w.now = date(5, hour: 10)
        m.check()
        m.check()
        XCTAssertEqual(w.asked.count, 1, "no repeat notice in the same day")
        w.now = date(6, hour: 10)
        m.check()
        XCTAssertEqual(w.asked.count, 2, "the next day is a new day")
    }
}
