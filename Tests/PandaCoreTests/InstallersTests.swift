import XCTest
@testable import PandaCore

final class InstallersTests: XCTestCase {
    private func scanner(_ box: Sandbox, keep: [String] = []) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(keep: keep), useOwnerTools: false)
    }
    private func cleaner(_ s: DiskScanner, mounted: [String] = []) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider,
                mountedImages: { mounted })
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func names(_ box: Sandbox) -> [String] { scanner(box).scanInstallers().map { $0.title } }

    // MARK: The type rule

    func testOnlyDmgAndPkgAreListed() throws {
        let box = try Sandbox()
        for n in ["a.dmg", "b.pkg", "c.zip", "d.app", "e.exe", "f.iso", "g.tar.gz", "h.dmg.download", "i.pkg.txt", "j.crdownload",
                  "k.txt", "dmg", "pkg", "l.mpkg", "m.xip"] {
            try box.file("Downloads/\(n)", bytes: 2_000_000, age: 90)
        }
        XCTAssertEqual(Set(names(box)), ["Installer · a.dmg", "Installer · b.pkg"])
    }

    func testTheTypeIsMatchedWithoutCase() throws {
        let box = try Sandbox()
        try box.file("Downloads/Big.DMG", bytes: 2_000_000, age: 90)
        try box.file("Downloads/Tool.Pkg", bytes: 2_000_000, age: 90)
        XCTAssertEqual(names(box).count, 2)
    }

    func testTheNameRule() {
        XCTAssertTrue(Installers.isInstallerName("App 1.2.dmg"))
        XCTAssertTrue(Installers.isInstallerName("x.pkg"))
        for bad in [".hidden.dmg", "dmg", "x.dmgx", "x.zip", "x.dmg.zip", "x.pkg.part", ""] {
            XCTAssertFalse(Installers.isInstallerName(bad), bad)
        }
    }

    // MARK: The age rule

    func testOnlyFilesOlderThanThirtyDaysAreListed() throws {
        let box = try Sandbox()
        try box.file("Downloads/new.dmg", bytes: 2_000_000, age: 5)
        try box.file("Downloads/almost.dmg", bytes: 2_000_000, age: 29)
        try box.file("Downloads/old.dmg", bytes: 2_000_000, age: 31)
        try box.file("Downloads/older.pkg", bytes: 2_000_000, age: 400)
        XCTAssertEqual(Set(names(box)), ["Installer · old.dmg", "Installer · older.pkg"])
    }

    func testTheLimitIsExactlyThirtyDays() throws {
        let box = try Sandbox()
        let url = try box.file("Downloads/edge.dmg", bytes: 2_000_000)
        let now = Date()
        let attrs: (Double) -> Void = {
            try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-$0 * 86_400)], ofItemAtPath: url.path)
        }
        attrs(30)
        XCTAssertNotNil(Installers.read(url, home: box.home, now: now), "30 days old counts")
        attrs(29.99)
        XCTAssertNil(Installers.read(url, home: box.home, now: now))
    }

    // MARK: Where it looks

    func testOnlyFilesDirectlyInDownloadsAreListed() throws {
        let box = try Sandbox()
        try box.file("Downloads/Projects/inner.dmg", bytes: 2_000_000, age: 90)
        try box.file("Documents/doc.dmg", bytes: 2_000_000, age: 90)
        try box.file("Desktop/desk.pkg", bytes: 2_000_000, age: 90)
        try box.file("Downloads/top.dmg", bytes: 2_000_000, age: 90)
        XCTAssertEqual(names(box), ["Installer · top.dmg"])
    }

    func testAFolderWithAnInstallerNameIsNotAFile() throws {
        let box = try Sandbox()
        try box.file("Downloads/Thing.pkg/Contents/x", bytes: 2_000_000, age: 90)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86_400)],
                                              ofItemAtPath: box.home.appendingPathComponent("Downloads/Thing.pkg").path)
        XCTAssertTrue(names(box).isEmpty, "A bundle is not a plain installer file")
    }

    func testALinkIsNeverListed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/real.dmg", bytes: 2_000_000, age: 90)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Downloads/link.dmg"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere/real.dmg"))
        XCTAssertTrue(names(box).isEmpty)
    }

    func testADownloadsFolderThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/real.dmg", bytes: 2_000_000, age: 90)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Downloads"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(names(box).isEmpty, "A link above the file could lead anywhere")
    }

    func testNothingWhenThereIsNoDownloadsFolder() throws {
        let box = try Sandbox()
        XCTAssertTrue(names(box).isEmpty)
    }

    func testAnUnreadableDownloadsFolderShowsNothing() throws {
        let box = try Sandbox()
        try box.file("Downloads/a.dmg", bytes: 2_000_000, age: 90)
        let dir = box.home.appendingPathComponent("Downloads")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        XCTAssertTrue(names(box).isEmpty, "macOS may refuse the read. That must not crash")
    }

    func testTheKeepListIsHonored() throws {
        let box = try Sandbox()
        try box.file("Downloads/keepme.dmg", bytes: 2_000_000, age: 90)
        try box.file("Downloads/other.dmg", bytes: 2_000_000, age: 90)
        let kept = scanner(box, keep: [box.home.appendingPathComponent("Downloads/keepme.dmg").path]).scanInstallers().map(\.title)
        XCTAssertEqual(kept, ["Installer · other.dmg"])
    }

    // MARK: The items

    func testEachFileIsOneReviewItemAndNeverInTheOneClickTotal() throws {
        let box = try Sandbox()
        try box.file("Downloads/a.dmg", bytes: 3_000_000, age: 90)
        try box.file("Downloads/b.pkg", bytes: 2_000_000, age: 60)
        let s = scanner(box)
        let items = s.scanInstallers()
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.tier == .review && $0.ecosystem == .installers && $0.owner == nil })
        XCTAssertEqual(items.first?.title, "Installer · a.dmg", "The largest file comes first")
        XCTAssertTrue(items[0].location.contains("90 days old"), items[0].location)
        let result = s.scan()
        XCTAssertEqual(result.reclaimable, 0)
        XCTAssertTrue(result.reviewable >= 5_000_000)
    }

    // MARK: The clean

    func testACleanRemovesOnlyTheChosenFile() throws {
        let box = try Sandbox()
        try box.file("Downloads/a.dmg", bytes: 3_000_000, age: 90)
        try box.file("Downloads/b.pkg", bytes: 2_000_000, age: 90)
        try box.file("Downloads/c.zip", bytes: 2_000_000, age: 90)
        try box.file("Downloads/notes.txt", bytes: 1_000, age: 90)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanInstallers().first { $0.title.contains("a.dmg") })
        let report = cleaner(s).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, 3_000_000)
        XCTAssertFalse(exists(box, "Downloads/a.dmg"))
        for kept in ["Downloads/b.pkg", "Downloads/c.zip", "Downloads/notes.txt"] { XCTAssertTrue(exists(box, kept), kept) }
        XCTAssertEqual(s.remainingBytes(of: item), 0)
    }

    func testAFileThatBecameNewIsSkipped() throws {
        let box = try Sandbox()
        let url = try box.file("Downloads/a.dmg", bytes: 3_000_000, age: 90)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanInstallers().first)
        try Data(repeating: 2, count: 3_000_000).write(to: url)          // downloaded again after the scan
        let report = cleaner(s).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(exists(box, "Downloads/a.dmg"))
    }

    func testAMountedImageIsNeverRemoved() throws {
        let box = try Sandbox()
        let url = try box.file("Downloads/a.dmg", bytes: 3_000_000, age: 90)
        let s = scanner(box)
        let item = try XCTUnwrap(s.scanInstallers().first)
        let report = cleaner(s, mounted: [url.path]).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.skipped[0].contains("Eject"), report.skipped[0])
        XCTAssertTrue(exists(box, "Downloads/a.dmg"))
    }

    func testTheCleanerRefusesAnythingThatIsNotAnInstallerInDownloads() throws {
        let box = try Sandbox()
        try box.file("Downloads/a.zip", bytes: 2_000_000, age: 90)
        try box.file("Downloads/sub/b.dmg", bytes: 2_000_000, age: 90)
        try box.file("Documents/c.dmg", bytes: 2_000_000, age: 90)
        try box.file("Downloads/d.dmg", bytes: 2_000_000, age: 5)
        let s = scanner(box)
        func fake(_ rel: String) -> Finding {
            Finding(id: rel, ecosystem: .installers, title: rel, location: rel, bytes: 2_000_000, tier: .review,
                    rebuild: .download, action: .removeInstaller(box.home.appendingPathComponent(rel)))
        }
        let report = cleaner(s).clean(["Downloads/a.zip", "Downloads/sub/b.dmg", "Documents/c.dmg", "Downloads/d.dmg"].map(fake))
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 4)
        for rel in ["Downloads/a.zip", "Downloads/sub/b.dmg", "Documents/c.dmg", "Downloads/d.dmg"] { XCTAssertTrue(exists(box, rel), rel) }
    }

    func testTheCleanerRefusesALinkAndLeavesItsTarget() throws {
        let box = try Sandbox()
        try box.file("elsewhere/real.dmg", bytes: 2_000_000, age: 90)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        let link = box.home.appendingPathComponent("Downloads/link.dmg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: box.home.appendingPathComponent("elsewhere/real.dmg"))
        let f = Finding(id: "l", ecosystem: .installers, title: "l", location: "l", bytes: 2_000_000, tier: .review,
                        rebuild: .download, action: .removeInstaller(link))
        let report = cleaner(scanner(box)).clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(box, "elsewhere/real.dmg"))
    }

    func testAnInstallerOnTheKeepListIsRefusedAtCleanTime() throws {
        let box = try Sandbox()
        try box.file("Downloads/keepme.dmg", bytes: 2_000_000, age: 90)
        let s = scanner(box, keep: [box.home.appendingPathComponent("Downloads/keepme.dmg").path])
        let f = Finding(id: "k", ecosystem: .installers, title: "k", location: "k", bytes: 2_000_000, tier: .review,
                        rebuild: .download, action: .removeInstaller(box.home.appendingPathComponent("Downloads/keepme.dmg")))
        XCTAssertEqual(cleaner(s).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, "Downloads/keepme.dmg"))
    }

    // MARK: The dialog and the permission text

    func testTheDialogKeepsTheFileByDefault() throws {
        let box = try Sandbox()
        try box.file("Downloads/a.dmg", bytes: 3_000_000, age: 90)
        let item = try XCTUnwrap(scanner(box).scanInstallers().first)
        XCTAssertEqual(Confirmation.kind(of: item), .installer)
        let c = Confirmation.forOne(item, staleDays: 30)
        XCTAssertEqual(c.title, "Delete this installer?")
        XCTAssertEqual(c.confirmTitle, "Delete installer")
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertTrue(c.footer?.contains("does not go to the Trash") == true)
    }

    func testTheAppExplainsTheDownloadsPermission() throws {
        let plist = try String(contentsOfFile: "scripts/Info.plist", encoding: .utf8)
        XCTAssertTrue(plist.contains("NSDownloadsFolderUsageDescription"))
    }
}
