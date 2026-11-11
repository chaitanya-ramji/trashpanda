import XCTest
@testable import PandaCore

/// S-02 and Q-04: a handler measures first and checks last, and it reports what it measured.
/// While the size is measured, a folder above the target becomes a link. The path still looks right, but it leads
/// somewhere else. The check after the measuring must refuse it, and nothing may be deleted.
final class CleanerMeasureFirstTests: XCTestCase {
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }

    private func cleaner(_ s: DiskScanner, programs: [String] = []) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider, programPaths: { programs })
    }

    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    /// The first time that a size is measured, the folder `rel` moves to `rel-moved`, and a link takes its place.
    /// The cleaner counts every delete, so a test can say that none happened.
    private func linkWhileMeasuring(_ box: Sandbox, _ cleaner: Cleaner, swap rel: String) -> () -> Int {
        let parent = box.home.appendingPathComponent(rel)
        let moved = box.home.appendingPathComponent(rel + "-moved")
        var swapped = false
        var deletes = 0
        cleaner.sizeOf = { url in
            if !swapped {
                swapped = true
                try? FileManager.default.moveItem(at: parent, to: moved)
                try? FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
            }
            return Sizer.size(of: url)
        }
        cleaner.deleteItem = { url in deletes += 1; try FileManager.default.removeItem(at: url) }
        return { deletes }
    }

    // MARK: Old test browsers

    func testOldTestBrowsersAreRefusedWhenTheirFolderBecomesALinkWhileMeasuring() throws {
        let box = try Sandbox()
        let pw = "Library/Caches/ms-playwright"
        for v in ["1200", "1300"] { try box.file("\(pw)/chromium-\(v)/chrome", bytes: 3_000_000) }
        let s = scanner(box)
        let items = s.scanTestBrowsers()
        XCTAssertEqual(items.count, 1)
        let c = cleaner(s)
        let deletes = linkWhileMeasuring(box, c, swap: pw)
        let report = c.clean(items)
        XCTAssertEqual(deletes(), 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1, "\(report.skipped)")
        XCTAssertTrue(exists(box, "\(pw)-moved/chromium-1200/chrome"), "the old version is still there")
    }

    // MARK: Service Worker storage

    func testServiceWorkerStorageIsRefusedWhenTheBrowserFolderBecomesALinkWhileMeasuring() throws {
        let box = try Sandbox()
        let site = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
        let arc = "Library/Application Support/Arc"
        try box.file("\(arc)/User Data/Default/Service Worker/CacheStorage/\(site)/index.txt", bytes: 3_000_000)
        let forged = Finding(id: "x", ecosystem: .browsers, title: "Offline websites", location: "x", bytes: 1, tier: .review,
                             rebuild: .download, action: .removeServiceWorkerStorage(browserID: "arc"))
        let c = cleaner(scanner(box))
        let deletes = linkWhileMeasuring(box, c, swap: arc)
        let report = c.clean([forged])
        XCTAssertEqual(deletes(), 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1, "\(report.skipped)")
        XCTAssertTrue((report.skipped.first ?? "").contains("not Service Worker storage of the browser"),
                      "the shape check after the measuring refuses it, not only the guard: \(report.skipped)")
        XCTAssertTrue(exists(box, "\(arc)-moved/User Data/Default/Service Worker/CacheStorage/\(site)/index.txt"))
    }

    // MARK: Browser caches

    func testBrowserCachesAreRefusedWhenTheCacheRootBecomesALinkWhileMeasuring() throws {
        let box = try Sandbox()
        let root = "Library/Caches/Arc"
        try box.file("\(root)/User Data/Default/Cache/f_1", bytes: 3_000_000)
        try box.file("\(root)/User Data/Default/Code Cache/f_2", bytes: 3_000_000)
        let s = scanner(box)
        let items = s.scanBrowserCaches()
        XCTAssertEqual(items.count, 1)
        let c = cleaner(s)
        let deletes = linkWhileMeasuring(box, c, swap: root)
        let report = c.clean(items)
        XCTAssertEqual(deletes(), 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 2, "\(report.skipped)")
        XCTAssertTrue(exists(box, "\(root)-moved/User Data/Default/Cache/f_1"))
        XCTAssertTrue(exists(box, "\(root)-moved/User Data/Default/Code Cache/f_2"))
    }

    // MARK: Update downloads

    func testUpdateDownloadsAreRefusedWhenTheAppFolderBecomesALinkWhileMeasuring() throws {
        let box = try Sandbox()
        let app = "Library/Caches/com.example.App"
        let item = try box.file("\(app)/org.sparkle-project.Sparkle/Installation/old1/Update.zip", bytes: 3_000_000)
            .deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: item.path)
        let sparkle = box.home.appendingPathComponent("\(app)/org.sparkle-project.Sparkle")
        let forged = Finding(id: "x", ecosystem: .browsers, title: "Old updates", location: "x", bytes: 1, tier: .safe,
                             rebuild: .download, action: .removeUpdateDownloads(sparkle))
        let c = cleaner(scanner(box))
        let deletes = linkWhileMeasuring(box, c, swap: app)
        let report = c.clean([forged])
        XCTAssertEqual(deletes(), 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1, "\(report.skipped)")
        XCTAssertTrue(exists(box, "\(app)-moved/org.sparkle-project.Sparkle/Installation/old1/Update.zip"))
    }

    // MARK: The report counts what was measured, not the scan (Q-04)

    /// The scan saw `scanned` bytes. Then the folder grew by 3 MB. The report must show the size at the time of the delete.
    private func assertMeasuredNotScanned(_ box: Sandbox, folder: URL, grow: String, action: Action,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let scanned = Sizer.size(of: folder)
        try box.file(grow, bytes: 3_000_000)
        let finding = Finding(id: "x", ecosystem: .swift, title: "x", location: folder.path, bytes: scanned, tier: .review,
                              rebuild: .recreate, action: action)
        let report = Cleaner(guardian: PathGuard(home: box.home), runningApps: FakeRunning().provider).clean([finding])
        XCTAssertEqual(report.removed, 1, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), file: file, line: line)
        XCTAssertGreaterThan(report.freed, scanned + 2_900_000, "the report shows the size of the delete, not of the scan: \(report.freed) vs \(scanned)",
                             file: file, line: line)
    }

    func testAnArchiveThatGrewAfterTheScanReportsTheNewSize() throws {
        let box = try Sandbox()
        let folder = try box.file("Library/Developer/Xcode/Archives/2026-05-01/Real.xcarchive/Info.plist", bytes: 1_000_000)
            .deletingLastPathComponent()
        try assertMeasuredNotScanned(box, folder: folder, grow: "Library/Developer/Xcode/Archives/2026-05-01/Real.xcarchive/more",
                                     action: .removeArchive(folder))
    }

    func testDeviceSupportThatGrewAfterTheScanReportsTheNewSize() throws {
        let box = try Sandbox()
        let base = "Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 17.5 (21F79)"
        let folder = try box.file("\(base)/Symbols/a", bytes: 1_000_000).deletingLastPathComponent().deletingLastPathComponent()
        try assertMeasuredNotScanned(box, folder: folder, grow: "\(base)/Symbols/more", action: .removeDeviceSupport(folder))
    }

    func testABuildFolderThatGrewAfterTheScanReportsTheNewSize() throws {
        let box = try Sandbox()
        try box.file("Developer/app/package.json", bytes: 10)
        let folder = try box.file("Developer/app/node_modules/x/i.js", bytes: 1_000_000).deletingLastPathComponent().deletingLastPathComponent()
        try assertMeasuredNotScanned(box, folder: folder, grow: "Developer/app/node_modules/x/more.js", action: .removeArtifact(folder))
    }
}
