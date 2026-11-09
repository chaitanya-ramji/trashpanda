import XCTest
@testable import PandaCore

final class UpdateDownloadsTests: XCTestCase {
    private let id = "com.example.App"

    /// A child of Installation or PersistentDownloads, `days` old. The child is a folder that holds a file.
    @discardableResult
    private func update(_ box: Sandbox, app: String? = nil, in sub: String = "Installation", _ name: String,
                        bytes: Int = 3_000_000, days: Int) throws -> URL {
        let base = "Library/Caches/\(app ?? id)/org.sparkle-project.Sparkle/\(sub)/\(name)"
        try box.file("\(base)/Update.zip", bytes: bytes)
        let url = box.home.appendingPathComponent(base)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(days) * 86_400)],
                                              ofItemAtPath: url.path)
        return url
    }

    private func scanner(_ box: Sandbox, names: [String: String] = ["com.example.App": "Example"]) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false, appName: { names[$0] })
    }

    private func cleaner(_ s: DiskScanner, running: [RunningApp] = []) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider)
    }

    // MARK: What counts

    func testOnlyUpdatesOlderThanSevenDaysCount() throws {
        let box = try Sandbox()
        try update(box, "old1", bytes: 3_000_000, days: 30)
        try update(box, in: "PersistentDownloads", "old2", bytes: 2_000_000, days: 10)
        try update(box, "fresh", bytes: 4_000_000, days: 2)             // an update can be in progress
        try update(box, "edge", bytes: 1_000_000, days: 6)
        let apps = UpdateDownloads.list(home: box.home, now: Date())
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].staleItems.map(\.lastPathComponent).sorted(), ["old1", "old2"])
        XCTAssertGreaterThanOrEqual(apps[0].staleBytes, 5_000_000)
        XCTAssertLessThan(apps[0].staleBytes, 8_000_000, "The two recent ones are not counted")
    }

    func testTheItemNamesTheAppAndIsSafe() throws {
        let box = try Sandbox()
        try update(box, "old", days: 30)
        let item = try XCTUnwrap(scanner(box).scanUpdateDownloads().first)
        XCTAssertEqual(item.title, "Old update downloads · Example")
        XCTAssertEqual(item.id, "app.updates:com.example.App")
        XCTAssertEqual(item.tier, .safe)
        XCTAssertEqual(item.rebuild, .download)
        XCTAssertEqual(item.ecosystem, .apps)
        XCTAssertEqual(item.owner?.bundleIDs, ["com.example.App"], "The app that owns it must be closed")
        XCTAssertTrue(item.location.contains("older than 7 days"))
        XCTAssertTrue(item.location.hasPrefix("~/Library/Caches/com.example.App"), item.location)
    }

    func testAnAppThatIsNotInstalledIsNamedByItsBundleID() throws {
        let box = try Sandbox()
        try update(box, app: "com.gone.App", "old", days: 30)
        XCTAssertEqual(scanner(box, names: [:]).scanUpdateDownloads().first?.title, "Old update downloads · com.gone.App")
    }

    func testNothingWhenThereIsNothingOldOrNoUpdateFolder() throws {
        let box = try Sandbox()
        try update(box, "fresh", days: 1)
        try box.file("Library/Caches/com.other.App/Cache.db", bytes: 3_000_000)                     // not a Sparkle app
        try box.file("Library/Caches/com.third.App/org.sparkle-project.Sparkle/Launcher/x", bytes: 3_000_000, age: 90)
        XCTAssertTrue(scanner(box).scanUpdateDownloads().isEmpty)
    }

    func testSeveralAppsAreSeparateItems() throws {
        let box = try Sandbox()
        try update(box, app: "com.a.App", "o", days: 20); try update(box, app: "com.b.App", "o", days: 20)
        XCTAssertEqual(scanner(box, names: [:]).scanUpdateDownloads().count, 2)
    }

    func testBadFolderNamesAndLinksAreNotListed() throws {
        let box = try Sandbox()
        try update(box, app: "Some Folder With Spaces", "old", days: 30)
        // A cache folder that is a link to a project. The "old files" inside it would be the user's files.
        let project = try box.file("Developer/proj/org.sparkle-project.Sparkle/Installation/old/x", bytes: 3_000_000)
            .deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: project.path)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches/com.link.App"),
                                                   withDestinationURL: box.home.appendingPathComponent("Developer/proj"))
        XCTAssertTrue(scanner(box).scanUpdateDownloads().isEmpty, "\(scanner(box).scanUpdateDownloads().map(\.title))")
    }

    func testALinkInsideTheUpdateFolderIsSkipped() throws {
        let box = try Sandbox()
        let precious = try box.file("Documents/keep/x", bytes: 3_000_000).deletingLastPathComponent()
        try update(box, "real", days: 30)
        let inst = box.home.appendingPathComponent("Library/Caches/\(id)/org.sparkle-project.Sparkle/Installation")
        let link = inst.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious)
        // Make the link itself old. (setAttributes would change the target, so we use lutimes.)
        let old = time_t(Date().addingTimeInterval(-40 * 86_400).timeIntervalSince1970)
        var times = [timeval(tv_sec: old, tv_usec: 0), timeval(tv_sec: old, tv_usec: 0)]
        XCTAssertEqual(lutimes(link.path, &times), 0)
        let s = scanner(box)
        let items = UpdateDownloads.staleItems(in: inst.deletingLastPathComponent(), now: Date())
        XCTAssertEqual(items.map(\.lastPathComponent), ["real"], "An old link is still not an item")
        _ = cleaner(s).clean(s.scanUpdateDownloads())
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.appendingPathComponent("x").path))
    }

    // MARK: The clean

    func testCleaningRemovesOnlyTheOldUpdateFiles() throws {
        let box = try Sandbox()
        let old1 = try update(box, "old1", days: 30)
        let old2 = try update(box, in: "PersistentDownloads", "old2", days: 10)
        let fresh = try update(box, "fresh", days: 2)
        let launcher = try box.file("Library/Caches/\(id)/org.sparkle-project.Sparkle/Launcher/Autoupdate", bytes: 100, age: 90)
        let other = try box.file("Library/Caches/\(id)/Cache.db", bytes: 3_000_000, age: 90)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanUpdateDownloads().first)

        let report = cleaner(s).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertGreaterThanOrEqual(report.freed, 5_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old2.path))
        for keep in [fresh, launcher, other, old1.deletingLastPathComponent(), old2.deletingLastPathComponent()] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path), keep.lastPathComponent)
        }
        XCTAssertTrue(s.scanUpdateDownloads().isEmpty, "It does not come back in the next scan")
    }

    func testAnUpdateThatStartsAfterTheScanStays() throws {
        let box = try Sandbox()
        let old = try update(box, "old", days: 30)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanUpdateDownloads().first)
        // The app starts to use this update after the scan. Its time is new now.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: old.path)
        let report = cleaner(s).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "The age is read again at clean time")
    }

    func testNothingIsRemovedWhileTheAppRuns() throws {
        let box = try Sandbox()
        let old = try update(box, "old", days: 30)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanUpdateDownloads().first)
        let report = cleaner(s, running: [RunningApp(bundleID: id, name: "Example")]).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.blockedApps, ["Example"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testAnotherAppRunningDoesNotBlock() throws {
        let box = try Sandbox()
        try update(box, "old", days: 30)
        let s = scanner(box)
        let report = cleaner(s, running: [RunningApp(bundleID: "com.apple.Safari", name: "Safari")]).clean(s.scanUpdateDownloads())
        XCTAssertEqual(report.removed, 1)
    }

    func testOnlyTheUpdateFolderOfAnAppCanBeCleaned() throws {
        let box = try Sandbox()
        let old = try update(box, "old", days: 30)
        let cache = box.home.appendingPathComponent("Library/Caches/\(id)")
        let docs = try box.file("Documents/proj/org.sparkle-project.Sparkle/Installation/old/x", bytes: 1_000, age: 90)
        let docsSparkle = box.home.appendingPathComponent("Documents/proj/org.sparkle-project.Sparkle")
        let traversal = box.home.appendingPathComponent("Library/Caches/\(id)/org.sparkle-project.Sparkle/../../../../Documents/proj/org.sparkle-project.Sparkle")
        let wrongName = box.home.appendingPathComponent("Library/Caches/\(id)/Other")


        let lookalike = try box.file("Library/Caches/\(id)/Other/Installation/old/x", bytes: 3_000_000, age: 90)
            .deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86_400)], ofItemAtPath: lookalike.path)
        let cachesRoot = box.home.appendingPathComponent("Library/Caches")
        for url in [cache, docsSparkle, traversal, wrongName, cachesRoot] {
            let f = Finding(id: "x", ecosystem: .apps, title: "x", location: url.path, bytes: 1, tier: .safe, rebuild: .download,
                            action: .removeUpdateDownloads(url))
            XCTAssertEqual(cleaner(scanner(box)).clean([f]).removed, 0, url.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.path), "Documents are safe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lookalike.path),
                      "A folder that is not named org.sparkle-project.Sparkle is not cleaned, even with an Installation folder inside")
    }

    func testALinkedCacheFolderIsNeverCleaned() throws {
        let box = try Sandbox()
        let project = try box.file("Developer/proj/org.sparkle-project.Sparkle/Installation/old/x", bytes: 3_000_000)
        let old = project.deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        let link = box.home.appendingPathComponent("Library/Caches/com.link.App")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: box.home.appendingPathComponent("Developer/proj"))
        let forged = Finding(id: "x", ecosystem: .apps, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                             action: .removeUpdateDownloads(link.appendingPathComponent("org.sparkle-project.Sparkle")))
        XCTAssertEqual(cleaner(scanner(box)).clean([forged]).removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path), "The project files are safe")
    }

    func testIsSparkleFolder() {
        let home = URL(fileURLWithPath: "/Users/x")
        func check(_ p: String) -> Bool { UpdateDownloads.isSparkleFolder(URL(fileURLWithPath: p), home: home) }
        XCTAssertTrue(check("/Users/x/Library/Caches/com.example.App/org.sparkle-project.Sparkle"))
        XCTAssertFalse(check("/Users/x/Library/Caches/com.example.App"))
        XCTAssertFalse(check("/Users/x/Library/Caches/com.example.App/Other"), "Two levels, but not the Sparkle folder")
        XCTAssertFalse(check("/Users/x/Library/Caches/org.sparkle-project.Sparkle"), "No app folder")
        XCTAssertFalse(check("/Users/x/Library/Caches/com.example.App/org.sparkle-project.Sparkle/Installation"))
        XCTAssertFalse(check("/Users/x/Library/Caches/a/b/org.sparkle-project.Sparkle"))
        XCTAssertFalse(check("/Users/x/Documents/org.sparkle-project.Sparkle"))
        XCTAssertFalse(check("/Users/y/Library/Caches/com.example.App/org.sparkle-project.Sparkle"), "Another user")
        XCTAssertFalse(check("/Users/x/Library/Caches/../../x/org.sparkle-project.Sparkle"))
        XCTAssertFalse(check("/Users/x/Library/Caches/com.example App/org.sparkle-project.Sparkle"), "A space is not a bundle ID")
    }

    func testTheRealSystemNamesAnInstalledApp() throws {
        // Finder is on every Mac. LaunchServices must know its name.
        try XCTSkipIf(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") == nil, "No LaunchServices")
        XCTAssertEqual(UpdateDownloads.systemAppName(for: "com.apple.finder"), "Finder")
        XCTAssertNil(UpdateDownloads.systemAppName(for: "com.example.not-installed"))
    }
}
