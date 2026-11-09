import XCTest
@testable import PandaCore

final class BrowserCachesTests: XCTestCase {
    private let support = "Library/Application Support/Arc/User Data"
    private let caches = "Library/Caches/Arc/User Data"

    /// What a profile holds that must never be touched, as paths from the home folder.
    private func neverTouch(_ profile: String) -> [String] {
        ["Cookies", "Login Data", "History", "Preferences", "Web Data", "Bookmarks", "Favicons",
         "Local Storage/leveldb/000003.log", "IndexedDB/https_site_0.indexeddb.leveldb/x", "Session Storage/x", "Sessions/Session_1",
         "Extensions/abc/manifest.json", "Service Worker/CacheStorage/x", "Service Worker/Database/x", "File System/x",
         "Network/Cookies", "Sync Data/x"].map { "\(support)/\(profile)/\($0)" }
    }

    /// A realistic Arc profile in a fake home folder. Returns the folders that may be cleaned.
    private func makeArc(_ box: Sandbox, profiles: [String] = ["Default"]) throws -> [URL] {
        var cleanable: [URL] = []
        for p in profiles {
            for n in ["GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"] {
                try box.file("\(support)/\(p)/\(n)/data_0", bytes: 2_000_000)
                cleanable.append(box.home.appendingPathComponent("\(support)/\(p)/\(n)"))
            }
            for n in ["Cache", "Code Cache"] {
                try box.file("\(caches)/\(p)/\(n)/f_000001", bytes: 3_000_000)
                cleanable.append(box.home.appendingPathComponent("\(caches)/\(p)/\(n)"))
            }
            for path in neverTouch(p) { try box.file(path, bytes: 1_000) }
        }
        try box.file("Library/Caches/Arc/EaselImagesCache/img", bytes: 3_000_000)               // not on the list of names
        try box.file("\(caches)/Guest Profile/Cache/x", bytes: 3_000_000)                       // not a profile that we clean
        try box.file("\(caches)/System Profile/Cache/x", bytes: 3_000_000)
        return cleanable
    }

    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ s: DiskScanner, running: [RunningApp] = []) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    // MARK: Finding the folders

    func testOneSafeItemForABrowserThatNamesIt() throws {
        let box = try Sandbox()
        _ = try makeArc(box)
        let found = scanner(box).scanBrowserCaches()
        XCTAssertEqual(found.count, 1)
        let item = found[0]
        XCTAssertEqual(item.title, "Browser caches · Arc")
        XCTAssertEqual(item.ecosystem, .browsers)
        XCTAssertEqual(item.tier, .safe)
        XCTAssertEqual(item.rebuild, .download)
        XCTAssertEqual(item.id, "browser.cache:arc")
        XCTAssertTrue(item.bytes >= 12_000_000 && item.bytes < 14_000_000, "3 x 2 MB + 2 x 3 MB, and nothing else: \(item.bytes)")
        XCTAssertTrue(item.owner!.bundleIDs.contains("company.thebrowser.Browser"))
        XCTAssertTrue(item.location.contains("~/Library/Caches/Arc/User Data"), item.location)
    }

    func testOnlyTheNamedFoldersOfARealProfileAreTargets() throws {
        let box = try Sandbox()
        let cleanable = try makeArc(box)
        let arc = try XCTUnwrap(BrowserCaches.browser(id: "arc"))
        XCTAssertEqual(Set(BrowserCaches.targets(of: arc, home: box.home).map(\.path)), Set(cleanable.map(\.path)))
    }

    func testSeveralProfilesAreAllCleaned() throws {
        let box = try Sandbox()
        let cleanable = try makeArc(box, profiles: ["Default", "Profile 1", "Profile 12"])
        let arc = try XCTUnwrap(BrowserCaches.browser(id: "arc"))
        XCTAssertEqual(BrowserCaches.targets(of: arc, home: box.home).count, cleanable.count)
        XCTAssertEqual(cleanable.count, 15)
    }

    func testProfileNames() {
        for ok in ["Default", "Profile 1", "Profile 12", "Profile 007"] { XCTAssertTrue(BrowserCaches.isProfileName(ok), ok) }
        for bad in ["", "default", "Profile", "Profile x", "Profile 1 ", "Profile -1", "Default2", "Guest Profile", "System Profile",
                    "Profile 1/..", "../Default", "Crashpad", "GrShaderCache"] { XCTAssertFalse(BrowserCaches.isProfileName(bad), bad) }
    }

    func testSeveralBrowsersAreSeparateItems() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/Google/Chrome/Default/GPUCache/x", bytes: 3_000_000)
        try box.file("Library/Caches/Google/Chrome/Default/Cache/x", bytes: 3_000_000)
        try box.file("Library/Application Support/BraveSoftware/Brave-Browser/Profile 1/Code Cache/x", bytes: 3_000_000)
        try box.file("Library/Caches/Microsoft Edge/Default/Cache/x", bytes: 3_000_000)
        try box.file("Library/Caches/Vivaldi/Default/Cache/x", bytes: 3_000_000)
        try box.file("Library/Caches/com.operasoftware.Opera/Default/Cache/x", bytes: 3_000_000)
        XCTAssertEqual(Set(scanner(box).scanBrowserCaches().map(\.title)), [
            "Browser caches · Chrome", "Browser caches · Brave", "Browser caches · Edge", "Browser caches · Vivaldi", "Browser caches · Opera"])
    }

    func testNothingWhenThereIsNoBrowserOrNoCache() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanBrowserCaches().isEmpty)
        try box.file("\(support)/Default/Cookies", bytes: 3_000_000)                          // a profile with no cache folder
        XCTAssertTrue(scanner(box).scanBrowserCaches().isEmpty)
    }

    // MARK: The clean

    func testACleanRemovesTheCachesAndNothingElse() throws {
        let box = try Sandbox()
        let cleanable = try makeArc(box, profiles: ["Default", "Profile 2"])
        let s = scanner(box)
        let report = cleaner(s).clean(s.scanBrowserCaches())

        XCTAssertEqual(report.removed, 1)
        XCTAssertGreaterThan(report.freed, 20_000_000)
        for url in cleanable { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }

        // Everything that belongs to the user is still there.
        for p in ["Default", "Profile 2"] {
            for path in neverTouch(p) { XCTAssertTrue(exists(box, path), "\(path) must stay") }
        }
        XCTAssertTrue(exists(box, "Library/Caches/Arc/EaselImagesCache/img"), "A folder that is not on the list stays")
        XCTAssertTrue(exists(box, "\(caches)/Guest Profile/Cache/x"), "A profile that we do not clean stays")
        XCTAssertTrue(exists(box, "\(caches)/System Profile/Cache/x"))
        XCTAssertTrue(exists(box, "\(support)/Default"), "The profile folder stays")
        XCTAssertTrue(s.scanBrowserCaches().isEmpty, "It does not come back in the next scan")
    }

    func testNothingIsRemovedWhileTheBrowserRuns() throws {
        for app in [RunningApp(bundleID: "company.thebrowser.Browser", name: "Arc"),
                    RunningApp(bundleID: "company.thebrowser.Browser.helper.Renderer", name: "Arc Helper (Renderer)")] {
            let box = try Sandbox()
            let cleanable = try makeArc(box)
            let s = scanner(box)
            let report = cleaner(s, running: [app]).clean(s.scanBrowserCaches())
            XCTAssertEqual(report.removed, 0, app.name)
            XCTAssertEqual(report.blockedApps, [app.name])
            XCTAssertTrue(cleanable.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    func testAnotherBrowserRunningDoesNotBlock() throws {
        let box = try Sandbox()
        _ = try makeArc(box)
        let s = scanner(box)
        let report = cleaner(s, running: [RunningApp(bundleID: "com.google.Chrome", name: "Chrome")]).clean(s.scanBrowserCaches())
        XCTAssertEqual(report.removed, 1)
    }

    func testAnUnknownBrowserIsRefused() throws {
        let box = try Sandbox()
        _ = try makeArc(box)
        let f = Finding(id: "x", ecosystem: .browsers, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                        action: .removeBrowserCaches(browserID: "../../Documents"))
        let s = scanner(box)
        XCTAssertEqual(cleaner(s).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, "\(support)/Default/GPUCache/data_0"))
    }

    // MARK: Links

    func testALinkedProfileOrCacheFolderIsNeverFollowed() throws {
        let box = try Sandbox()
        let project = try box.file("Developer/proj/Cache/precious", bytes: 3_000_000).deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("\(caches)"), withIntermediateDirectories: true)
        // The profile folder is a link to a project. The cache folder inside a real profile is a link to a project.
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(caches)/Default"), withDestinationURL: project)
        try box.file("\(support)/Profile 1/GPUCache/x", bytes: 1_000)
        try FileManager.default.removeItem(at: box.home.appendingPathComponent("\(support)/Profile 1/GPUCache"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(support)/Profile 1/GPUCache"),
                                                   withDestinationURL: project.appendingPathComponent("Cache"))
        let s = scanner(box)
        XCTAssertTrue(s.scanBrowserCaches().isEmpty)
        let f = Finding(id: "x", ecosystem: .browsers, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                        action: .removeBrowserCaches(browserID: "arc"))
        XCTAssertEqual(cleaner(s).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, "Developer/proj/Cache/precious"), "The project files are safe")
    }

    func testALinkedRootIsNeverFollowed() throws {
        let box = try Sandbox()
        let project = try box.file("Developer/proj/Default/Cache/precious", bytes: 3_000_000)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library/Caches/Arc"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(caches), withDestinationURL: project)
        XCTAssertTrue(scanner(box).scanBrowserCaches().isEmpty)
    }

    /// A link in the MIDDLE of the path is the case that the type of the last part cannot see.
    func testALinkAboveTheRootIsNeverFollowed() throws {
        let box = try Sandbox()
        // ~/Library/Caches/Arc is a link to a project. Inside the project there is a real "User Data/Default/Cache".
        let project = try box.file("Developer/proj/User Data/Default/Cache/precious", bytes: 3_000_000)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches/Arc"), withDestinationURL: project)
        let arc = try XCTUnwrap(BrowserCaches.browser(id: "arc"))
        XCTAssertTrue(BrowserCaches.targets(of: arc, home: box.home).isEmpty, "A path with a link in it is not a target")
        let s = scanner(box)
        XCTAssertTrue(s.scanBrowserCaches().isEmpty)
        let f = Finding(id: "x", ecosystem: .browsers, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                        action: .removeBrowserCaches(browserID: "arc"))
        XCTAssertEqual(cleaner(s).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, "Developer/proj/User Data/Default/Cache/precious"), "The project files are safe")
    }

    func testALinkedCacheFolderIsNotATarget() throws {
        let box = try Sandbox()
        let project = try box.file("Developer/proj/Cache/precious", bytes: 3_000_000).deletingLastPathComponent()
        try box.file("\(support)/Default/Cookies", bytes: 1_000)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(support)/Default/GPUCache"), withDestinationURL: project)
        let arc = try XCTUnwrap(BrowserCaches.browser(id: "arc"))
        XCTAssertTrue(BrowserCaches.targets(of: arc, home: box.home).isEmpty, "A link is not a cache folder")
    }

    // MARK: The path guard exception

    func testTheGuardAllowsACacheFolderAndNothingElseInAProfile() throws {
        let box = try Sandbox()
        _ = try makeArc(box)
        let g = PathGuard(home: box.home)
        for allowed in ["GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"] {
            XCTAssertNil(g.check(box.home.appendingPathComponent("\(support)/Default/\(allowed)")), allowed)
        }
        XCTAssertNil(g.check(box.home.appendingPathComponent("\(caches)/Default/Cache")))
        for p in neverTouch("Default") {
            let url = box.home.appendingPathComponent(p)
            XCTAssertNotNil(g.check(url), "\(p) must be refused")
            XCTAssertNotNil(g.check(url.deletingLastPathComponent()), "\(url.deletingLastPathComponent().lastPathComponent) must be refused")
        }
        for refused in ["\(support)/Default", "\(support)", "Library/Application Support/Arc", "Library/Application Support",
                        "\(support)/Default/GPUCache/data_0", "\(support)/Guest Profile/GPUCache", "\(support)/Default/GPUCache2",
                        "Library/Application Support/Other App/Default/GPUCache",
                        "\(support)/Default/GPUCache/../Cookies", "\(support)/Profile/GPUCache"] {
            XCTAssertNotNil(g.check(box.home.appendingPathComponent(refused)), "\(refused) must be refused")
        }
    }

    func testCacheShape() {
        func shape(_ p: String) -> Bool { BrowserCaches.isCacheShape(relative: p) }
        XCTAssertTrue(shape("Library/Application Support/Google/Chrome/Default/GPUCache"))
        XCTAssertTrue(shape("Library/Caches/Google/Chrome/Profile 3/Code Cache"))
        XCTAssertTrue(shape("Library/Application Support/BraveSoftware/Brave-Browser/Default/ShaderCache"))
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/Default/Cookies"))
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/Default/Service Worker"))
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/GPUCache"), "No profile")
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/Default/GPUCache/x"), "Too deep")
        XCTAssertFalse(shape("Library/Application Support/Google/Default/GPUCache"), "Not the root of a browser")
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome/Default/../Default/Cookies"))
        XCTAssertFalse(shape("Library/Application Support/Google/Chrome//Default/GPUCache"))
        XCTAssertFalse(shape(""))
        XCTAssertFalse(shape("Library/Application Support/Safari/Default/Cache"), "Safari is not a Chromium browser")
    }

    func testTheNamesOnTheListNeverInclude() {
        for danger in ["Cookies", "Login Data", "History", "Local Storage", "IndexedDB", "Extensions", "Preferences", "Sessions",
                       "Service Worker", "Session Storage", "Web Data", "Bookmarks", "Network", "Sync Data", "File System"] {
            XCTAssertFalse(BrowserCaches.cacheNames.contains(danger), danger)
        }
        XCTAssertEqual(BrowserCaches.cacheNames.count, 8)
    }

    func testEveryBrowserHasADistinctBundleIDAndRoots() {
        let b = BrowserCaches.browsers
        XCTAssertEqual(Set(b.map(\.bundleID)).count, b.count)
        XCTAssertEqual(Set(b.map(\.id)).count, b.count)
        XCTAssertTrue(b.filter { $0.kind == .chromium }.allSatisfy {
            $0.roots.count == 2 && $0.roots[0].hasPrefix("Library/Application Support/") && $0.roots[1].hasPrefix("Library/Caches/") })
        XCTAssertEqual(b.filter { $0.kind == .firefox }.map(\.roots), [["Library/Caches/Firefox/Profiles"]],
                       "Firefox is cleaned only in Library/Caches. Its profile folder holds user data.")
    }
}
