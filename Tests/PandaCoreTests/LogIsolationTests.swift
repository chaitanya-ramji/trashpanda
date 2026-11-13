import XCTest
@testable import PandaCore

/// No test may write the REAL log (`~/Library/Logs/TrashPanda/trashpanda.log`) or the real home folder, however the tests are started.
/// `Log.fileURL` picks a temp file when XCTest is present, so a run like `swift test --filter AppQuitterTests` (no `Sandbox`) is safe.
///
/// The real log path is built from parts and read only. This file has no call that writes, moves, or deletes.
private enum RealLog {
    /// The real log file of the app, as a path. It is only read (size and time), never written.
    static let path = NSString(string: "~/Library/Logs/TrashPanda/trashpanda.log").expandingTildeInPath
    static let folder = NSString(string: "~/Library/Logs/TrashPanda").expandingTildeInPath

    /// Size and modification time, or nil when the file does not exist.
    static func state() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let time = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size) \(time)"
    }

    /// Taken the first time that any of these tests runs (the class `AAA...` runs first), before other tests can log.
    static let before: String? = state()
}

/// The name sorts first. It calls nothing but `Log` and `RealLog`, and it makes no `Sandbox`.
final class AAALogIsolationTests: XCTestCase {
    func testTheLogFileIsNotTheRealLogWhenNoSandboxExists() throws {
        _ = RealLog.before
        XCTAssertTrue(Log.isRunningUnderXCTest)
        XCTAssertFalse(Log.fileURL.path.hasPrefix(RealLog.folder), "the log of a test run must not be the real log: \(Log.fileURL.path)")
        XCTAssertNotEqual(Log.fileURL.standardizedFileURL.path, RealLog.path)
        XCTAssertTrue(Log.defaultFileURL().path.hasPrefix(NSTemporaryDirectory()) || Log.defaultFileURL().path.hasPrefix("/private" + NSTemporaryDirectory()),
                      "the default under a test is a temp file: \(Log.defaultFileURL().path)")
    }

    func testTheDefaultOfTheRealAppIsUnchanged() {
        XCTAssertTrue(Log.defaultFileURL(underTest: false).path.hasSuffix("/Library/Logs/TrashPanda/trashpanda.log"))
        XCTAssertEqual(Log.defaultFileURL(underTest: false).path, RealLog.path)
    }

    func testOnlyHOMEDoesNotIsolateAProgram() {
        // On this macOS, HOME alone leaves `NSHomeDirectory()` at the real home folder. Only CFFIXED_USER_HOME moves it.
        // This test does not start a program and does not touch the real home. It tests the rule that the helper keeps.
        let fake = URL(fileURLWithPath: "/tmp/fake-home-for-a-test")
        XCTAssertFalse(FakeHomeEnvironment.isIsolated(["HOME": fake.path], home: fake), "HOME alone is not isolated")
        XCTAssertFalse(FakeHomeEnvironment.isIsolated(["CFFIXED_USER_HOME": fake.path], home: fake))
        XCTAssertFalse(FakeHomeEnvironment.isIsolated(["HOME": fake.path, "CFFIXED_USER_HOME": "/elsewhere"], home: fake))
        let env = FakeHomeEnvironment.environment(for: fake, base: ["PATH": "/usr/bin", "HOME": "/real/home"])
        XCTAssertEqual(env["HOME"], fake.path)
        XCTAssertEqual(env["CFFIXED_USER_HOME"], fake.path)
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertTrue(FakeHomeEnvironment.isIsolated(env, home: fake))
    }
}

/// The name sorts last. If the real log changed in size or time while the tests ran, a test wrote it.
final class ZZZRealLogUnchangedTests: XCTestCase {
    func testTheRealLogFileDidNotChangeDuringTheTestRun() throws {
        let before = RealLog.before
        try XCTSkipIf(before == nil, "the real log file does not exist on this Mac")
        XCTAssertEqual(RealLog.state(), before,
                       "The real log changed during the test run. A test wrote it. (If the Trash Panda app runs on this Mac, quit it and run again.)")
    }
}
