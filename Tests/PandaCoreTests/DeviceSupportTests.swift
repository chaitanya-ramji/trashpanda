import XCTest
@testable import PandaCore

final class DeviceSupportTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z")!
    private let ios = "iOS DeviceSupport"

    @discardableResult
    private func folder(_ box: Sandbox, _ dir: String, _ name: String, bytes: Int = 3_000_000, days: Int = 100) throws -> URL {
        try box.file("Library/Developer/Xcode/\(dir)/\(name)/Symbols/System/Library/x", bytes: bytes)
        let url = box.home.appendingPathComponent("Library/Developer/Xcode/\(dir)/\(name)")
        let when = now.addingTimeInterval(-Double(days) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        return url
    }

    private func scanner(_ box: Sandbox) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false, now: { [now] in now })
    }

    private func offered(_ s: DiskScanner) -> [Finding] { s.scanDeviceSupport().filter(\.isActionable) }
    private func kept(_ s: DiskScanner) -> [Finding] { s.scanDeviceSupport().filter { !$0.isActionable } }

    // MARK: Names

    func testNamesAreReadStrictly() {
        func p(_ n: String) -> (String?, String, String)? { DeviceSupport.parse(name: n).map { ($0.model, $0.version, $0.build) } }
        XCTAssertTrue(p("iPhone15,2 17.5 (21F79)")! == ("iPhone15,2", "17.5", "21F79"))
        XCTAssertTrue(p("10.3.3 (14G60)")! == (nil, "10.3.3", "14G60"), "An older Xcode has no model in the name")
        XCTAssertTrue(p("Watch6,2 7.3 (18R381)")! == ("Watch6,2", "7.3", "18R381"))
        XCTAssertTrue(p("AppleTV6,2 14.4 (18L204)")! == ("AppleTV6,2", "14.4", "18L204"))
        XCTAssertTrue(p("RealityDevice14,1 1.0 (21N333)")! == ("RealityDevice14,1", "1.0", "21N333"))
        XCTAssertTrue(p("iPhone10,6 13.3 (17D50) arm64e")! == ("iPhone10,6", "13.3", "17D50"), "A trailing architecture is accepted")
        XCTAssertTrue(p("iPhone16,1 18.0 (22A5297f)")! == ("iPhone16,1", "18.0", "22A5297f"), "Builds can hold letters")
        for bad in ["", "Latest", "iPhone15,2", "17.5", "iPhone15,2 17.5", "My Backup (1)", "iPhone15,2 17.5 (21F79) extra words",
                    ".DS_Store", "../x", "iPhone15,2 17.5 (21F79)/..", "iPhone15,2  17.5 (21F79)", "iPhone15,2 17.5 ()", "iphone 17.5 (21F79)"] {
            XCTAssertNil(p(bad), "\"\(bad)\" is not ours")
        }
    }

    func testVersionsAreComparedAsNumbers() throws {
        let box = try Sandbox()
        try folder(box, ios, "iPhone15,2 17.5 (21F79)")
        try folder(box, ios, "iPhone15,2 17.10 (21G93)")
        let s = scanner(box)
        XCTAssertEqual(kept(s).map(\.title), ["iOS device support · iPhone15,2 17.10 (21G93) · newest, kept"], "17.10 is newer than 17.5")
        XCTAssertEqual(offered(s).map(\.title), ["iOS device support · iPhone15,2 17.5 (21F79)"])
    }

    // MARK: What is offered and what is kept

    func testOneModelWithSeveralVersions() throws {
        let box = try Sandbox()
        for v in ["17.4 (21E219)", "17.5 (21F79)", "17.6 (21G80)", "18.0 (22A3354)"] { try folder(box, ios, "iPhone15,2 \(v)") }
        let s = scanner(box)
        XCTAssertEqual(Set(offered(s).map(\.title)), [
            "iOS device support · iPhone15,2 17.4 (21E219)", "iOS device support · iPhone15,2 17.5 (21F79)",
            "iOS device support · iPhone15,2 17.6 (21G80)"])
        XCTAssertEqual(kept(s).count, 1)
        XCTAssertTrue(kept(s)[0].title.contains("18.0"), "The newest is kept")
    }

    func testTwoModelsEachKeepTheirNewest() throws {
        let box = try Sandbox()
        try folder(box, ios, "iPhone15,2 17.5 (21F79)"); try folder(box, ios, "iPhone15,2 17.4 (21E219)")
        try folder(box, ios, "iPhone12,1 16.7 (20H19)"); try folder(box, ios, "iPhone12,1 16.6 (20G75)")
        let s = scanner(box)
        XCTAssertEqual(Set(offered(s).map(\.title)), ["iOS device support · iPhone15,2 17.4 (21E219)",
                                                       "iOS device support · iPhone12,1 16.6 (20G75)"])
        XCTAssertEqual(kept(s).count, 2, "The newest of each model, even if one model is older")
    }

    func testAnOlderXcodeFolderWithNoModelIsOneGroup() throws {
        let box = try Sandbox()
        try folder(box, ios, "12.4 (16G77)"); try folder(box, ios, "13.3 (17D50)")
        try folder(box, ios, "iPhone8,1 12.4 (16G77)")      // a model: its own group, so it is kept
        let s = scanner(box)
        XCTAssertEqual(offered(s).map(\.title), ["iOS device support · 12.4 (16G77)"])
        XCTAssertEqual(kept(s).count, 2)
    }

    func testAModelWithOnlyOneVersionHasNothingToOffer() throws {
        let box = try Sandbox()
        try folder(box, ios, "iPhone15,2 17.5 (21F79)")
        let s = scanner(box)
        XCTAssertTrue(offered(s).isEmpty)
        XCTAssertEqual(kept(s).count, 1)
    }

    func testAnEmptyFolderIsIgnored() throws {
        let box = try Sandbox()
        try folder(box, ios, "iPhone15,2 17.5 (21F79)")
        try FileManager.default.createDirectory(
            at: box.home.appendingPathComponent("Library/Developer/Xcode/\(ios)/iPhone15,2 18.0 (22A3354)"), withIntermediateDirectories: true)
        let s = scanner(box)
        XCTAssertTrue(offered(s).isEmpty)
        XCTAssertEqual(kept(s).map(\.title), ["iOS device support · iPhone15,2 17.5 (21F79) · newest, kept"],
                       "An empty newer folder does not make the real one look old")
    }

    func testNamesInAnotherShapeAreLeftAlone() throws {
        let box = try Sandbox()
        try folder(box, ios, "iPhone15,2 17.5 (21F79)"); try folder(box, ios, "iPhone15,2 17.4 (21E219)")
        try folder(box, ios, "Latest"); try folder(box, ios, "My Backup 2024")
        try box.file("Library/Developer/Xcode/\(ios)/iPhone15,2 16.0 (20A362)", bytes: 3_000_000)      // a file, not a folder
        let real = try folder(box, "elsewhere", "iPhone15,2 15.0 (19A346)")
        try FileManager.default.createSymbolicLink(
            at: box.home.appendingPathComponent("Library/Developer/Xcode/\(ios)/iPhone15,2 15.1 (19B74)"), withDestinationURL: real)
        let titles = scanner(box).scanDeviceSupport().map(\.title).joined(separator: " | ")
        XCTAssertFalse(titles.contains("Latest") || titles.contains("Backup") || titles.contains("16.0") || titles.contains("15."), titles)
        XCTAssertEqual(scanner(box).scanDeviceSupport().count, 2)
    }

    func testTheOtherPlatformsAreListedWithTheirNames() throws {
        let box = try Sandbox()
        try folder(box, "watchOS DeviceSupport", "Watch6,2 7.3 (18R381)"); try folder(box, "watchOS DeviceSupport", "Watch6,2 7.2 (18R376)")
        try folder(box, "tvOS DeviceSupport", "AppleTV6,2 14.4 (18L204)"); try folder(box, "tvOS DeviceSupport", "AppleTV6,2 14.3 (18K550)")
        try folder(box, "visionOS DeviceSupport", "RealityDevice14,1 1.0 (21N333)"); try folder(box, "visionOS DeviceSupport", "RealityDevice14,1 1.1 (21O100)")
        XCTAssertEqual(Set(offered(scanner(box)).map(\.title)), [
            "watchOS device support · Watch6,2 7.2 (18R376)", "tvOS device support · AppleTV6,2 14.3 (18K550)",
            "visionOS device support · RealityDevice14,1 1.0 (21N333)"])
    }

    func testAnOldKeptFolderOfAnotherPlatformDoesNotInterfere() throws {
        let box = try Sandbox()
        // The same model name in two platform folders is two groups.
        try folder(box, ios, "Device1,1 5.0 (A1)"); try folder(box, "tvOS DeviceSupport", "Device1,1 9.0 (B1)")
        XCTAssertTrue(offered(scanner(box)).isEmpty)
        XCTAssertEqual(kept(scanner(box)).count, 2)
    }

    // MARK: The items

    func testEachOfferedItemIsAReviewItemOwnedByXcode() throws {
        let box = try Sandbox()
        try folder(box, ios, "iPhone15,2 17.5 (21F79)", days: 5); try folder(box, ios, "iPhone15,2 17.4 (21E219)", days: 100)
        let item = try XCTUnwrap(offered(scanner(box)).first)
        XCTAssertEqual(item.tier, .review)
        XCTAssertEqual(item.rebuild, .minutes)
        XCTAssertEqual(item.owner?.name, "Xcode")
        XCTAssertTrue(item.location.contains("added 100 days ago"))
        XCTAssertTrue(item.location.contains("copies it again when you connect the device"))
        XCTAssertEqual(Confirmation.kind(of: item), .deviceSupport)
        XCTAssertFalse(kept(scanner(box)).contains { $0.owner != nil }, "A kept line has no action and no owner")
    }

    func testTheKeptLinesAreInformationAndNotInTotals() throws {
        let box = try Sandbox()
        try folder(box, ios, "iPhone15,2 17.5 (21F79)", bytes: 4_000_000); try folder(box, ios, "iPhone15,2 17.4 (21E219)", bytes: 3_000_000)
        let found = scanner(box).scanDeviceSupport()
        let result = ScanResult(findings: found, disk: DiskUsage(total: 10, free: 5))
        XCTAssertEqual(result.reclaimable, 0)
        XCTAssertEqual(result.reviewable, offered(scanner(box)).reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(SplitBar.segments(from: found).map(\.bytes).reduce(0, +), result.reviewable, "Not in the split bar either")
    }

    func testTheOldWholeFolderRowIsGone() {
        XCTAssertNil(Catalog.caches.first { $0.id == "xcode.devsupport" },
                     "The whole folder is no longer one item. Each version is its own item.")
    }

    // MARK: The clean

    func testCleaningOneFolderLeavesTheOthers() throws {
        let box = try Sandbox()
        let new = try folder(box, ios, "iPhone15,2 17.5 (21F79)")
        let old = try folder(box, ios, "iPhone15,2 17.4 (21E219)")
        let older = try folder(box, ios, "iPhone15,2 17.3 (21D50)")
        let other = try folder(box, ios, "iPhone12,1 16.7 (20H19)")
        let s = scanner(box)
        let target = try XCTUnwrap(offered(s).first { $0.title.contains("17.4") })

        let report = Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning().provider).clean([target])
        XCTAssertEqual(report.removed, 1)
        XCTAssertGreaterThan(report.freed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for keep in [new, older, other, old.deletingLastPathComponent()] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path), keep.lastPathComponent)
        }
        XCTAssertFalse(offered(scanner(box)).contains { $0.title.contains("17.4") }, "It does not come back in the next scan")
    }

    func testNothingIsRemovedWhileXcodeRuns() throws {
        let box = try Sandbox()
        try folder(box, ios, "iPhone15,2 17.5 (21F79)"); let old = try folder(box, ios, "iPhone15,2 17.4 (21E219)")
        let s = scanner(box)
        let report = Cleaner(guardian: s.guardian, runningApps: FakeRunning(apps: [FakeRunning.xcode]).provider)
            .clean(offered(s))
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.blockedApps, ["Xcode"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testOnlyARealDeviceSupportFolderCanBeRemoved() throws {
        let box = try Sandbox()
        let good = try folder(box, ios, "iPhone15,2 17.5 (21F79)")
        let docs = try box.file("Documents/iPhone15,2 17.5 (21F79)/thesis", bytes: 1_000).deletingLastPathComponent()
        let wrongDir = try box.file("Library/Developer/Xcode/Archives/iPhone15,2 17.5 (21F79)/x", bytes: 1_000).deletingLastPathComponent()
        let latest = try folder(box, ios, "Latest")
        let deep = try folder(box, ios, "iPhone15,2 17.5 (21F79)/iPhone15,2 17.4 (21E219)")
        let link = box.home.appendingPathComponent("Library/Developer/Xcode/\(ios)/iPhone15,2 16.0 (20A362)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: docs)
        let traversal = box.home.appendingPathComponent("Library/Developer/Xcode/\(ios)/../../../../Documents/iPhone15,2 17.5 (21F79)")
        let platformDir = box.home.appendingPathComponent("Library/Developer/Xcode/\(ios)")

        let guardian = PathGuard(home: box.home)
        for url in [docs, wrongDir, latest, deep, link, traversal, platformDir] {
            let f = Finding(id: "x", ecosystem: .swift, title: "x", location: url.path, bytes: 1, tier: .review,
                            rebuild: .minutes, action: .removeDeviceSupport(url))
            XCTAssertEqual(Cleaner(guardian: guardian, runningApps: FakeRunning().provider).clean([f]).removed, 0, url.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appendingPathComponent("thesis").path), "Documents are safe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: platformDir.path), "The platform folder itself is never removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: latest.path))
    }

    func testIsDeviceSupport() {
        let home = URL(fileURLWithPath: "/Users/x")
        func check(_ p: String) -> Bool { DeviceSupport.isDeviceSupport(URL(fileURLWithPath: p), home: home) }
        let base = "/Users/x/Library/Developer/Xcode"
        XCTAssertTrue(check("\(base)/iOS DeviceSupport/iPhone15,2 17.5 (21F79)"))
        XCTAssertTrue(check("\(base)/watchOS DeviceSupport/Watch6,2 7.3 (18R381)"))
        XCTAssertFalse(check("\(base)/iOS DeviceSupport"), "The platform folder")
        XCTAssertFalse(check("\(base)/iOS DeviceSupport/Latest"))
        XCTAssertFalse(check("\(base)/Archives/iPhone15,2 17.5 (21F79)"))
        XCTAssertFalse(check("\(base)/macOS DeviceSupport/iPhone15,2 17.5 (21F79)"), "Not a platform that we list")
        XCTAssertFalse(check("\(base)/iOS DeviceSupport/iPhone15,2 17.5 (21F79)/sub"))
        XCTAssertFalse(check("/Users/y/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 17.5 (21F79)"), "Another user")
        XCTAssertFalse(check("\(base)/iOS DeviceSupport/../../../../Documents/iPhone15,2 17.5 (21F79)"))
    }

    func testTheDialogWords() {
        let f = Finding(id: "x", ecosystem: .swift, title: "iOS device support · iPhone15,2 17.4 (21E219)", location: "Where",
                        bytes: 3_000_000_000, tier: .review, rebuild: .minutes,
                        action: .removeDeviceSupport(URL(fileURLWithPath: "/x/iOS DeviceSupport/iPhone15,2 17.4 (21E219)")))
        let c = Confirmation.forOne(f, staleDays: 30)
        XCTAssertEqual(c.title, "Remove these device support files?")
        XCTAssertTrue(c.footer!.contains("copies them from the device again"))
        XCTAssertTrue(c.footer!.contains("can't be undone"))
        XCTAssertEqual(c.confirmTitle, "Remove files")
        XCTAssertTrue(c.cancelIsDefault, "Files for an old iOS version or a device that is gone cannot be restored")
    }
}
