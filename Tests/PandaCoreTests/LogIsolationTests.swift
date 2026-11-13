import XCTest
@testable import PandaCore

/// No test may write the REAL log (`~/Library/Logs/TrashPanda/trashpanda.log`) or the real home folder, however the tests are started.
/// `Log.fileURL` picks a temp file when a `.xctest` bundle is loaded, so a run like `swift test --filter AppQuitterTests` (no `Sandbox`) is safe.
///
/// The real log path and the real Trash are built from parts and read only. This file has no call that writes, moves, or deletes.
private enum RealLog {
    /// The real log file of the app, as a path. It is only read (size and bytes), never written.
    static let path = NSString(string: "~/Library/Logs/TrashPanda/trashpanda.log").expandingTildeInPath
    static let folder = NSString(string: "~/Library/Logs/TrashPanda").expandingTildeInPath
    static let trash = NSString(string: "~/.Trash").expandingTildeInPath

    /// The size of the real log, or nil when the file does not exist.
    static func size() -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    /// The names in the real Trash (a read-only listing), or nil when it cannot be listed.
    static func trashNames() -> Set<String>? {
        (try? FileManager.default.contentsOfDirectory(atPath: trash)).map(Set.init)
    }

    /// The state at the FIRST test of the bundle (the `AAA` class sets it up before its first test). It is a lazy static, so
    /// the first access decides. A run with `--filter ZZZ` takes it late, but then no other test ran before it either.
    struct Baseline {
        let size: Int64?
        let trashNames: Set<String>?
    }
    static let baseline = Baseline(size: size(), trashNames: trashNames())

    /// Text that only a test run writes: a path in the temp folder, a Sandbox path, the example user, or the test log name.
    static var markers: [String] {
        let temp = NSTemporaryDirectory().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ["/" + temp, "/private/" + temp, "/panda-", "/Users/example", "trashpanda-tests"]
    }

    /// The bytes after `offset` in the real log, as text. Only these bytes are read.
    static func addedText(after offset: Int64) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch { return "" }
    }

    static func hasMarker(_ text: String) -> Bool { markers.contains { text.contains($0) } }

    /// Names in the Trash that look like a test fixture.
    static func looksLikeFixture(_ name: String) -> Bool {
        ["panda-", "trashpanda-tests", "example"].contains { name.lowercased().contains($0) }
    }
}

/// The name sorts first. It calls nothing but `Log` and `RealLog`, and it makes no `Sandbox`.
final class AAALogIsolationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = RealLog.baseline   // the first test of the bundle takes the baseline
    }

    func testTheLogFileIsNotTheRealLogWhenNoSandboxExists() throws {
        XCTAssertTrue(Log.isRunningUnderXCTest)
        XCTAssertFalse(Log.fileURL.path.hasPrefix(RealLog.folder), "the log of a test run must not be the real log: \(Log.fileURL.path)")
        XCTAssertNotEqual(Log.fileURL.standardizedFileURL.path, RealLog.path)
        let temp = NSTemporaryDirectory()
        let path = Log.defaultFileURL().path
        XCTAssertTrue(path.hasPrefix(temp) || path.hasPrefix("/private" + temp), "the default under a test is in the temp folder: \(path)")
        XCTAssertTrue(path.hasSuffix("/trashpanda-tests/trashpanda-tests.log"), "the temp log is in a private folder: \(path)")
    }

    func testTheDefaultOfTheRealAppIsUnchanged() {
        XCTAssertTrue(Log.defaultFileURL(underTest: false).path.hasSuffix("/Library/Logs/TrashPanda/trashpanda.log"))
        XCTAssertEqual(Log.defaultFileURL(underTest: false).path, RealLog.path)
    }

    func testTheChooserUsesTheRealPathWhenNoTestBundleIsLoaded() {
        // The pure rule, with injected inputs. The environment variable of XCTest is not an input: only the loaded bundle counts.
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(Log.chooseDefault(underTest: false, home: home, temp: "/tmp/t/").path, "/Users/someone/Library/Logs/TrashPanda/trashpanda.log")
        XCTAssertEqual(Log.chooseDefault(underTest: true, home: home, temp: "/tmp/t/").path, "/tmp/t/trashpanda-tests/trashpanda-tests.log")
        // A set `XCTestConfigurationFilePath` does not change the answer of the real app, because the rule does not read it.
        XCTAssertEqual(Log.chooseDefault(underTest: false, home: home, temp: "/tmp/t/").path, "/Users/someone/Library/Logs/TrashPanda/trashpanda.log")
    }

    func testTheTempLogHasAPrivateFolder() throws {
        let url = Log.defaultFileURL(underTest: true)
        Log.info("log isolation test line trashpanda-tests")
        // The log writes on its own queue. Wait until the file exists.
        let fm = FileManager.default
        for _ in 0..<50 where !fm.fileExists(atPath: Log.fileURL.path) { Thread.sleep(forTimeInterval: 0.05) }
        guard Log.fileURL == url else { return }   // another test set its own file
        let folder = url.deletingLastPathComponent()
        let folderMode = (try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(folderMode, 0o700)
        let fileMode = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(fileMode, 0o600)
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

/// The name sorts last. If a test wrote the real log, the added bytes of the log show a mark of the test run.
/// The app of the owner may run during the test run and write the real log too. That is not a test failure: then this test skips.
final class ZZZRealLogUnchangedTests: XCTestCase {
    func testTheRealLogFileDidNotChangeDuringTheTestRun() throws {
        let baseline = RealLog.baseline
        let trashNote = try checkTrash(baseline)
        guard let before = baseline.size else {
            throw XCTSkip("the real log file did not exist at the start of the test run")
        }
        guard let now = RealLog.size() else {
            throw XCTSkip("the real log file is gone now. It was rotated or removed, so it cannot be compared. \(trashNote)")
        }
        if now < before {
            throw XCTSkip("the real log is smaller than at the start (\(now) < \(before) bytes). It was rotated, so it cannot be compared. \(trashNote)")
        }
        if now == before { return }
        // The log grew. Read only the added bytes. A mark of the test run means a test wrote it.
        let added = RealLog.addedText(after: before)
        if RealLog.hasMarker(added) {
            XCTFail("The real log got new lines with a mark of the test run. A test wrote it. (\(now - before) new bytes)")
            return
        }
        throw XCTSkip("the real log grew by \(now - before) bytes, and the new lines have no mark of the test run. The running Trash Panda app wrote them, not a test. \(trashNote)")
    }

    /// Fails when the real Trash got a new item that looks like a test fixture. Other changes are only a note.
    private func checkTrash(_ baseline: RealLog.Baseline) throws -> String {
        guard let before = baseline.trashNames, let now = RealLog.trashNames() else { return "" }
        if before.count == now.count && before == now { return "" }
        let added = now.subtracting(before)
        let fixtures = added.filter(RealLog.looksLikeFixture)
        XCTAssertTrue(fixtures.isEmpty, "The real Trash got items that look like a test fixture: \(fixtures.sorted())")
        return "(The real Trash changed: \(before.count) to \(now.count) items. No new name looks like a test fixture.)"
    }
}
