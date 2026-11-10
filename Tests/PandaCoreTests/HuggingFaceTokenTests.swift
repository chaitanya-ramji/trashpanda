import XCTest
@testable import PandaCore

/// #57: the Hugging Face cache row must never take the login with it.
final class HuggingFaceTokenTests: XCTestCase {
    private let hf = ".cache/huggingface"

    private func makeCache(_ box: Sandbox) throws {
        try box.file("\(hf)/hub/models--org--name/blobs/aaaa", bytes: 3_000_000)
        try box.file("\(hf)/hub/models--org--name/refs/main", bytes: 40)
        try box.file("\(hf)/xet/chunk-cache/x", bytes: 2_000_000)
        try box.file("\(hf)/token", bytes: 40)
        try box.file("\(hf)/stored_tokens", bytes: 80)
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheScanListsOnlyXetHereAndNeverTheParent() throws {
        let box = try Sandbox()
        try makeCache(box)
        let found = scanner(box).scanCaches().filter { $0.id.hasPrefix("hf.cache") }
        XCTAssertEqual(Set(found.map(\.id)), ["hf.cache:\(hf)/xet"], "The hub is listed for each repository in the AI agents group")
        XCTAssertTrue(found.allSatisfy { $0.tier == .review })
        XCTAssertFalse(found.contains { $0.location.hasSuffix("/huggingface") }, "The parent holds the login")
    }

    func testACleanKeepsTheLogin() throws {
        let box = try Sandbox()
        try makeCache(box)
        let found = scanner(box).scanCaches().filter { $0.id.hasPrefix("hf.cache") }
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "\(hf)/xet/chunk-cache/x"))
        XCTAssertTrue(exists(box, "\(hf)/token"), "The login stays")
        XCTAssertTrue(exists(box, "\(hf)/stored_tokens"))
    }

    func testTheGuardRefusesTheLoginAndItsFolder() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        func check(_ rel: String) -> Refusal? { g.check(box.home.appendingPathComponent(rel)) }
        XCTAssertNotNil(check("\(hf)/token"))
        XCTAssertNotNil(check("\(hf)/stored_tokens"))
        XCTAssertNotNil(check(hf), "The folder that holds the login")
        XCTAssertNil(check("\(hf)/hub"))
        XCTAssertNil(check("\(hf)/hub/models--org--name"))
        XCTAssertNil(check("\(hf)/xet"))
        XCTAssertNil(check("\(hf)/tokens-are-not-here"), "Only the exact names are protected")
    }

    func testAForgedFindingForTheParentRemovesNothing() throws {
        let box = try Sandbox()
        try makeCache(box)
        let parent = box.home.appendingPathComponent(hf)
        let forged = Finding(id: "forged", ecosystem: .python, title: "x", location: parent.path, bytes: 5_000_000,
                             tier: .review, rebuild: .download, action: .removeContents(parent))
        let report = cleaner(box).clean([forged])
        XCTAssertEqual(report.removed, 0)
        XCTAssertFalse(report.skipped.isEmpty)
        XCTAssertTrue(exists(box, "\(hf)/token"))
        XCTAssertTrue(exists(box, "\(hf)/hub/models--org--name/blobs/aaaa"), "Nothing under the parent is removed")
    }

    func testAForgedWholeFolderDeleteIsRefused() throws {
        let box = try Sandbox()
        try makeCache(box)
        let parent = box.home.appendingPathComponent(hf)
        // The artifact action deletes a folder as a whole. The guard must stop it before the name check passes.
        XCTAssertNotNil(PathGuard(home: box.home).check(parent))
    }

    func testTheKeepRowsStillWorkWithoutTheLogin() throws {
        let box = try Sandbox()
        try box.file("\(hf)/hub/m/a", bytes: 2_000_000)
        try box.file("\(hf)/xet/c/x", bytes: 2_000_000)
        let found = scanner(box).scanCaches().filter { $0.id.hasPrefix("hf.cache") }
        XCTAssertEqual(found.count, 1, "Only xet is a row here")
        XCTAssertEqual(cleaner(box).clean(found).removed, 1)
    }
}
