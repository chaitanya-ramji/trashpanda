import XCTest
@testable import PandaCore

/// A file with hard links frees its space only when all its links are deleted.
final class SizerHardLinkTests: XCTestCase {
    private let size = 1_000_000

    private func link(_ from: URL, _ to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: from, to: to)
    }

    func testOneLinkInTheFolderCountsZero() throws {
        let box = try Sandbox()
        let store = try box.file("store/pkg.bin", bytes: size)
        try link(store, box.home.appendingPathComponent("project/node_modules/pkg.bin"))
        XCTAssertEqual(Sizer.size(of: box.home.appendingPathComponent("project")), 0)
    }

    func testAllLinksInTheFolderCountOneTime() throws {
        let box = try Sandbox()
        let first = try box.file("project/a/pkg.bin", bytes: size)
        try link(first, box.home.appendingPathComponent("project/b/pkg.bin"))
        let counted = Sizer.size(of: box.home.appendingPathComponent("project"))
        XCTAssertGreaterThanOrEqual(counted, Int64(size))
        XCTAssertLessThan(counted, Int64(2 * size))
    }

    func testAFileWithOneLinkIsCountedAsBefore() throws {
        let box = try Sandbox()
        try box.file("project/plain.bin", bytes: size)
        XCTAssertGreaterThanOrEqual(Sizer.size(of: box.home.appendingPathComponent("project")), Int64(size))
    }

    func testTheStoreFolderCountsZeroWhileAProjectStillLinksIt() throws {
        let box = try Sandbox()
        let store = try box.file("store/pkg.bin", bytes: size)
        try link(store, box.home.appendingPathComponent("project/pkg.bin"))
        XCTAssertEqual(Sizer.size(of: box.home.appendingPathComponent("store")), 0)
    }
}
