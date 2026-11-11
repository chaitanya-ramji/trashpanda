import XCTest
@testable import PandaCore

final class OldLogsTests: XCTestCase {
    private let mb = 1_500_000
    private func scanner(_ box: Sandbox, keep: [String] = []) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(keep: keep), useOwnerTools: false)
    }
    private func cleaner(_ s: DiskScanner) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func item(_ box: Sandbox, _ kind: OldLogs.Kind) -> Finding? { scanner(box).scanLogs().first { $0.id == kind.findingID } }
    private func clean(_ box: Sandbox, _ kind: OldLogs.Kind) throws -> CleanReport {
        let s = scanner(box)
        return cleaner(s).clean([try XCTUnwrap(item(box, kind))])
    }

    // MARK: The age rule

    func testOnlyFilesOlderThanThirtyDaysCount() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/new.log", bytes: mb, age: 5)
        try box.file("Library/Logs/almost.log", bytes: mb, age: 29)
        try box.file("Library/Logs/old.log", bytes: 2 * mb, age: 31)
        let f = try XCTUnwrap(item(box, .logs))
        XCTAssertTrue(f.bytes >= 2 * mb && f.bytes < 3 * mb, "\(f.bytes)")
        XCTAssertTrue(f.location.contains("1 file older than 30 days"), f.location)
    }

    func testTheLimitIsExactlyThirtyDays() throws {
        let box = try Sandbox()
        let url = try box.file("Library/Logs/edge.log", bytes: mb)
        let now = Date()
        func set(_ days: Double) {
            try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
        }
        set(30)
        XCTAssertEqual(OldLogs.entries(.logs, home: box.home, now: now).count, 1, "30 days old counts")
        set(29.99)
        XCTAssertTrue(OldLogs.entries(.logs, home: box.home, now: now).isEmpty)
    }

    // MARK: The two groups

    func testLogsAndCrashReportsAreTwoReviewItems() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/fsck_hfs.log", bytes: mb, age: 60)
        try box.file("Library/Logs/Homebrew/gh/01.log", bytes: mb, age: 60)
        try box.file("Library/Logs/DiagnosticReports/App-2026.ips", bytes: 2 * mb, age: 60)
        try box.file("Library/Logs/CrashReporter/MobileDevice/phone/x.ips", bytes: 2 * mb, age: 60)
        let found = scanner(box).scanLogs()
        XCTAssertEqual(Set(found.map(\.id)), ["logs.logs", "logs.crashReports"])
        XCTAssertTrue(found.allSatisfy { $0.tier == .review && $0.ecosystem == .logs && $0.owner == nil })
        let logs = try XCTUnwrap(found.first { $0.id == "logs.logs" })
        let crash = try XCTUnwrap(found.first { $0.id == "logs.crashReports" })
        XCTAssertTrue(logs.bytes >= 2 * mb && logs.bytes < 3 * mb && logs.title == "Old logs")
        XCTAssertTrue(crash.bytes >= 4 * mb && crash.bytes < 5 * mb && crash.title == "Old crash reports")
    }

    func testNeverInTheOneClickTotal() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/a.log", bytes: 3 * mb, age: 90)
        let result = scanner(box).scan()
        XCTAssertEqual(result.reclaimable, 0)
        XCTAssertTrue(result.reviewable >= 3 * mb)
    }

    func testNothingWhenThereIsNothing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanLogs().isEmpty, "no Logs folder")
        try box.file("Library/Logs/new.log", bytes: mb, age: 1)
        XCTAssertTrue(scanner(box).scanLogs().isEmpty, "only new files")
    }

    // MARK: What is never touched

    func testTheLogOfTrashPandaIsNeverListed() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/TrashPanda/trashpanda.log", bytes: 3 * mb, age: 90)
        try box.file("Library/Logs/trashpanda/old.log", bytes: 3 * mb, age: 90)
        try box.file("Library/Logs/TRASHPANDA/other.log", bytes: 3 * mb, age: 90)
        XCTAssertTrue(scanner(box).scanLogs().isEmpty)
    }

    func testTheConfiguredLogFileIsNeverListed() throws {
        let box = try Sandbox()
        let own = try box.file("Library/Logs/custom-place/mylog.txt", bytes: 3 * mb, age: 90)
        let saved = Log.fileURL
        Log.fileURL = own
        defer { Log.fileURL = saved }
        XCTAssertTrue(scanner(box).scanLogs().isEmpty)
    }

    func testLinksAndFoldersAreNeverListed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/big.log", bytes: 5 * mb, age: 90)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library/Logs/OldFolder"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86_400)],
                                              ofItemAtPath: box.home.appendingPathComponent("Library/Logs/OldFolder").path)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Logs/link.log"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere/big.log"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Logs/linkdir"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(scanner(box).scanLogs().isEmpty)
    }

    func testALogsFolderThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/big.log", bytes: 5 * mb, age: 90)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Logs"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(scanner(box).scanLogs().isEmpty)
    }

    func testTheKeepListIsHonored() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/Keep/a.log", bytes: 3 * mb, age: 90)
        try box.file("Library/Logs/Other/b.log", bytes: 3 * mb, age: 90)
        let s = scanner(box, keep: [box.home.appendingPathComponent("Library/Logs/Keep").path])
        XCTAssertEqual(s.scanLogs().first?.location.contains("1 file"), true)
        _ = try cleaner(s).clean([try XCTUnwrap(s.scanLogs().first)])
        XCTAssertTrue(exists(box, "Library/Logs/Keep/a.log"))
        XCTAssertFalse(exists(box, "Library/Logs/Other/b.log"))
    }

    // MARK: The clean

    func testACleanRemovesOnlyOldFilesOfTheChosenGroup() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/old.log", bytes: 2 * mb, age: 90)
        try box.file("Library/Logs/App/nested/old2.log", bytes: 2 * mb, age: 40)
        try box.file("Library/Logs/new.log", bytes: 2 * mb, age: 3)
        try box.file("Library/Logs/DiagnosticReports/crash.ips", bytes: 2 * mb, age: 90)
        try box.file("Library/Logs/TrashPanda/trashpanda.log", bytes: 2 * mb, age: 90)
        let report = try clean(box, .logs)
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(report.freed >= 4 * mb && report.freed < 5 * mb, "\(report.freed)")
        XCTAssertFalse(exists(box, "Library/Logs/old.log"))
        XCTAssertFalse(exists(box, "Library/Logs/App/nested/old2.log"))
        for kept in ["Library/Logs/new.log", "Library/Logs/DiagnosticReports/crash.ips", "Library/Logs/TrashPanda/trashpanda.log"] {
            XCTAssertTrue(exists(box, kept), kept)
        }
        XCTAssertTrue(exists(box, "Library/Logs/App/nested"), "Folders are never removed")
        XCTAssertEqual(scanner(box).remainingBytes(of: Finding(id: "logs.logs", ecosystem: .logs, title: "", location: "", bytes: 0,
                                                              tier: .review, rebuild: .never, action: .removeOldLogs(.logs))), 0)
    }

    func testCrashReportsAreCleanedWithoutTouchingLogs() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/old.log", bytes: 2 * mb, age: 90)
        try box.file("Library/Logs/DiagnosticReports/crash.ips", bytes: 2 * mb, age: 90)
        try box.file("Library/Logs/DiagnosticReports/fresh.ips", bytes: 2 * mb, age: 2)
        let report = try clean(box, .crashReports)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Library/Logs/DiagnosticReports/crash.ips"))
        XCTAssertTrue(exists(box, "Library/Logs/DiagnosticReports/fresh.ips"))
        XCTAssertTrue(exists(box, "Library/Logs/old.log"))
    }

    func testAFileThatBecameNewIsKept() throws {
        let box = try Sandbox()
        let url = try box.file("Library/Logs/busy.log", bytes: 2 * mb, age: 90)
        let s = scanner(box)
        let f = try XCTUnwrap(s.scanLogs().first)
        try Data(repeating: 3, count: 2 * mb).write(to: url)           // an app wrote to it after the scan
        let report = cleaner(s).clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(box, "Library/Logs/busy.log"))
    }

    func testACleanFollowsNoLinks() throws {
        let box = try Sandbox()
        try box.file("elsewhere/precious.txt", bytes: mb, age: 90)
        try box.file("Library/Logs/old.log", bytes: 2 * mb, age: 90)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Logs/link.log"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere/precious.txt"))
        _ = try clean(box, .logs)
        XCTAssertTrue(exists(box, "elsewhere/precious.txt"))
        XCTAssertTrue(exists(box, "Library/Logs/link.log"), "A link is left alone")
    }

    func testPathRules() {
        let home = URL(fileURLWithPath: "/Users/x")
        func kind(_ p: String) -> OldLogs.Kind? { OldLogs.kind(of: URL(fileURLWithPath: "/Users/x/\(p)"), home: home) }
        XCTAssertEqual(kind("Library/Logs/a.log"), .logs)
        XCTAssertEqual(kind("Library/Logs/DiagnosticReports/a.ips"), .crashReports)
        XCTAssertEqual(kind("Library/Logs/diagnosticreports/a.ips"), .crashReports)
        XCTAssertEqual(kind("Library/Logs/CrashReporter/MobileDevice/p/a.ips"), .crashReports)
        XCTAssertNil(kind("Library/Logs/TrashPanda/trashpanda.log"))
        XCTAssertNil(kind("Library/Caches/a.log"))
        XCTAssertNil(kind("Library/Logs"))
        XCTAssertNil(kind("Library/LogsX/a.log"))
    }

    // MARK: The dialog

    func testTheDialogKeepsTheFilesByDefault() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/DiagnosticReports/crash.ips", bytes: 2 * mb, age: 90)
        let f = try XCTUnwrap(item(box, .crashReports))
        XCTAssertEqual(Confirmation.kind(of: f), .oldLogs)
        let c = Confirmation.forOne(f, staleDays: 30)
        XCTAssertEqual(c.title, "Delete these old log files?")
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertTrue(c.footer?.contains("30 days") == true && c.footer?.contains("log of Trash Panda") == true)
    }

    /// S-11 a. Library/Logs is a link to a folder inside the home. The folder behind it is not ours: nothing is deleted.
    func testALinkedLogsFolderIsNeverCleanedEvenWithAForgedFinding() throws {
        let box = try Sandbox()
        try box.file("Documents/real/old.log", bytes: 2 * mb, age: 90)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Logs"),
                                                   withDestinationURL: box.home.appendingPathComponent("Documents/real"))
        let forged = Finding(id: "logs.logs", ecosystem: .logs, title: "x", location: "../Documents/real", bytes: 1, tier: .review,
                             rebuild: .never, action: .removeOldLogs(.logs))
        let report = cleaner(scanner(box)).clean([forged])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertTrue(exists(box, "Documents/real/old.log"))
    }

    /// S-11 a. A folder of Logs becomes a link after the preview. The handler finds the file again, and refuses it.
    func testAFolderOfLogsThatBecameALinkAfterThePreviewIsRefused() throws {
        let box = try Sandbox()
        try box.file("Library/Logs/App/old.log", bytes: 2 * mb, age: 90)
        let s = scanner(box)
        let f = try XCTUnwrap(s.scanLogs().first)
        let c = cleaner(s)
        var swapped = false
        c.sizeOf = { url in
            if !swapped {
                swapped = true
                let dir = box.home.appendingPathComponent("Library/Logs/App")
                try? FileManager.default.moveItem(at: dir, to: box.home.appendingPathComponent("Library/Logs/App-moved"))
                try? FileManager.default.createSymbolicLink(at: dir, withDestinationURL: box.home.appendingPathComponent("Library/Logs/App-moved"))
            }
            return Sizer.size(of: url)
        }
        let report = c.clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertTrue(exists(box, "Library/Logs/App-moved/old.log"))
    }
}
