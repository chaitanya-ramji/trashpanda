import XCTest
@testable import PandaCore

final class ShellTrustTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        Shell.searchDirsOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeScript(_ name: String, body: String = "echo ok", mode: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    func testFakeSystemToolInSearchFolderIsNotUsed() throws {
        _ = try makeScript("osascript", mode: 0o755)
        Shell.searchDirsOverride = [dir.path, "/usr/bin", "/usr/sbin", "/bin"]
        XCTAssertEqual(Shell.resolve("osascript"), "/usr/bin/osascript")
        for name in ["xcrun", "xcode-select", "tmutil", "lsof", "ps"] {
            XCTAssertEqual(Shell.resolve(name), Shell.systemTools[name])
        }
    }

    func testToolFileThatOthersCanWriteToIsRefused() throws {
        let tool = try makeScript("sometool", mode: 0o777)
        let r = Shell.run(tool.path, [], timeout: 5)
        XCTAssertTrue(r.refused)
        XCTAssertEqual(r.status, -1)
        XCTAssertEqual(r.stderr, "The tool is not safe to run")
        XCTAssertFalse(Shell.isTrustedBinary(tool))
    }

    func testToolFileThatGroupCanWriteToIsRefused() throws {
        let tool = try makeScript("sometool", mode: 0o775)
        XCTAssertTrue(Shell.run(tool.path, [], timeout: 5).refused)
    }

    func testToolFileOwnedByUserWithSafeModeRuns() throws {
        let tool = try makeScript("sometool", mode: 0o755)
        let r = Shell.run(tool.path, [], timeout: 5)
        XCTAssertFalse(r.refused)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }

    func testLinkToTrustedFileIsAccepted() throws {
        let tool = try makeScript("real", mode: 0o755)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        XCTAssertTrue(Shell.isTrustedBinary(link))
        XCTAssertFalse(Shell.run(link.path, [], timeout: 5).refused)
    }

    func testLinkToUntrustedFileIsRefused() throws {
        let tool = try makeScript("real", mode: 0o777)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        XCTAssertFalse(Shell.isTrustedBinary(link))
        XCTAssertTrue(Shell.run(link.path, [], timeout: 5).refused)
    }

    func testChildDoesNotGetLoaderVariables() throws {
        setenv("DYLD_INSERT_LIBRARIES", "/nonexistent.dylib", 1)
        setenv("LD_PRELOAD", "/nonexistent.so", 1)
        defer { unsetenv("DYLD_INSERT_LIBRARIES"); unsetenv("LD_PRELOAD") }
        let tool = try makeScript("envtool", body: "echo \"[${DYLD_INSERT_LIBRARIES}][${LD_PRELOAD}]\"", mode: 0o755)
        let r = Shell.run(tool.path, [], timeout: 5)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "[][]")
    }
}
