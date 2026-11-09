import XCTest
@testable import PandaCore

final class ServiceWorkerTests: XCTestCase {
    private let support = "Library/Application Support/Arc/User Data"
    private let caches = "Library/Caches/Arc/User Data"

    private func makeArc(_ box: Sandbox, profiles: [String] = ["Default"]) throws {
        for p in profiles {
            try box.file("\(support)/\(p)/Service Worker/CacheStorage/origin1/index.txt", bytes: 4_000_000)
            try box.file("\(support)/\(p)/Service Worker/CacheStorage/origin2/0_0", bytes: 3_000_000)
            try box.file("\(support)/\(p)/Service Worker/Database/000003.log", bytes: 50_000)
            try box.file("\(support)/\(p)/Service Worker/ScriptCache/abc", bytes: 1_000_000)
            try box.file("\(support)/\(p)/GPUCache/data_0", bytes: 2_000_000)
            try box.file("\(caches)/\(p)/Cache/f_1", bytes: 3_000_000)
            for u in ["Cookies", "Login Data", "History", "IndexedDB/a/x", "Local Storage/leveldb/x", "Extensions/e/manifest.json"] {
                try box.file("\(support)/\(p)/\(u)", bytes: 1_000)
            }
        }
    }

    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ s: DiskScanner, running: [RunningApp] = []) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private var arc: Browser { BrowserCaches.browser(id: "arc")! }

    // MARK: The item

    func testAReviewItemThatNeverJoinsTheOneClickClean() throws {
        let box = try Sandbox()
        try makeArc(box)
        let all = scanner(box).scanServiceWorkerStorage()
        let item = try XCTUnwrap(all.first)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(item.title, "Service Worker storage · Arc")
        XCTAssertEqual(item.tier, .review, "Offline web apps keep their files here")
        XCTAssertEqual(item.id, "browser.sw:arc")
        XCTAssertTrue(item.bytes >= 7_000_000 && item.bytes < 8_000_000, "Only CacheStorage: \(item.bytes)")
        XCTAssertTrue(item.location.contains("work offline"))
        let result = ScanResult(findings: all + scanner(box).scanBrowserCaches(), disk: DiskUsage(total: 10, free: 5))
        XCTAssertEqual(result.reclaimable, scanner(box).scanBrowserCaches().reduce(0) { $0 + $1.bytes }, "Only the real caches are safe")
        XCTAssertEqual(result.reviewable, item.bytes)
    }

    func testOnlyCacheStorageIsATarget() throws {
        let box = try Sandbox()
        try makeArc(box, profiles: ["Default", "Profile 3"])
        let targets = BrowserCaches.serviceWorkerTargets(of: arc, home: box.home)
        XCTAssertEqual(targets.map { $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }.sorted(), ["Default", "Profile 3"])
        XCTAssertTrue(targets.allSatisfy { $0.lastPathComponent == "CacheStorage" })
    }

    func testFirefoxHasNoServiceWorkerItem() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Firefox/Profiles/abcd1234.default/Service Worker/CacheStorage/x", bytes: 3_000_000)
        XCTAssertTrue(BrowserCaches.serviceWorkerTargets(of: BrowserCaches.browser(id: "firefox")!, home: box.home).isEmpty)
        XCTAssertTrue(scanner(box).scanServiceWorkerStorage().isEmpty)
    }

    func testNothingWhenThereIsNone() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanServiceWorkerStorage().isEmpty)
        try box.file("\(support)/Default/Cookies", bytes: 3_000_000)
        XCTAssertTrue(scanner(box).scanServiceWorkerStorage().isEmpty)
    }

    // MARK: The clean

    func testACleanRemovesCacheStorageAndNothingElse() throws {
        let box = try Sandbox()
        try makeArc(box)
        let s = scanner(box)
        let report = cleaner(s).clean(s.scanServiceWorkerStorage())

        XCTAssertEqual(report.removed, 1)
        XCTAssertGreaterThan(report.freed, 6_000_000)
        XCTAssertFalse(exists(box, "\(support)/Default/Service Worker/CacheStorage"))
        for keep in ["Service Worker/Database/000003.log", "Service Worker/ScriptCache/abc", "Service Worker", "GPUCache/data_0",
                     "Cookies", "Login Data", "History", "IndexedDB/a/x", "Local Storage/leveldb/x", "Extensions/e/manifest.json"] {
            XCTAssertTrue(exists(box, "\(support)/Default/\(keep)"), "\(keep) must stay")
        }
        XCTAssertTrue(exists(box, "\(caches)/Default/Cache/f_1"), "The real cache is a different item")
        XCTAssertTrue(s.scanServiceWorkerStorage().isEmpty)
    }

    func testTheTwoItemsAreIndependent() throws {
        let box = try Sandbox()
        try makeArc(box)
        let s = scanner(box)
        _ = cleaner(s).clean(s.scanBrowserCaches())
        XCTAssertTrue(exists(box, "\(support)/Default/Service Worker/CacheStorage/origin1/index.txt"), "Cleaning the caches keeps Service Worker data")
        XCTAssertFalse(exists(box, "\(caches)/Default/Cache"))
    }

    func testNothingIsRemovedWhileTheBrowserRuns() throws {
        let box = try Sandbox()
        try makeArc(box)
        let s = scanner(box)
        let r = cleaner(s, running: [RunningApp(bundleID: "company.thebrowser.Browser", name: "Arc")]).clean(s.scanServiceWorkerStorage())
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.blockedApps, ["Arc"])
        XCTAssertTrue(exists(box, "\(support)/Default/Service Worker/CacheStorage/origin1/index.txt"))
    }

    func testLinksAreNeverFollowed() throws {
        let box = try Sandbox()
        let project = try box.file("Developer/proj/CacheStorage/precious", bytes: 3_000_000).deletingLastPathComponent()
        try box.file("\(support)/Default/Service Worker/Database/x", bytes: 1_000)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(support)/Default/Service Worker/CacheStorage"),
                                                   withDestinationURL: project)
        XCTAssertTrue(BrowserCaches.serviceWorkerTargets(of: arc, home: box.home).isEmpty)
        let s = scanner(box)
        let f = Finding(id: "x", ecosystem: .browsers, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .download,
                        action: .removeServiceWorkerStorage(browserID: "arc"))
        XCTAssertEqual(cleaner(s).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, "Developer/proj/CacheStorage/precious"))
    }

    func testALinkAboveTheRootIsNeverFollowed() throws {
        let box = try Sandbox()
        let project = try box.file("Developer/proj/User Data/Default/Service Worker/CacheStorage/precious", bytes: 3_000_000)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Application Support/Arc"), withDestinationURL: project)
        XCTAssertTrue(BrowserCaches.serviceWorkerTargets(of: arc, home: box.home).isEmpty)
    }

    func testAnUnknownBrowserIsRefused() throws {
        let box = try Sandbox()
        try makeArc(box)
        let f = Finding(id: "x", ecosystem: .browsers, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .download,
                        action: .removeServiceWorkerStorage(browserID: "nope"))
        XCTAssertEqual(cleaner(scanner(box)).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, "\(support)/Default/Service Worker/CacheStorage/origin1/index.txt"))
    }

    // MARK: The guard and the shapes

    func testTheGuardAllowsOnlyTheCacheStorageFolderItself() throws {
        let box = try Sandbox()
        try makeArc(box)
        let g = PathGuard(home: box.home)
        func check(_ rel: String) -> Refusal? { g.check(box.home.appendingPathComponent("\(support)/Default/\(rel)")) }
        XCTAssertNil(check("Service Worker/CacheStorage"))
        for refused in ["Service Worker", "Service Worker/Database", "Service Worker/ScriptCache", "Service Worker/CacheStorage/origin1",
                        "Service Worker/CacheStorage/origin1/index.txt", "Service Worker/cachestorage2", "Cookies", "IndexedDB", "Extensions"] {
            XCTAssertNotNil(check(refused), "\(refused) must be refused")
        }
        XCTAssertNotNil(g.check(box.home.appendingPathComponent("\(support)/Guest Profile/Service Worker/CacheStorage")), "Not a profile that we clean")
    }

    func testServiceWorkerShape() {
        func shape(_ p: String) -> Bool { BrowserCaches.isServiceWorkerShape(relative: p) }
        XCTAssertTrue(shape("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage"))
        XCTAssertTrue(shape("Library/Application Support/BraveSoftware/Brave-Browser/Profile 2/Service Worker/CacheStorage"))
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/Default/Service Worker/Database"))
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/Default/Service Worker"))
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage/x"))
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/Service Worker/CacheStorage"), "No profile")
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/Default/Extra/Service Worker/CacheStorage"), "An extra folder before the name")
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/Default/Extensions/abc/Service Worker/CacheStorage"), "An extension folder")
        XCTAssertFalse(shape("Library/Caches/Firefox/Profiles/abcd1234.default/Service Worker/CacheStorage"), "Firefox")
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/Default/../Default/Service Worker/CacheStorage"))
        XCTAssertFalse(BrowserCaches.isCacheShape(relative: "Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage"),
                       "It is not an ordinary cache. It is its own kind, with its own item.")
    }

    // MARK: The words

    func testTheDialogWarnsAboutOfflineSitesAndKeepsByDefault() {
        let f = Finding(id: "x", ecosystem: .browsers, title: "Service Worker storage · Arc", location: "Where", bytes: 316_000_000,
                        tier: .review, rebuild: .download, action: .removeServiceWorkerStorage(browserID: "arc"))
        XCTAssertEqual(Confirmation.kind(of: f), .serviceWorker)
        let c = Confirmation.forOne(f, staleDays: 30)
        XCTAssertEqual(c.title, "Remove saved website data?")
        XCTAssertTrue(c.footer!.contains("work offline"))
        XCTAssertTrue(c.footer!.contains("can't be undone"))
        XCTAssertEqual(c.confirmTitle, "Remove data")
        XCTAssertTrue(c.cancelIsDefault, "The default button keeps it")
    }
}
