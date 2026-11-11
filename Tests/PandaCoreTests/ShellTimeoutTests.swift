import XCTest
@testable import PandaCore

/// Only scripts that these tests start are ever signalled.
final class ShellTimeoutTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var pidFile: String { dir.appendingPathComponent("pid").path }

    private func makeScript(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("tool.sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func scriptPid() -> Int32? {
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True while the process exists. Signal 0 sends nothing.
    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func testToolThatIgnoresTermIsKilled() throws {
        let tool = try makeScript("trap '' TERM\necho $$ > '\(pidFile)'\nwhile :; do sleep 0.2; done")
        let start = Date()
        let r = Shell.run(tool, [], timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(r.timedOut)
        XCTAssertGreaterThan(elapsed, 1 + Shell.killGrace - 0.2, "SIGTERM was ignored, so the grace time must pass")
        XCTAssertLessThan(elapsed, 1 + Shell.killGrace + 3 + 3 + 2)
        let pid = try XCTUnwrap(scriptPid())
        XCTAssertFalse(isAlive(pid))
    }

    func testToolThatExitsOnTermNeedsNoKill() throws {
        let tool = try makeScript("echo $$ > '\(pidFile)'\nwhile :; do sleep 0.2; done")
        let start = Date()
        let r = Shell.run(tool, [], timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1 + Shell.killGrace)
        XCTAssertFalse(isAlive(try XCTUnwrap(scriptPid())))
    }

    func testToolNamedKillIsRefused() throws {
        let url = dir.appendingPathComponent("kill")
        try "#!/bin/sh\necho ran > '\(dir.appendingPathComponent("ran").path)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let r = Shell.run(url.path, [], timeout: 5)
        XCTAssertTrue(r.refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ran").path))
        // A link with another name that points to it is refused too.
        let link = dir.appendingPathComponent("harmless")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertTrue(Shell.run(link.path, [], timeout: 5).refused)
    }

    func testToolThatFinishesInTimeIsUnchanged() throws {
        let tool = try makeScript("echo hello\necho oops >&2\nexit 3")
        let r = Shell.run(tool, [], timeout: 5)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.stdout, "hello\n")
        XCTAssertEqual(r.stderr, "oops\n")
    }

    func testToolThatExitsAtTheLimitDoesNotCrash() throws {
        let tool = try makeScript("sleep 0.5")
        for _ in 0..<5 {
            let r = Shell.run(tool, [], timeout: 0.5)
            // Either outcome is fine. The call must return and not crash.
            XCTAssertTrue(r.status == 0 || r.timedOut)
        }
    }
}
