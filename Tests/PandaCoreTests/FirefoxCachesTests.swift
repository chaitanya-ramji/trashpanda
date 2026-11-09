import XCTest
@testable import PandaCore

final class FirefoxCachesTests: XCTestCase {
    private let profile = "abcd1234.default-release"
    private let support = "Library/Application Support/Firefox/Profiles"
    private let caches = "Library/Caches/Firefox/Profiles"

    /// What a Firefox profile holds that must never be touched.
    private func userData(_ p: String) -> [String] {
        ["cookies.sqlite", "places.sqlite", "key4.db", "logins.json", "prefs.js", "formhistory.sqlite", "permissions.sqlite",
         "extensions/addon@x.xpi", "storage/default/https+++site/idb/x", "sessionstore-backups/recovery.jsonlz4", "bookmarkbackups/b.jsonlz4",
         "containers.json", "cert9.db"].map { "\(support)/\(p)/\($0)" }
    }

    private func makeProfile(_ box: Sandbox, _ p: String? = nil) throws -> [URL] {
        let p = p ?? profile
        try box.file("\(caches)/\(p)/cache2/entries/ABCDEF", bytes: 3_000_000)
        try box.file("\(caches)/\(p)/startupCache/startupCache.8.little", bytes: 2_000_000)
        try box.file("\(caches)/\(p)/thumbnails/t.png", bytes: 3_000_000)                // not on the list
        for path in userData(p) { try box.file(path, bytes: 1_000) }
        return ["cache2", "startupCache"].map { box.home.appendingPathComponent("\(caches)/\(p)/\($0)") }
    }

    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ s: DiskScanner, running: [RunningApp] = []) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private var firefox: Browser { BrowserCaches.browser(id: "firefox")! }

    func testOneSafeItemThatNamesFirefox() throws {
        let box = try Sandbox()
        _ = try makeProfile(box)
        let item = try XCTUnwrap(scanner(box).scanBrowserCaches().first { $0.id == "browser.cache:firefox" })
        XCTAssertEqual(item.title, "Browser caches · Firefox")
        XCTAssertEqual(item.tier, .safe)
        XCTAssertTrue(item.bytes >= 5_000_000 && item.bytes < 6_500_000, "cache2 + startupCache only: \(item.bytes)")
        XCTAssertTrue(item.location.contains("~/Library/Caches/Firefox/Profiles"))
    }

    func testOnlyCache2AndStartupCacheAreTargets() throws {
        let box = try Sandbox()
        let cleanable = try makeProfile(box)
        XCTAssertEqual(Set(BrowserCaches.targets(of: firefox, home: box.home).map(\.path)), Set(cleanable.map(\.path)))
    }

    func testSeveralProfiles() throws {
        let box = try Sandbox()
        let a = try makeProfile(box, "abcd1234.default-release"), b = try makeProfile(box, "wxyz9876.dev-edition-default")
        XCTAssertEqual(BrowserCaches.targets(of: firefox, home: box.home).count, a.count + b.count)
    }

    func testACleanLeavesEveryFileOfTheUser() throws {
        let box = try Sandbox()
        let cleanable = try makeProfile(box)
        let s = scanner(box)
        let report = cleaner(s).clean(s.scanBrowserCaches().filter { $0.id == "browser.cache:firefox" })
        XCTAssertEqual(report.removed, 1)
        XCTAssertGreaterThan(report.freed, 5_000_000)
        for url in cleanable { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
        for path in userData(profile) { XCTAssertTrue(exists(box, path), "\(path) must stay") }
        XCTAssertTrue(exists(box, "\(caches)/\(profile)/thumbnails/t.png"), "A folder that is not on the list stays")
        XCTAssertTrue(exists(box, "\(caches)/\(profile)"), "The profile folder stays")
    }

    func testNothingIsRemovedWhileFirefoxOrItsFamilyRuns() throws {
        for app in [RunningApp(bundleID: "org.mozilla.firefox", name: "Firefox"),
                    RunningApp(bundleID: "org.mozilla.firefoxdeveloperedition", name: "Firefox Developer Edition"),
                    RunningApp(bundleID: "org.mozilla.nightly", name: "Firefox Nightly")] {
            let box = try Sandbox()
            let cleanable = try makeProfile(box)
            let s = scanner(box)
            let blocked = cleaner(s, running: [app]).clean(s.scanBrowserCaches().filter { $0.id == "browser.cache:firefox" })
            if app.bundleID == "org.mozilla.nightly" {
                // Nightly has its own folder name in practice. The family name is "org.mozilla.firefox*", so it does not match.
                XCTAssertEqual(blocked.removed, 1, "Nightly is not matched by the Firefox family")
            } else {
                XCTAssertEqual(blocked.removed, 0, app.name)
                XCTAssertEqual(blocked.blockedApps, [app.name])
                XCTAssertTrue(cleanable.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            }
        }
    }

    func testAChromiumBrowserRunningDoesNotBlockFirefox() throws {
        let box = try Sandbox()
        _ = try makeProfile(box)
        let s = scanner(box)
        let r = cleaner(s, running: [RunningApp(bundleID: "company.thebrowser.Browser", name: "Arc")])
            .clean(s.scanBrowserCaches().filter { $0.id == "browser.cache:firefox" })
        XCTAssertEqual(r.removed, 1)
    }

    func testProfileNames() {
        for ok in ["abcd1234.default-release", "A1b2C3d4.default", "12345678.dev-edition-default", "abcd1234.Profile 1".replacingOccurrences(of: " ", with: "_")] {
            XCTAssertTrue(BrowserCaches.isFirefoxProfileName(ok), ok)
        }
        for bad in ["", "default", "Profiles", "abcd123.default", "abcd12345.default", "abcd1234", "abcd1234.", "abcd1234..x", "abcd1234.a/b",
                    "../abcd1234.x", "abcd1234.x ", "Default", "Profile 1", "abcd-123.default"] {
            XCTAssertFalse(BrowserCaches.isFirefoxProfileName(bad), bad)
        }
    }

    func testLinksAreNeverFollowed() throws {
        let box = try Sandbox()
        let project = try box.file("Developer/proj/cache2/precious", bytes: 3_000_000).deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(caches), withIntermediateDirectories: true)
        // The profile folder is a link. And a real profile has a link as its cache2.
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(caches)/linkpro1.default"), withDestinationURL: project)
        try box.file("\(caches)/realpro1.default/startupCache/x", bytes: 1_000)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(caches)/realpro1.default/cache2"),
                                                   withDestinationURL: project.appendingPathComponent("cache2"))
        XCTAssertEqual(BrowserCaches.targets(of: firefox, home: box.home).map(\.lastPathComponent), ["startupCache"],
                       "Only the real folder is a target")
        let s = scanner(box)
        _ = cleaner(s).clean(s.scanBrowserCaches())
        XCTAssertTrue(exists(box, "Developer/proj/cache2/precious"), "The project files are safe")
    }

    func testALinkAboveTheRootIsNeverFollowed() throws {
        let box = try Sandbox()
        let project = try box.file("Developer/proj/Profiles/abcd1234.default/cache2/precious", bytes: 3_000_000)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches/Firefox"), withDestinationURL: project)
        XCTAssertTrue(BrowserCaches.targets(of: firefox, home: box.home).isEmpty)
    }

    func testTheGuardStillProtectsTheProfileOfFirefox() throws {
        let box = try Sandbox()
        _ = try makeProfile(box)
        let g = PathGuard(home: box.home)
        for p in userData(profile) { XCTAssertNotNil(g.check(box.home.appendingPathComponent(p)), "\(p) must be refused") }
        XCTAssertNotNil(g.check(box.home.appendingPathComponent("\(support)/\(profile)")), "The profile folder")
        XCTAssertNotNil(g.check(box.home.appendingPathComponent("Library/Application Support/Firefox")))
        // The Firefox cache shape is not an exception for Application Support: those paths stay protected.
        XCTAssertNotNil(g.check(box.home.appendingPathComponent("\(support)/\(profile)/cache2")))
        XCTAssertNil(g.check(box.home.appendingPathComponent("\(caches)/\(profile)/cache2")), "In Library/Caches it is a cache")
    }

    func testCacheShapeKnowsTheTwoKindsApart() {
        func shape(_ p: String) -> Bool { BrowserCaches.isCacheShape(relative: p) }
        XCTAssertTrue(shape("Library/Caches/Firefox/Profiles/abcd1234.default-release/cache2"))
        XCTAssertTrue(shape("Library/Caches/Firefox/Profiles/abcd1234.default-release/startupCache"))
        XCTAssertFalse(shape("Library/Caches/Firefox/Profiles/abcd1234.default-release/cookies.sqlite"))
        XCTAssertFalse(shape("Library/Caches/Firefox/Profiles/Default/cache2"), "A Chromium profile name in a Firefox folder")
        XCTAssertFalse(shape("Library/Caches/Firefox/Profiles/abcd1234.default-release/Cache"), "A Chromium name in a Firefox profile")
        XCTAssertFalse(shape("Library/Caches/Google/Chrome/abcd1234.default-release/cache2"), "A Firefox name in a Chromium folder")
        XCTAssertFalse(shape("Library/Application Support/Firefox/Profiles/abcd1234.default-release/cache2"))
    }

    func testTheNamesNeverIncludeUserData() {
        for danger in ["cookies.sqlite", "places.sqlite", "key4.db", "logins.json", "storage", "extensions", "sessionstore-backups",
                       "bookmarkbackups", "formhistory.sqlite", "prefs.js", "cert9.db"] {
            XCTAssertFalse(BrowserCaches.firefoxCacheNames.contains(danger), danger)
        }
        XCTAssertEqual(BrowserCaches.firefoxCacheNames, ["cache2", "startupCache"])
    }
}
