import XCTest
@testable import PandaCore

/// #20: a read-only list of the largest folders in Library/Caches, with a label for each.
final class CacheExplorerTests: XCTestCase {
    private let mb = 1_500_000
    private func makeCaches(_ box: Sandbox, _ sizes: [(String, Int)]) throws {
        for (name, bytes) in sizes { try box.file("Library/Caches/\(name)/data", bytes: bytes) }
    }
    private func scanner(_ box: Sandbox, names: [String: String] = [:]) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false, appName: { names[$0] })
    }
    private func entries(_ box: Sandbox, cleanable: Set<String> = [], names: [String: String] = [:], limit: Int = 10) -> [CacheExplorer.Entry] {
        CacheExplorer.entries(home: box.home, cleanable: cleanable, appName: { names[$0] }, limit: limit)
    }

    // MARK: The labels

    func testCloudKitIsKeepWithAShortReason() throws {
        let box = try Sandbox()
        try makeCaches(box, [("CloudKit", 30 * mb)])
        let e = try XCTUnwrap(entries(box).first)
        XCTAssertEqual(e.folder, "CloudKit")
        XCTAssertEqual(e.label, .keep)
        XCTAssertTrue(e.reason.contains("iCloud"), e.reason)
        XCTAssertLessThan(e.reason.count, 90, "A short reason")
    }

    func testEveryLabel() {
        let cleanable: Set<String> = ["pnpm", "Yarn", "com.apple.dt.Xcode"]
        func l(_ f: String) -> CacheLabel { CacheExplorer.label(for: f, cleanable: cleanable).0 }
        XCTAssertEqual(l("pnpm"), .canClean)
        XCTAssertEqual(l("com.apple.dt.Xcode"), .canClean, "An item of its own comes before the Apple rule")
        for keep in ["CloudKit", "GeoServices", "com.apple.bird", "com.apple.Safari", "com.apple.photolibraryd", "com.apple.mail", "com.apple.helpd", "com.apple.anything.else", "FamilyCircle"] {
            XCTAssertEqual(l(keep), .keep, keep)
        }
        for unknown in ["Adobe", "company.thebrowser.Browser", "SomeApp", "com.example.app", "apple", "com.applesauce"] {
            XCTAssertEqual(l(unknown), .unknown, unknown)
        }
    }

    func testAnUnknownFolderHasAnHonestReasonAndNoOtherLabelIsInvented() {
        let (label, reason) = CacheExplorer.label(for: "Adobe", cleanable: [])
        XCTAssertEqual(label, .unknown)
        XCTAssertTrue(reason.contains("do not know"), reason)
        XCTAssertEqual(Set(["can clean", "keep", "unknown"]), Set([CacheLabel.canClean, .keep, .unknown].map(\.rawValue)))
    }

    func testTheCatalogNamesAreFound() {
        let names = CacheExplorer.cleanableNames(paths: ["Library/Caches/pnpm", "Library/pnpm/store", ".cache/uv", "Library/Caches/Google/Chrome/Default", "Library/Caches/org.swift.swiftpm",
                                                         "Library/Caches"])
        XCTAssertEqual(names, ["pnpm", "Google", "org.swift.swiftpm"])
    }

    // MARK: The list

    func testTheTenLargestInOrder() throws {
        let box = try Sandbox()
        try makeCaches(box, (1...14).map { ("App\($0)", ($0 + 10) * mb) })
        let e = entries(box)
        XCTAssertEqual(e.count, 10)
        XCTAssertEqual(e.map(\.folder), (5...14).reversed().map { "App\($0)" }, "Largest first, and the four smallest are cut")
        XCTAssertEqual(entries(box, limit: 3).count, 3)
    }

    func testSmallFoldersFilesAndLinksAreLeftOut() throws {
        let box = try Sandbox()
        try makeCaches(box, [("Big", 20 * mb), ("Tiny", 1_000)])
        try box.file("Library/Caches/loose-file.bin", bytes: 30 * mb)
        try box.file("elsewhere/x", bytes: 40 * mb)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches/Linked"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertEqual(entries(box).map(\.folder), ["Big"])
    }

    func testACachesFolderThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/App/x", bytes: 40 * mb)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Caches"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(entries(box).isEmpty)
    }

    func testNothingWhenThereIsNoCachesFolder() throws {
        XCTAssertTrue(entries(try Sandbox()).isEmpty)
    }

    func testBundleIDsGetTheNameOfTheApp() throws {
        let box = try Sandbox()
        try makeCaches(box, [("company.thebrowser.Browser", 30 * mb), ("Adobe", 20 * mb), ("com.unknown.app", 15 * mb)])
        let e = entries(box, names: ["company.thebrowser.Browser": "Arc"])
        XCTAssertEqual(e.map(\.displayName), ["Arc", "Adobe", "com.unknown.app"])
        XCTAssertEqual(e.map(\.folder), ["company.thebrowser.Browser", "Adobe", "com.unknown.app"])
    }

    // MARK: The menu items are read only

    func testTheItemsAreReviewItemsAndInNoOneClickTotal() throws {
        let box = try Sandbox()
        try makeCaches(box, [("CloudKit", 30 * mb), ("pnpm", 20 * mb), ("Adobe", 15 * mb)])
        let found = scanner(box).scanCacheExplorer()
        XCTAssertEqual(Set(found.map(\.title)), ["CloudKit · system cache", "Adobe · cache folder"], "pnpm has its own item, so it is not here")
        for f in found {
            XCTAssertEqual(f.ecosystem, .cacheExplorer)
            XCTAssertEqual(f.tier, .review)
            XCTAssertTrue(f.isActionable)
            XCTAssertNotNil(f.note)
        }
        let result = ScanResult(findings: found, disk: DiskUsage(total: 1, free: 1))
        XCTAssertEqual(result.reclaimable, 0, "Never in the one-click clean")
        XCTAssertEqual(result.reviewable, found.reduce(0) { $0 + $1.bytes })
    }

    func testEveryRowInTheListCanBeRemoved() throws {
        let box = try Sandbox()
        try makeCaches(box, [("CloudKit", 30 * mb), ("pnpm", 20 * mb), ("Adobe", 20 * mb), ("com.apple.bird", 15 * mb)])
        let found = scanner(box).scanCacheExplorer()
        XCTAssertEqual(Set(found.map(\.location)), ["~/Library/Caches/CloudKit", "~/Library/Caches/Adobe", "~/Library/Caches/com.apple.bird"])
        XCTAssertTrue(found.allSatisfy(\.isActionable), "Nothing in the menu is read only")
    }

    func testFoldersThatHaveAnItemOfTheirOwnAreNotListedAgain() throws {
        let box = try Sandbox()
        try makeCaches(box, [("Homebrew", 30 * mb), ("go-build", 20 * mb), ("ms-playwright", 25 * mb), ("Yarn", 15 * mb), ("pypoetry", 12 * mb), ("Adobe", 11 * mb)])
        let found = scanner(box).scanCacheExplorer()
        XCTAssertEqual(found.map(\.location), ["~/Library/Caches/Adobe"], "The others have an item in the group of their tool, so they are not shown twice")
    }

    func testTwoFoldersWithTheSameAppNameCanBeToldApart() throws {
        let box = try Sandbox()
        try makeCaches(box, [("company.thebrowser.Browser", 30 * mb), ("Arc", 20 * mb)])
        let found = DiskScanner(home: box.home, config: Config(), useOwnerTools: false, appName: { $0 == "company.thebrowser.Browser" ? "Arc" : nil }).scanCacheExplorer()
        XCTAssertEqual(found.map(\.title), ["Arc (company.thebrowser.Browser) · cache folder"], "The folder named Arc has its own item")
    }
}
