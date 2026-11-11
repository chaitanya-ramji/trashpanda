import XCTest
@testable import PandaCore

final class LogPrivacyTests: XCTestCase {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("log-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testRedactReplacesHome() {
        let out = Log.redact("remove /Users/test/Library/Caches/x and /Users/test", home: "/Users/test")
        XCTAssertEqual(out, "remove ~/Library/Caches/x and ~")
    }

    func testRedactLeavesOtherPathsAndEmptyHome() {
        XCTAssertEqual(Log.redact("/Users/tester/x", home: "/Users/test"), "~er/x")
        XCTAssertEqual(Log.redact("/opt/x", home: ""), "/opt/x")
    }

    func testShortenKeepsTwoPartsAndCountsRest() {
        XCTAssertEqual(Log.shorten("removed ~/Library/Caches/a/b/c: failed"), "removed ~/Library/Caches/(3 more): failed")
        XCTAssertEqual(Log.shorten("skip ~/Library/Caches"), "skip ~/Library/Caches")
        XCTAssertEqual(Log.shorten("at /Volumes/Disk/a/b."), "at /Volumes/Disk/(2 more).")
        XCTAssertEqual(Log.shorten("freed 12 bytes and/or more"), "freed 12 bytes and/or more")
    }

    func testExportForReportKeepsLast200Lines() throws {
        let dir = try temp()
        let file = dir.appendingPathComponent("t.log")
        let lines = (1...250).map { "2026-01-01T00:00:00Z INFO  line \($0) /Users/test/Library/Caches/a/b" }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let out = Log.exportForReport(from: file, home: "/Users/test").split(separator: "\n")
        XCTAssertEqual(out.count, 200)
        XCTAssertTrue(out.first!.contains("line 51 "))
        XCTAssertTrue(out.last!.hasSuffix("~/Library/Caches/(2 more)"))
        XCTAssertFalse(out.joined().contains("/Users/test"))
    }

    func testNewLogFileAndFolderModes() throws {
        let dir = try temp()
        let old = Log.fileURL
        defer { Log.fileURL = old }
        Log.fileURL = dir.appendingPathComponent("logs/trashpanda.log")
        Log.info("mode check")
        Log.flush()
        let fm = FileManager.default
        let file = try fm.attributesOfItem(atPath: Log.fileURL.path)[.posixPermissions] as? Int
        let folder = try fm.attributesOfItem(atPath: Log.fileURL.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(file, 0o600)
        XCTAssertEqual(folder, 0o700)
    }

    func testLinesFromManyCallsAreWrittenInOrderAndFlushWaitsForThem() throws {
        let dir = try temp()
        let old = Log.fileURL
        defer { Log.fileURL = old }
        Log.fileURL = dir.appendingPathComponent("order/trashpanda.log")
        for i in 0..<50 { Log.info("line \(i)") }
        Log.flush()
        let lines = try String(contentsOf: Log.fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 50)
        XCTAssertTrue(lines.first?.hasSuffix("line 0") == true && lines.last?.hasSuffix("line 49") == true)
    }

    func testALogFileThatWasDeletedIsMadeAgain() throws {
        let dir = try temp()
        let old = Log.fileURL
        defer { Log.fileURL = old }
        Log.fileURL = dir.appendingPathComponent("gone/trashpanda.log")
        Log.info("first")
        Log.flush()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone"))
        Log.info("second")
        Log.flush()
        let text = try String(contentsOf: Log.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("second"))
        XCTAssertFalse(text.contains("first"))
    }
}
