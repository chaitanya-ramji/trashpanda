import XCTest
@testable import PandaCore

final class TestBrowsersTests: XCTestCase {
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ s: DiskScanner, programs: [String] = []) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider, programPaths: { programs })
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private let pw = "Library/Caches/ms-playwright"
    private func makePlaywright(_ box: Sandbox) throws {
        for v in ["1200", "1248", "1300"] {
            try box.file("\(pw)/chromium-\(v)/chrome", bytes: 3_000_000)
            try box.file("\(pw)/chromium_headless_shell-\(v)/shell", bytes: 2_000_000)
        }
        try box.file("\(pw)/ffmpeg-1013/ffmpeg", bytes: 1_500_000)      // only one: it is the newest, stays
        try box.file("\(pw)/.links/x", bytes: 10)
        try box.file("\(pw)/notes/readme", bytes: 3_000_000)             // name does not parse
    }

    func testOldPlaywrightVersionsOnlyNewestOfEachKindStays() throws {
        let box = try Sandbox()
        try makePlaywright(box)
        let tool = TestBrowsers.tool(id: "playwright")!
        let names = Set(TestBrowsers.oldVersions(of: tool, home: box.home).map(\.lastPathComponent))
        XCTAssertEqual(names, ["chromium-1200", "chromium-1248", "chromium_headless_shell-1200", "chromium_headless_shell-1248"])
    }

    func testVersionsCompareAsNumbers() {
        XCTAssertTrue(TestBrowsers.isNewer([1000], than: [999]))
        XCTAssertTrue(TestBrowsers.isNewer([121, 0, 6167, 85], than: [121, 0, 6167, 9]))
        XCTAssertFalse(TestBrowsers.isNewer([1, 2], than: [1, 2, 0]))
        XCTAssertFalse(TestBrowsers.isNewer([1], than: [2]))
    }

    func testCleanRemovesOldAndKeepsNewestAndUnknown() throws {
        let box = try Sandbox()
        try makePlaywright(box)
        let s = scanner(box)
        let items = s.scanTestBrowsers()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Old test browsers · Playwright")
        XCTAssertEqual(items[0].tier, .safe)
        let r = cleaner(s).clean(items)
        XCTAssertEqual(r.removed, 1)
        XCTAssertGreaterThan(r.freed, 9_000_000)
        for gone in ["chromium-1200", "chromium-1248", "chromium_headless_shell-1200", "chromium_headless_shell-1248"] { XCTAssertFalse(exists(box, "\(pw)/\(gone)"), gone) }
        for kept in ["chromium-1300", "chromium_headless_shell-1300", "ffmpeg-1013", ".links/x", "notes/readme"] { XCTAssertTrue(exists(box, "\(pw)/\(kept)"), kept) }
        XCTAssertTrue(s.scanTestBrowsers().isEmpty)
    }

    func testNothingWhenOnlyOneVersion() throws {
        let box = try Sandbox()
        try box.file("\(pw)/chromium-1300/chrome", bytes: 3_000_000)
        XCTAssertTrue(scanner(box).scanTestBrowsers().isEmpty)
    }

    func testCypressKeepsNewest() throws {
        let box = try Sandbox()
        for v in ["12.17.4", "13.6.0", "13.10.0"] { try box.file("Library/Caches/Cypress/\(v)/Cypress.app/x", bytes: 3_000_000) }
        try box.file("Library/Caches/Cypress/readme", bytes: 3_000_000)
        let s = scanner(box)
        _ = cleaner(s).clean(s.scanTestBrowsers())
        XCTAssertFalse(exists(box, "Library/Caches/Cypress/12.17.4"))
        XCTAssertFalse(exists(box, "Library/Caches/Cypress/13.6.0"))
        XCTAssertTrue(exists(box, "Library/Caches/Cypress/13.10.0"))
        XCTAssertTrue(exists(box, "Library/Caches/Cypress/readme"))
    }

    func testPuppeteerNestedKeepsNewestPerBrowser() throws {
        let box = try Sandbox()
        for p in ["chrome/mac_arm-120.0.6099.109", "chrome/mac_arm-121.0.6167.85", "chrome-headless-shell/mac_arm-120.0.6099.109"] {
            try box.file(".cache/puppeteer/\(p)/bin", bytes: 3_000_000)
        }
        let s = scanner(box)
        _ = cleaner(s).clean(s.scanTestBrowsers())
        XCTAssertFalse(exists(box, ".cache/puppeteer/chrome/mac_arm-120.0.6099.109"))
        XCTAssertTrue(exists(box, ".cache/puppeteer/chrome/mac_arm-121.0.6167.85"))
        XCTAssertTrue(exists(box, ".cache/puppeteer/chrome-headless-shell/mac_arm-120.0.6099.109"), "Only one of its kind: newest")
    }

    func testAVersionInUseStays() throws {
        let box = try Sandbox()
        try makePlaywright(box)
        let s = scanner(box)
        let running = box.home.appendingPathComponent("\(pw)/chromium-1200/chrome").standardizedFileURL.path
        let r = cleaner(s, programs: [running]).clean(s.scanTestBrowsers())
        XCTAssertTrue(exists(box, "\(pw)/chromium-1200/chrome"), "A program runs from it")
        XCTAssertFalse(exists(box, "\(pw)/chromium-1248"))
        XCTAssertTrue(r.skipped.contains { $0.contains("runs from it") })
    }

    func testLinksAreNeverFollowed() throws {
        let box = try Sandbox()
        let project = try box.file("Developer/proj/data", bytes: 3_000_000).deletingLastPathComponent()
        try box.file("\(pw)/chromium-1300/chrome", bytes: 1_000)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(pw)/chromium-1200"), withDestinationURL: project)
        let tool = TestBrowsers.tool(id: "playwright")!
        XCTAssertTrue(TestBrowsers.oldVersions(of: tool, home: box.home).isEmpty, "A link is not a version folder")
        // a link ABOVE the root: Library/Caches is a link to a project folder that holds ms-playwright
        let box2 = try Sandbox()
        try box2.file("Developer/p/caches/ms-playwright/chromium-1/x", bytes: 3_000_000)
        try box2.file("Developer/p/caches/ms-playwright/chromium-2/x", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box2.home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box2.home.appendingPathComponent("Library/Caches"),
                                                   withDestinationURL: box2.home.appendingPathComponent("Developer/p/caches"))
        XCTAssertTrue(TestBrowsers.oldVersions(of: tool, home: box2.home).isEmpty, "A path with a link in it is not used")
    }

    func testParsingRejectsOddNames() {
        let pwt = TestBrowsers.tool(id: "playwright")!, cy = TestBrowsers.tool(id: "cypress")!
        XCTAssertNotNil(TestBrowsers.parse(name: "chromium-1248", tool: pwt))
        for bad in ["chromium", "1248", "-1248", "chromium-12x", "Chromium-1248", "chromium-1248-extra", ".links", "chromium-"] { XCTAssertNil(TestBrowsers.parse(name: bad, tool: pwt), bad) }
        XCTAssertNotNil(TestBrowsers.parse(name: "13.6.0", tool: cy))
        for bad in ["13.6", "13.6.0.1", "v13.6.0", "latest", "13.6.x"] { XCTAssertNil(TestBrowsers.parse(name: bad, tool: cy), bad) }
    }

    func testUnknownToolRefused() throws {
        let box = try Sandbox()
        try makePlaywright(box)
        let f = Finding(id: "x", ecosystem: .javascript, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                        action: .removeOldTestBrowsers(toolID: "../x"))
        XCTAssertEqual(cleaner(scanner(box)).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, "\(pw)/chromium-1200"))
    }
}
