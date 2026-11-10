import XCTest
@testable import PandaCore

/// The guard of `~/Library/Caches`. The folder itself, iCloud data, and the caches of macOS can never be deleted by a path.
final class LibraryCachesGuardTests: XCTestCase {
    private func check(_ box: Sandbox, _ rel: String) -> Refusal? { PathGuard(home: box.home).check(box.home.appendingPathComponent(rel)) }

    func testTheCachesFolderItselfIsRefused() throws {
        let box = try Sandbox()
        XCTAssertNotNil(check(box, "Library/Caches"))
    }

    func testICloudAndAppleFoldersAreRefusedWithEverythingInThem() throws {
        let box = try Sandbox()
        for rel in ["CloudKit", "CloudKit/x", "CloudKit/a/b/c", "FamilyCircle", "GeoServices", "GeoServices/Cache", "com.apple.bird", "com.apple.Safari/WebKit",
                    "com.apple.dt.Xcode", "com.apple.anything.new", "com.apple.photolibraryd/x", "cloudkit", "CLOUDKIT/x", "COM.APPLE.mail", "Cloudkit"] {
            XCTAssertNotNil(check(box, "Library/Caches/\(rel)"), rel)
        }
    }

    func testOtherCachesStayCleanable() throws {
        let box = try Sandbox()
        for rel in ["pnpm", "Yarn", "Google/Chrome/Default", "org.swift.swiftpm", "company.thebrowser.Browser", "Adobe", "com.example.app", "comapple", "apple.com", "CloudKit2",
                    "MyCloudKit"] {
            XCTAssertNil(check(box, "Library/Caches/\(rel)"), rel)
        }
    }

    func testAForgedActionCannotEmptyTheWholeCachesFolder() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/CloudKit/data", bytes: 2_000_000)
        try box.file("Library/Caches/com.apple.bird/data", bytes: 2_000_000)
        try box.file("Library/Caches/Adobe/data", bytes: 2_000_000)
        let caches = box.home.appendingPathComponent("Library/Caches")
        let s = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let forged = Finding(id: "f", ecosystem: .python, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download, action: .removeContents(caches))
        let report = Cleaner(guardian: s.guardian, runningApps: FakeRunning(apps: []).provider).clean([forged])
        XCTAssertEqual(report.removed, 0)
        for keep in ["CloudKit/data", "com.apple.bird/data", "Adobe/data"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("Library/Caches/\(keep)").path), keep)
        }
    }

    func testAForgedActionOnAProtectedChildIsRefused() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/CloudKit/data", bytes: 2_000_000)
        let s = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        for url in [box.home.appendingPathComponent("Library/Caches/CloudKit"), box.home.appendingPathComponent("Library/Caches/CloudKit/data")] {
            let f = Finding(id: "f", ecosystem: .python, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download, action: .removeContents(url))
            XCTAssertEqual(Cleaner(guardian: s.guardian, runningApps: FakeRunning(apps: []).provider).clean([f]).removed, 0)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("Library/Caches/CloudKit/data").path))
    }

    func testTheExistingCleanersOfCachesStillWork() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Yarn/v6/x", bytes: 2_000_000)
        try box.file("Library/Caches/pnpm/x", bytes: 2_000_000)
        let s = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let found = s.scanCaches()
        XCTAssertEqual(found.count, 2, "The guard does not hide the catalog items")
        XCTAssertEqual(Cleaner(guardian: s.guardian, runningApps: FakeRunning(apps: []).provider).clean(found).removed, 2)
    }
}
