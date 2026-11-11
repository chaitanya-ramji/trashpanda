import XCTest
@testable import PandaCore

/// Every test uses its own temporary home folder. The real settings file is never read or written.
final class KeepAppendTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("keep-append-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var keepFile: URL { home.appendingPathComponent(".config/trashpanda/keep") }
    private func lines() throws -> [String] {
        try String(contentsOf: keepFile, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
    }

    func testItMakesTheFileAndAddsOneLine() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: keepFile.path))
        let path = home.appendingPathComponent("Projects/app/node_modules").path
        XCTAssertEqual(Config.appendKeep(path, home: home), .added)
        XCTAssertEqual(try lines(), [home.appendingPathComponent("Projects/app/node_modules").standardizedFileURL.path])
    }

    func testASecondCallWithTheSamePathAddsNothing() throws {
        let path = home.appendingPathComponent("Projects/app/node_modules").path
        XCTAssertEqual(Config.appendKeep(path, home: home), .added)
        XCTAssertEqual(Config.appendKeep(path, home: home), .alreadyKept)
        XCTAssertEqual(Config.appendKeep(path + "/", home: home), .alreadyKept)
        XCTAssertEqual(try lines().count, 1)
    }

    func testAPathThatIsWrittenWithATildeCountsAsKept() throws {
        try FileManager.default.createDirectory(at: keepFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "~/Projects/old\n".write(to: keepFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.appendKeep(home.appendingPathComponent("Projects/old").path, home: home), .alreadyKept)
        XCTAssertEqual(try lines(), ["~/Projects/old"])
    }

    func testOldLinesStayAndAFileWithoutALastLineBreakIsHandled() throws {
        try FileManager.default.createDirectory(at: keepFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# my notes\n~/Projects/old".write(to: keepFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.appendKeep(home.appendingPathComponent("Projects/new").path, home: home), .added)
        let text = try String(contentsOf: keepFile, encoding: .utf8)
        XCTAssertEqual(text, "# my notes\n~/Projects/old\n\(home.appendingPathComponent("Projects/new").standardizedFileURL.path)\n")
    }

    func testAPathThatIsNotSafeIsRefusedAndNothingIsWritten() {
        XCTAssertEqual(Config.appendKeep("Projects/app", home: home), .refused)
        XCTAssertEqual(Config.appendKeep("~/Projects/app", home: home), .refused)
        XCTAssertEqual(Config.appendKeep("/usr/local/lib", home: home), .refused)
        XCTAssertEqual(Config.appendKeep(home.path, home: home), .refused)
        XCTAssertEqual(Config.appendKeep(home.path + "/", home: home), .refused)
        XCTAssertEqual(Config.appendKeep(home.path + "/Projects/../../outside", home: home), .refused)
        XCTAssertEqual(Config.appendKeep(home.path + "-other/x", home: home), .refused)
        XCTAssertEqual(Config.appendKeep(home.path + "/a\n/usr/b", home: home), .refused)
        XCTAssertEqual(Config.appendKeep(home.path + "/a\r/usr/b", home: home), .refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keepFile.path))
    }

    func testAfterTheCallThePathGuardKeepsThePath() throws {
        let folder = home.appendingPathComponent("Projects/app/node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(PathGuard(home: home, keep: Config.load(home: home).keep).check(folder))
        XCTAssertEqual(Config.appendKeep(folder.path, home: home), .added)
        XCTAssertEqual(PathGuard(home: home, keep: Config.load(home: home).keep).check(folder), .kept)
    }
}
