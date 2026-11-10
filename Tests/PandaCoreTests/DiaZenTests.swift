import XCTest
@testable import PandaCore

final class DiaZenTests: XCTestCase {
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ s: DiskScanner, running: [RunningApp] = []) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testDiaIsCleanedLikeAChromiumBrowser() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Dia/User Data/Default/Cache/f", bytes: 3_000_000)
        try box.file("Library/Application Support/Dia/User Data/Default/GPUCache/d", bytes: 2_000_000)
        for u in ["Cookies", "Login Data", "History", "Service Worker/CacheStorage/x"] { try box.file("Library/Application Support/Dia/User Data/Default/\(u)", bytes: 1_000) }
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanBrowserCaches().first { $0.id == "browser.cache:dia" })
        XCTAssertEqual(item.title, "Browser caches · Dia")
        XCTAssertEqual(cleaner(s).clean([item]).removed, 1)
        XCTAssertFalse(exists(box, "Library/Caches/Dia/User Data/Default/Cache"))
        for keep in ["Cookies", "Login Data", "History", "Service Worker/CacheStorage/x"] {
            XCTAssertTrue(exists(box, "Library/Application Support/Dia/User Data/Default/\(keep)"), keep)
        }
    }

    func testDiaRunningBlocks() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Dia/User Data/Default/Cache/f", bytes: 3_000_000)
        let s = scanner(box)
        let r = cleaner(s, running: [RunningApp(bundleID: "company.thebrowser.dia", name: "Dia")]).clean(s.scanBrowserCaches())
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.blockedApps, ["Dia"])
    }

    func testZenIsCleanedLikeFirefoxAndItsProfileStays() throws {
        let box = try Sandbox()
        let p = "abcd1234.Default (release)".replacingOccurrences(of: " (release)", with: "-release")
        try box.file("Library/Caches/zen/Profiles/\(p)/cache2/e", bytes: 3_000_000)
        try box.file("Library/Caches/zen/Profiles/\(p)/startupCache/s", bytes: 2_000_000)
        try box.file("Library/Application Support/zen/Profiles/\(p)/cookies.sqlite", bytes: 1_000)
        try box.file("Library/Application Support/zen/Profiles/\(p)/places.sqlite", bytes: 1_000)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanBrowserCaches().first { $0.id == "browser.cache:zen" })
        XCTAssertEqual(cleaner(s).clean([item]).removed, 1)
        XCTAssertFalse(exists(box, "Library/Caches/zen/Profiles/\(p)/cache2"))
        XCTAssertTrue(exists(box, "Library/Application Support/zen/Profiles/\(p)/cookies.sqlite"))
        XCTAssertTrue(exists(box, "Library/Application Support/zen/Profiles/\(p)/places.sqlite"))
        let r = cleaner(s, running: [RunningApp(bundleID: "app.zen-browser.zen", name: "Zen")])
        XCTAssertEqual(r.clean([item]).removed, 0, "Zen running blocks")
    }

    func testBundleIDsAreDistinctFromTheOtherBrowsers() {
        XCTAssertEqual(Set(BrowserCaches.browsers.map(\.bundleID)).count, BrowserCaches.browsers.count)
        XCTAssertNotNil(BrowserCaches.browser(id: "dia"))
        XCTAssertEqual(BrowserCaches.browser(id: "zen")?.kind, .firefox)
    }
}
