import XCTest
@testable import PandaCore

/// The low-disk alert (#34). No test reads the real disk, the real clock, or shows a real notification.
final class LowDiskAlertTests: XCTestCase {
    private let gb = LowDiskAlert.bytesPerGB
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    // MARK: The decision

    func testItIsOffByDefault() {
        XCTAssertNil(Config().lowDiskAlertGB)
        XCTAssertNil(Config.parseSettings("").lowDiskAlertGB)
        XCTAssertFalse(LowDiskAlert.shouldAlert(limitGB: nil, freeBytes: 0, lastAlert: nil, now: date(1), calendar: calendar))
    }

    func testBelowAtAndAboveTheLimit() {
        func alert(_ free: Int64) -> Bool {
            LowDiskAlert.shouldAlert(limitGB: 10, freeBytes: free, lastAlert: nil, now: date(1), calendar: calendar)
        }
        XCTAssertTrue(alert(10 * gb - 1), "below")
        XCTAssertFalse(alert(10 * gb), "at the limit is not below")
        XCTAssertFalse(alert(10 * gb + 1), "above")
        XCTAssertTrue(alert(0))
    }

    func testOneAlertInACalendarDay() {
        func alert(last: Date?, now: Date) -> Bool {
            LowDiskAlert.shouldAlert(limitGB: 10, freeBytes: gb, lastAlert: last, now: now, calendar: calendar)
        }
        XCTAssertTrue(alert(last: nil, now: date(5)))
        XCTAssertFalse(alert(last: date(5, hour: 1), now: date(5, hour: 23)), "same day")
        XCTAssertFalse(alert(last: date(5, hour: 23), now: date(5, hour: 23)))
    }

    func testTheNextDayAlertsAgain() {
        XCTAssertTrue(LowDiskAlert.shouldAlert(limitGB: 10, freeBytes: gb, lastAlert: date(5, hour: 23), now: date(6, hour: 0), calendar: calendar))
        XCTAssertTrue(LowDiskAlert.shouldAlert(limitGB: 10, freeBytes: gb, lastAlert: date(5), now: date(9), calendar: calendar))
    }

    func testALimitOutsideTheRangeNeverAlerts() {
        XCTAssertFalse(LowDiskAlert.shouldAlert(limitGB: 0, freeBytes: 0, lastAlert: nil, now: date(1), calendar: calendar))
        XCTAssertFalse(LowDiskAlert.shouldAlert(limitGB: -5, freeBytes: 0, lastAlert: nil, now: date(1), calendar: calendar))
    }

    // MARK: The checker, with a fake clock, a fake disk, and a fake notice

    private final class World {
        var limit: Int? = 10
        var free: Int64? = 4_000_000_000
        var now: Date
        var last: Date?
        var shown: [(String, String)] = []
        var diskReads = 0
        var noticeWorks = true
        init(now: Date) { self.now = now }
        func checker(_ calendar: Calendar) -> LowDiskChecker {
            LowDiskChecker(limitGB: { self.limit }, freeBytes: { self.diskReads += 1; return self.free }, now: { self.now },
                           lastAlert: { self.last }, saveAlert: { self.last = $0 }, notify: { t, b, done in self.shown.append((t, b)); done(self.noticeWorks) },
                           calendar: calendar)
        }
    }

    private func run(_ checker: LowDiskChecker) -> Bool {
        var result = false
        checker.run { result = $0 }
        return result
    }

    func testTheCheckerShowsOneNoticeAndRemembersTheDay() {
        let world = World(now: date(5, hour: 9))
        let checker = world.checker(calendar)
        XCTAssertTrue(run(checker))
        XCTAssertEqual(world.shown.count, 1)
        XCTAssertEqual(world.last, date(5, hour: 9))
        world.now = date(5, hour: 15)
        XCTAssertFalse(run(checker), "same day")
        XCTAssertEqual(world.shown.count, 1)
        world.now = date(6, hour: 9)
        XCTAssertTrue(run(checker), "next day")
        XCTAssertEqual(world.shown.count, 2)
    }

    func testTheCheckerDoesNothingWhenOffOrWhenSpaceIsEnough() {
        let world = World(now: date(5))
        let checker = world.checker(calendar)
        world.limit = nil
        XCTAssertFalse(run(checker))
        XCTAssertEqual(world.diskReads, 0, "when it is off, the disk is not read")
        world.limit = 10
        world.free = 10 * gb
        XCTAssertFalse(run(checker))
        XCTAssertTrue(world.shown.isEmpty)
        XCTAssertNil(world.last, "no alert, no saved day")
    }

    func testTheCheckerDoesNothingWhenTheFreeSpaceCannotBeRead() {
        let world = World(now: date(5))
        world.free = nil
        XCTAssertFalse(run(world.checker(calendar)))
        XCTAssertTrue(world.shown.isEmpty)
    }

    func testAFailedNoticeDoesNotUseUpTheDay() {
        let world = World(now: date(5, hour: 9))
        let checker = world.checker(calendar)
        world.noticeWorks = false   // permission denied, no app bundle, or a failed show
        XCTAssertFalse(run(checker))
        XCTAssertNil(world.last, "nothing was shown, so the day is not saved")
        world.now = date(5, hour: 10)
        world.noticeWorks = true
        XCTAssertTrue(run(checker), "the next check can alert on the same day")
        XCTAssertEqual(world.last, date(5, hour: 10))
        XCTAssertFalse(run(checker), "now the day is used")
    }

    func testTheDayBoundaryFollowsTheCalendarTimeZone() {
        var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var la = Calendar(identifier: .gregorian); la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // The same two moments. Tokyo: Nov 6 05:00 and Nov 6 18:00 (one day). Los Angeles: Nov 5 12:00 and Nov 6 01:00 (two days).
        let first = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 20))!
        let second = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9))!
        XCTAssertFalse(LowDiskAlert.shouldAlert(limitGB: 10, freeBytes: gb, lastAlert: first, now: second, calendar: tokyo))
        XCTAssertTrue(LowDiskAlert.shouldAlert(limitGB: 10, freeBytes: gb, lastAlert: first, now: second, calendar: la))
        XCTAssertTrue(LowDiskAlert.shouldAlert(limitGB: 10, freeBytes: gb, lastAlert: first, now: second, calendar: calendar))
    }

    func testAMissingFreeValueIsNotZeroBytes() {
        XCTAssertNil(DiskUsage.alertFreeBytes(total: 500_000_000_000, important: nil))
        XCTAssertNil(DiskUsage.alertFreeBytes(total: nil, important: 5))
        XCTAssertNil(DiskUsage.alertFreeBytes(total: 0, important: 5))
        XCTAssertEqual(DiskUsage.alertFreeBytes(total: 500_000_000_000, important: 7), 7)
        XCTAssertEqual(DiskUsage.alertFreeBytes(total: 500_000_000_000, important: 0), 0, "a real zero is a real zero")
    }

    func testABadValueIsWarnedOnceInTheLog() throws {
        let box = try Sandbox()
        let log = box.home.appendingPathComponent("test.log")
        Log.fileURL = log
        defer { Log.fileURL = TestLog.url }
        Config.resetLowDiskWarning()
        let file = box.home.appendingPathComponent(".config/trashpanda/settings")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "low_disk_alert_gb = lots\n".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<3 { XCTAssertNil(Config.readLowDiskAlertGB(home: box.home)) }
        Log.flush()
        func warnings() -> Int { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").components(separatedBy: "WARN").count - 1 }
        XCTAssertEqual(warnings(), 1)
        try "low_disk_alert_gb = many\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(Config.readLowDiskAlertGB(home: box.home))
        Log.flush()
        XCTAssertEqual(warnings(), 2, "a different bad value warns again")
    }

    // MARK: The setting

    func testSettingValues() {
        XCTAssertEqual(Config.parseSettings("low_disk_alert_gb = 20").lowDiskAlertGB, 20)
        XCTAssertEqual(Config.parseSettings("low_disk_alert_gb=5\n").lowDiskAlertGB, 5)
        XCTAssertNil(Config.parseSettings("low_disk_alert_gb = off").lowDiskAlertGB)
        XCTAssertNil(Config.parseSettings("low_disk_alert_gb = OFF").lowDiskAlertGB)
        XCTAssertTrue(Config.parseSettings("low_disk_alert_gb = off").warnings.isEmpty)
        XCTAssertTrue(Config.parseSettings("low_disk_alert_gb = 20").warnings.isEmpty)
    }

    func testAnInvalidValueIsOffWithAWarning() {
        for bad in ["abc", "0", "-5", "1.5", "10GB", "20000", ""] {
            let parsed = Config.parseSettings("low_disk_alert_gb = \(bad)")
            if bad.isEmpty { continue }   // a line with no value is an unknown line, not this setting
            XCTAssertNil(parsed.lowDiskAlertGB, bad)
            XCTAssertEqual(parsed.warnings.count, 1, bad)
            XCTAssertTrue(parsed.warnings[0].hasPrefix("low_disk_alert_gb"), bad)
        }
    }

    func testAnInvalidValueGoesToTheLog() throws {
        let box = try Sandbox()
        let log = box.home.appendingPathComponent("test.log")
        Log.fileURL = log
        defer { Log.fileURL = TestLog.url }
        let file = box.home.appendingPathComponent(".config/trashpanda/settings")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "low_disk_alert_gb = lots\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(Config.readLowDiskAlertGB(home: box.home))
        Log.flush()
        XCTAssertTrue(((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("WARN"))
    }

    func testWritingTheSettingKeepsTheOtherLines() throws {
        let box = try Sandbox()
        XCTAssertNil(Config.readLowDiskAlertGB(home: box.home), "no file")
        XCTAssertTrue(Config.setLowDiskAlertGB(10, home: box.home))
        XCTAssertEqual(Config.readLowDiskAlertGB(home: box.home), 10)
        let file = box.home.appendingPathComponent(".config/trashpanda/settings")
        try "# my note\nstale_days = 14\ndelete_mode = trash\nlow_disk_alert_gb = 10\nlow_disk_alert_gb = 99\n"
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(Config.setLowDiskAlertGB(50, home: box.home))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# my note\nstale_days = 14\ndelete_mode = trash\nlow_disk_alert_gb = 50\n")
        XCTAssertTrue(Config.setLowDiskAlertGB(nil, home: box.home))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# my note\nstale_days = 14\ndelete_mode = trash\nlow_disk_alert_gb = off\n")
        XCTAssertNil(Config.readLowDiskAlertGB(home: box.home))
        XCTAssertEqual(Config.readDeleteMode(home: box.home), .trash)
        XCTAssertTrue(Config.setDeleteMode(.permanent, home: box.home))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("low_disk_alert_gb = off"))
    }

    // MARK: The menu

    func testTheSettingsMenuHasTheChoicesAndTheCheck() throws {
        func choices(_ limit: Int?) throws -> [MenuModel.Row] {
            var input = MenuInput(result: nil, disk: DiskUsage(total: 1_000_000_000, free: 500_000_000), scanning: false, cleaning: false,
                                  running: RunningSnapshot(apps: []), staleDays: 30)
            input.lowDiskAlertGB = limit
            let settings = try XCTUnwrap(MenuModel.make(input).rows.first { $0.title == "Settings" }?.submenu?.rows)
            return try XCTUnwrap(settings.first { $0.title == LowDiskText.settingTitle }?.submenu?.rows)
        }
        XCTAssertEqual(try choices(nil).map(\.title), ["Off", "5 GB", "10 GB", "20 GB", "50 GB"])
        XCTAssertEqual(try choices(nil).map(\.action), [nil, 5, 10, 20, 50].map { MenuModel.Action.setLowDiskAlert(gb: $0) })
        XCTAssertEqual(try choices(nil).map(\.checked), [true, false, false, false, false])
        XCTAssertEqual(try choices(20).map(\.checked), [false, false, false, true, false])
    }

    // MARK: Words

    func testTheTextIsShortAndSafe() {
        let body = LowDiskText.body(freeBytes: 4_200_000_000)
        XCTAssertEqual(LowDiskText.title, "Your disk is almost full")
        XCTAssertEqual(body, "Only 4.2 GB is free on your Mac. Open Trash Panda to see what you can clean.")
        for text in [LowDiskText.title, body, LowDiskText.settingTooltip] {
            XCTAssertFalse(text.contains("/"), "no path: \(text)")
            for word in ["delete", "remove", "erase", "wipe"] { XCTAssertFalse(text.lowercased().contains(word), "\(word) in \(text)") }
        }
        for sentence in body.split(separator: ".") { XCTAssertLessThanOrEqual(sentence.split(separator: " ").count, 20) }
        XCTAssertEqual(LowDiskText.choiceTitle(nil), "Off")
        XCTAssertEqual(LowDiskText.choiceTitle(10), "10 GB")
    }
}
