import XCTest
@testable import PandaCore

/// One folder on disk is in one finding only. An action with an ID (browser, agent, editor) covers folders, and the cache explorer knows them.
final class OneFolderOneGroupTests: XCTestCase {
    private let mb = 3_500_000
    private func scanner(_ box: Sandbox, names: [String: String] = [:]) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false, appName: { names[$0] })
    }
    private func total(_ findings: [Finding]) -> Int64 { findings.filter(\.isActionable).reduce(Int64(0)) { $0 + $1.bytes } }
    private func explorerRow(_ folder: String, bytes: Int64) -> Finding {
        Finding(id: "cache.explorer:\(folder)", ecosystem: .cacheExplorer, title: "\(folder) · cache folder", location: "~/Library/Caches/\(folder)",
                bytes: bytes, tier: .review, rebuild: .download, action: .removeCacheFolderContents(name: folder))
    }

    func testAnAgentCacheFolderShowsInOneGroupOnly() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Codex/Default/Cache/a", bytes: 3 * mb)
        try box.file("Library/Caches/Codex/Default/Code Cache/b", bytes: mb)
        let s = scanner(box)
        let agent = s.scanAgents().filter { if case .agent(.removeAgentCaches) = $0.action { return true } else { return false } }
        XCTAssertEqual(agent.count, 1)
        // The explorer does not list the folder at all, because the rule of the agent names it.
        XCTAssertTrue(CacheExplorer.catalogNames().contains("Codex"))
        XCTAssertTrue(s.scanCacheExplorer().isEmpty)
        // Even a row that was made by hand is removed, because the agent item covers the folder.
        let merged = DiskScanner.removeOverlap(agent + [explorerRow("Codex", bytes: 4 * Int64(mb))], home: box.home)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.ecosystem, agent.first?.ecosystem)
    }

    func testABrowserCacheFolderShowsInOneGroupOnly() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Google/Chrome/Default/Cache/a", bytes: 3 * mb)
        try box.file("Library/Caches/Google/Chrome/Default/Code Cache/b", bytes: 2 * mb)
        let s = scanner(box)
        let browser = s.scanBrowserCaches()
        XCTAssertEqual(browser.count, 1)
        XCTAssertEqual(s.coveredURLs(of: browser[0]).count, 2)
        let merged = DiskScanner.removeOverlap(browser + [explorerRow("Google", bytes: 5 * Int64(mb))], home: box.home)
        XCTAssertEqual(merged.map(\.id), browser.map(\.id), "The explorer row is not shown")
        XCTAssertEqual(total(merged), browser[0].bytes)
    }

    func testAPartOfAFolderThatAnotherItemCoversIsTakenOff() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Google/Chrome/Default/Cache/a", bytes: 3 * mb)
        try box.file("Library/Caches/Google/other/b", bytes: 2 * mb)
        let s = scanner(box)
        let browser = s.scanBrowserCaches()
        let size = Sizer.size(of: box.home.appendingPathComponent("Library/Caches/Google"))
        let merged = DiskScanner.removeOverlap(browser + [explorerRow("Google", bytes: size)], home: box.home)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(total(merged), size, "The sum of the rows is not larger than the folder")
    }

    func testAnUpdateDownloadFolderShowsInOneGroupOnly() throws {
        let box = try Sandbox()
        let id = "com.example.App"
        let old = "Library/Caches/\(id)/org.sparkle-project.Sparkle/Installation/old"
        try box.file("\(old)/Update.zip", bytes: 4 * mb)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)],
                                              ofItemAtPath: box.home.appendingPathComponent(old).path)
        try box.file("Library/Caches/\(id)/keep/y", bytes: 3 * mb)
        let s = scanner(box, names: [id: "Example"])
        let updates = s.scanUpdateDownloads()
        XCTAssertEqual(updates.count, 1)
        let size = Sizer.size(of: box.home.appendingPathComponent("Library/Caches/\(id)"))
        let merged = DiskScanner.removeOverlap(updates + [explorerRow(id, bytes: size)], home: box.home)
        XCTAssertLessThanOrEqual(total(merged), size)
        XCTAssertEqual(merged.first { $0.id == updates[0].id }?.bytes, updates[0].bytes)
    }

    func testAnEditorFolderCoversItsCacheFolders() throws {
        let box = try Sandbox()
        try box.file("Library/Application Support/Code/CachedData/a", bytes: 3 * mb)
        let s = scanner(box)
        let finding = Finding(id: "e", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                              action: .agent(.removeEditorCaches(appID: "vscode")))
        XCTAssertEqual(s.coveredURLs(of: finding).map(\.lastPathComponent), ["CachedData"])
        let none = Finding(id: "n", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download,
                           action: .removeBrowserCaches(browserID: "no-such-browser"))
        XCTAssertTrue(s.coveredURLs(of: none).isEmpty)
    }
}
