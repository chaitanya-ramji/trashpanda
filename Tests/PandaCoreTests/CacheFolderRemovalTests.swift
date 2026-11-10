import XCTest
@testable import PandaCore

/// The cache explorer rows can be emptied (the owner asked: "if it cannot be removed, it is useless").
/// An unknown folder is a review item. CloudKit, Apple caches, and folders that have their own item are never emptied through it.
final class CacheFolderRemovalTests: XCTestCase {
    private let mb = 3_500_000
    private func make(_ box: Sandbox) throws {
        try box.file("Library/Caches/Adobe/a/data", bytes: 3 * mb)
        try box.file("Library/Caches/Adobe/b", bytes: mb)
        try box.file("Library/Caches/company.thebrowser.Browser/c/data", bytes: 4 * mb)
        try box.file("Library/Caches/CloudKit/data", bytes: 5 * mb)
        try box.file("Library/Caches/com.apple.bird/data", bytes: 5 * mb)
        try box.file("Library/Caches/pnpm/x", bytes: 5 * mb)
    }
    private func scanner(_ box: Sandbox, names: [String: String] = ["company.thebrowser.Browser": "Arc"]) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false, appName: { names[$0] })
    }
    private func cleaner(_ box: Sandbox, running: [RunningApp] = []) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func item(_ box: Sandbox, _ folder: String) -> Finding? { scanner(box).scanCacheExplorer().first { $0.id == "cache.explorer:\(folder)" } }
    private func forged(_ name: String) -> Finding {
        Finding(id: "f", ecosystem: .cacheExplorer, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .download, action: .removeCacheFolderContents(name: name))
    }

    // MARK: The items

    func testAnUnknownFolderIsAReviewItemThatNeverJoinsTheOneClickClean() throws {
        let box = try Sandbox()
        try make(box)
        let f = try XCTUnwrap(item(box, "Adobe"))
        XCTAssertEqual(f.title, "Adobe · cache folder")
        XCTAssertEqual(f.tier, .review)
        XCTAssertTrue(f.isActionable)
        XCTAssertNil(f.owner, "Adobe is not a bundle ID, so no app can be matched")
        XCTAssertTrue(f.note?.contains("do not know the app") == true)
        let all = scanner(box).scanCacheExplorer()
        XCTAssertEqual(ScanResult(findings: all, disk: DiskUsage(total: 1, free: 1)).reclaimable, 0)
        XCTAssertEqual(Confirmation.kind(of: f), .cacheFolder)
        let c = Confirmation.forOne(f, staleDays: 30)
        XCTAssertEqual(c.title, "Empty this cache folder?")
        XCTAssertEqual(c.confirmTitle, "Empty folder")
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertTrue(c.footer?.contains("sign you out") == true && c.footer?.contains("can't be undone") == true)
    }

    func testAKeepFolderAndAFolderWithAnItemHaveNoAction() throws {
        let box = try Sandbox()
        try make(box)
        for name in ["CloudKit", "com.apple.bird", "pnpm"] {
            let f = try XCTUnwrap(item(box, name), name)
            XCTAssertFalse(f.isActionable, name)
            if case .inform = f.action {} else { XCTFail(name) }
        }
    }

    func testABundleIDFolderGetsTheOwnerApp() throws {
        let box = try Sandbox()
        try make(box)
        let f = try XCTUnwrap(item(box, "company.thebrowser.Browser"))
        XCTAssertEqual(f.owner?.name, "Arc")
        XCTAssertTrue(f.owner?.matches(bundleID: "company.thebrowser.Browser") == true)
        XCTAssertTrue(f.owner?.matches(bundleID: "company.thebrowser.Browser.helper") == true)
        XCTAssertFalse(f.owner?.matches(bundleID: "company.thebrowser.Other") == true)
        XCTAssertEqual(f.title, "Arc (company.thebrowser.Browser) · cache folder")
    }

    func testBundleIDShapes() {
        for ok in ["company.thebrowser.Browser", "com.example.app", "org.mozilla.firefox", "com.apple-x.y.z", "io.a.b"] { XCTAssertTrue(CacheExplorer.looksLikeBundleID(ok), ok) }
        for bad in ["Adobe", "a.b", "pnpm", "go-build", "com..x", "-a.b.c", "a.b.c\n", ".a.b.c", "com.example."] { XCTAssertFalse(CacheExplorer.looksLikeBundleID(bad), bad) }
    }

    // MARK: The clean

    func testACleanEmptiesTheFolderAndKeepsTheFolderAndTheRest() throws {
        let box = try Sandbox()
        try make(box)
        let f = try XCTUnwrap(item(box, "Adobe"))
        let report = cleaner(box).clean([f])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(report.freed >= 4 * Int64(mb) && report.freed <= f.bytes + 100_000, "\(report.freed)")
        XCTAssertTrue(exists(box, "Library/Caches/Adobe"), "The folder stays")
        XCTAssertFalse(exists(box, "Library/Caches/Adobe/a/data") || exists(box, "Library/Caches/Adobe/b"))
        for keep in ["CloudKit/data", "com.apple.bird/data", "pnpm/x", "company.thebrowser.Browser/c/data"] { XCTAssertTrue(exists(box, "Library/Caches/\(keep)"), keep) }
        XCTAssertEqual(scanner(box).remainingBytes(of: f), 0)
    }

    func testAnOpenAppBlocksItsFolder() throws {
        let box = try Sandbox()
        try make(box)
        let f = try XCTUnwrap(item(box, "company.thebrowser.Browser"))
        let report = cleaner(box, running: [RunningApp(bundleID: "company.thebrowser.Browser", name: "Arc")]).clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.blockedApps, ["Arc"])
        XCTAssertTrue(exists(box, "Library/Caches/company.thebrowser.Browser/c/data"))
        XCTAssertEqual(cleaner(box).clean([f]).removed, 1, "When the app is closed, it is cleaned")
    }

    func testForgedNamesRemoveNothing() throws {
        let box = try Sandbox()
        try make(box)
        try box.file("Documents/keep.txt", bytes: 100)
        let names = ["", ".", "..", "../Documents", "a/b", "/etc", ".hidden", "CloudKit", "cloudkit", "com.apple.bird", "com.apple.anything", "GeoServices",
                     "FamilyCircle", "pnpm", "Yarn", "Homebrew", "ms-playwright", "Adobe\n", "x\u{0}y", String(repeating: "a", count: 300), "Library", "Caches"]
        let report = cleaner(box).clean(names.map(forged))
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, names.count)
        for keep in ["Library/Caches/CloudKit/data", "Library/Caches/com.apple.bird/data", "Library/Caches/pnpm/x", "Library/Caches/Adobe/a/data", "Documents/keep.txt"] {
            XCTAssertTrue(exists(box, keep), keep)
        }
    }

    func testANameThatLeavesTheCachesFolderCannotReachAnUnprotectedFolder() throws {
        let box = try Sandbox()
        try box.file("Projects/app/src.swift", bytes: 100)
        try box.file("Library/Preferences/x.plist", bytes: 100)
        try box.file("elsewhere/data", bytes: 100)
        let report = cleaner(box).clean(["../../Projects", "../../elsewhere", "../../Projects/app", "..", "../Caches/../../Projects"].map(forged))
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(box, "Projects/app/src.swift") && exists(box, "elsewhere/data") && exists(box, "Library/Preferences/x.plist"))
    }

    func testAFolderThatIsALinkIsNeverFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/precious", bytes: 100)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches/Linked"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertEqual(cleaner(box).clean([forged("Linked")]).removed, 0)
        XCTAssertTrue(exists(box, "elsewhere/precious"))
    }

    func testAChildThatIsALinkRemovesTheLinkAndNotTheTarget() throws {
        let box = try Sandbox()
        try make(box)
        try box.file("elsewhere/precious", bytes: 100)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches/Adobe/link"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        let f = try XCTUnwrap(item(box, "Adobe"))
        _ = cleaner(box).clean([f])
        XCTAssertTrue(exists(box, "elsewhere/precious"), "Only the link may go, and the guard refuses it")
    }

    func testACachesFolderThatIsALinkIsNeverFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/Adobe/data", bytes: 100)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertEqual(cleaner(box).clean([forged("Adobe")]).removed, 0)
        XCTAssertTrue(exists(box, "elsewhere/Adobe/data"))
    }

    func testAFolderThatBecameAKeepFolderOrALinkAfterThePreviewIsSafe() throws {
        let box = try Sandbox()
        try make(box)
        try box.file("proj/precious", bytes: 100)
        let f = try XCTUnwrap(item(box, "Adobe"))
        try FileManager.default.removeItem(at: box.home.appendingPathComponent("Library/Caches/Adobe"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches/Adobe"), withDestinationURL: box.home.appendingPathComponent("proj"))
        XCTAssertEqual(cleaner(box).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, "proj/precious"))
    }

    func testTheGuardStillStopsTheWholeCachesFolder() throws {
        let box = try Sandbox()
        try make(box)
        let all = Finding(id: "f", ecosystem: .cacheExplorer, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .download,
                          action: .removeContents(box.home.appendingPathComponent("Library/Caches")))
        XCTAssertEqual(cleaner(box).clean([all]).removed, 0)
        XCTAssertTrue(exists(box, "Library/Caches/CloudKit/data") && exists(box, "Library/Caches/Adobe/a/data"))
    }

    // MARK: No double counting

    func testBytesThatAnotherItemCountsAreNotCountedTwice() throws {
        let box = try Sandbox()
        // The Sparkle folder of Arc is inside the cache folder of Arc.
        try box.file("Library/Caches/company.thebrowser.Browser/org.sparkle-project.Sparkle/Installation/old/x", bytes: 4 * mb, age: 30)
        try box.file("Library/Caches/company.thebrowser.Browser/other/y", bytes: 2 * mb)
        let s = scanner(box, names: ["company.thebrowser.Browser": "Arc"])
        let explorer = try XCTUnwrap(s.scanCacheExplorer().first)
        let update = Finding(id: "app.updates:company.thebrowser.Browser", ecosystem: .apps, title: "Old update downloads · Arc",
                             location: "x", bytes: 4 * Int64(mb), tier: .safe, rebuild: .download,
                             action: .removeUpdateDownloads(box.home.appendingPathComponent("Library/Caches/company.thebrowser.Browser/org.sparkle-project.Sparkle")))
        let merged = DiskScanner.removeOverlap([explorer, update], home: box.home)
        let after = try XCTUnwrap(merged.first { $0.id == explorer.id })
        XCTAssertEqual(after.bytes, explorer.bytes - 4 * Int64(mb))
        XCTAssertTrue(after.note?.contains("Not counted here") == true && after.note?.contains("Old update downloads") == true, after.note ?? "")
        XCTAssertEqual(merged.first { $0.id == update.id }?.bytes, update.bytes, "The other item keeps its size")
        let total = merged.filter(\.isActionable).reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertEqual(total, explorer.bytes, "The folder is in the total once")
    }

    func testAnItemThatIsNotInsideTheFolderIsLeftAlone() throws {
        let box = try Sandbox()
        try make(box)
        let s = scanner(box)
        let explorer = try XCTUnwrap(s.scanCacheExplorer().first { $0.id.hasSuffix("Adobe") })
        let other = Finding(id: "o", ecosystem: .go, title: "x", location: "x", bytes: 9_000_000, tier: .safe, rebuild: .minutes,
                            action: .removeContents(box.home.appendingPathComponent("Library/Caches/AdobeSomethingElse")))
        XCTAssertEqual(DiskScanner.removeOverlap([explorer, other], home: box.home).first { $0.id == explorer.id }?.bytes, explorer.bytes,
                       "A folder name that only starts the same is not inside it")
    }
}
