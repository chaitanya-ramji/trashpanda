import XCTest
@testable import PandaCore

private func uid(_ c: Character) -> String { [8, 4, 4, 4, 12].map { String(repeating: c, count: $0) }.joined(separator: "-") }

// MARK: - Parsing

final class SimctlParsingTests: XCTestCase {
    func testRuntimesAreReadFromTheFixtureAndUnreadableOnesAreLeftOut() throws {
        let list = try XCTUnwrap(Simctl.parseRuntimes(try FakeSimctl.fixture("runtimes-full")))
        XCTAssertEqual(list.count, 11, "The runtime with no size is left out")
        XCTAssertNil(list.first { $0.id == uid("c") }, "No size: fail closed")

        let ios = try XCTUnwrap(list.first { $0.id == uid("1") })
        XCTAssertEqual(ios.platform, "iOS")
        XCTAssertEqual(ios.displayName, "iOS 17.5")
        XCTAssertEqual(ios.sizeBytes, 7_000_000_000)
        XCTAssertEqual(ios.build, "21F79")
        XCTAssertNotNil(ios.lastUsedAt)
        XCTAssertEqual(list.first { $0.id == uid("a") }?.platform, "visionOS", "Apple calls it xrOS inside")
        XCTAssertEqual(list.first { $0.id == uid("5") }?.platform, "watchOS")
    }

    func testOnlyAReadyOrUnusableRuntimeThatXcodeCanDeleteIsRemovable() throws {
        let list = try XCTUnwrap(Simctl.parseRuntimes(try FakeSimctl.fixture("runtimes-full")))
        func removable(_ c: Character) -> Bool { list.first { $0.id == uid(c) }?.isRemovableKind ?? false }
        XCTAssertTrue(removable("1"))
        XCTAssertTrue(removable("7"), "Unusable runtimes can go")
        XCTAssertFalse(removable("6"), "Bundled with Xcode")
        XCTAssertFalse(removable("8"), "Verifying: it is changing state")
        XCTAssertFalse(removable("9"), "Xcode says it cannot delete it")
    }

    func testVersionsAreComparedAsNumbers() {
        func r(_ v: String, _ b: String = "") -> SimRuntime {
            SimRuntime(id: uid("1"), runtimeIdentifier: "x.iOS-1", version: v, build: b, sizeBytes: 1, state: "Ready",
                       kind: "Disk Image", deletable: true, lastUsedAt: nil)
        }
        XCTAssertTrue(r("17.10").isNewer(than: r("17.5")), "17.10 is newer than 17.5")
        XCTAssertTrue(r("18").isNewer(than: r("17.99")))
        XCTAssertFalse(r("17.5").isNewer(than: r("17.5.1")))
        XCTAssertTrue(r("17.5", "B").isNewer(than: r("17.5", "A")), "Same version: the build decides")
    }

    func testDevicesAreRead() throws {
        let list = try XCTUnwrap(Simctl.parseDevices(try FakeSimctl.fixture("devices-full")))
        XCTAssertEqual(list.count, 13)
        let booted = try XCTUnwrap(list.first { $0.name == "iPhone 15 Pro" })
        XCTAssertTrue(booted.isActive)
        XCTAssertEqual(booted.runtimeIdentifier, "com.apple.CoreSimulator.SimRuntime.iOS-17-5")
        XCTAssertEqual(list.first { $0.name == "iPhone 14" }?.isAvailable, false)
        XCTAssertEqual(list.first { $0.name == "iPhone 15" }?.dataBytes, 800_000_000)
        XCTAssertNil(list.first { $0.name == "iPhone SE" }?.dataBytes)
    }

    func testEmptyAndBadOutput() {
        XCTAssertEqual(Simctl.parseRuntimes("{\n\n}\n")?.count, 0, "This is what a Mac with no runtimes prints")
        XCTAssertEqual(Simctl.parseDevices("{\"devices\":{}}")?.count, 0)
        for bad in ["", "not json", "42", "null", "\"text\""] {
            XCTAssertNil(Simctl.parseRuntimes(bad), bad)
            XCTAssertNil(Simctl.parseDevices(bad), bad)
        }
        XCTAssertEqual(Simctl.parseRuntimes("{\"x\": 5, \"y\": []}")?.count, 0, "Entries of the wrong shape are left out")
    }

    func testNumbersAndTrueFalseMayComeAsText() {
        let json = """
        {"\(uid("1"))": {"identifier": "\(uid("1"))", "runtimeIdentifier": "a.iOS-17-5", "version": "17.5",
         "sizeBytes": "7000000000", "state": "Ready", "kind": "Disk Image", "deletable": "true"}}
        """
        let r = Simctl.parseRuntimes(json)?.first
        XCTAssertEqual(r?.sizeBytes, 7_000_000_000)
        XCTAssertEqual(r?.deletable, true)
        // A negative or a yes/no word is not trusted.
        XCTAssertNil(Simctl.parseRuntimes(json.replacingOccurrences(of: "\"7000000000\"", with: "-5"))?.first)
    }

    func testActionIdentifiersMustBeUUIDs() {
        for bad in ["", "-f", "all", "--outdated", "1111", "not-a-uuid", uid("1") + " --force", uid("g"), "../\(uid("1"))"] {
            XCTAssertNil(SimulatorAction.deleteRuntime(id: bad).arguments, "\"\(bad)\"")
            XCTAssertNil(SimulatorAction.deleteDevice(udid: bad).arguments, "\"\(bad)\"")
        }
        XCTAssertEqual(SimulatorAction.deleteRuntime(id: uid("a")).arguments, ["runtime", "delete", uid("a")])
        XCTAssertEqual(SimulatorAction.deleteDevice(udid: uid("B")).arguments, ["delete", uid("B")])
    }
}

// MARK: - The scan

final class XcodeScanTests: SimctlTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z")!

    private func scanner(_ box: Sandbox, _ fake: FakeSimctl?, staleDays: Int = 30) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(staleDays: staleDays), useOwnerTools: false,
                    now: { [now] in now }, xcrunPath: fake?.path)
    }

    private func full(_ box: Sandbox) throws -> (FakeSimctl, DiskScanner) {
        let fake = try FakeSimctl(box: box, runtimesFixture: "runtimes-full", devicesFixture: "devices-full")
        return (fake, scanner(box, fake))
    }

    func testTheRuntimesThatCanBeRemoved() throws {
        let box = try Sandbox()
        let (fake, s) = try full(box)
        let found = s.scanSimulators().filter { $0.id.hasPrefix("xcode.runtime:") }

        XCTAssertEqual(Set(found.map(\.title)),
                       ["Simulator runtime · watchOS 10.5", "Simulator runtime · iOS 16.4", "Simulator runtime · iOS 17.0"])
        XCTAssertTrue(found.allSatisfy { $0.tier == .review && $0.rebuild == .download && $0.isActionable })
        XCTAssertTrue(found.allSatisfy { $0.owner?.bundleIDs.contains("com.apple.iphonesimulator") == true },
                      "Xcode and Simulator own them")
        XCTAssertEqual(found.first { $0.title.contains("watchOS") }?.bytes, 3_200_000_000)
        XCTAssertTrue(found.first { $0.title.contains("watchOS") }!.location.contains("1 simulator runs on it"))
        XCTAssertTrue(found.first { $0.title.contains("16.4") }!.location.contains("2 simulators run on it"))
        XCTAssertEqual(fake.calls, ["simctl list devices -j", "simctl runtime list -j"], "The scan only reads")
        XCTAssertTrue(fake.unexpected.isEmpty)
    }

    func testTheRuntimesThatAreKeptAreShownAsInformation() throws {
        let box = try Sandbox()
        let (_, s) = try full(box)
        let info = s.scanSimulators().filter { $0.id.hasPrefix("xcode.runtime.info:") }
        XCTAssertEqual(Set(info.map(\.title)), [
            "iOS 17.5 runtime · in use",              // a simulator is running
            "iOS 18.2 runtime · in use",              // used 4 days ago
            "iOS 27.0 runtime · newest, kept",
            "watchOS 11.0 runtime · newest, kept",
            "visionOS 2.0 runtime · newest, kept",
        ])
        XCTAssertTrue(info.allSatisfy { !$0.isActionable })
        let inUse = try XCTUnwrap(info.first { $0.title.contains("17.5") }, "iOS 17.5 must be listed as in use")
        XCTAssertTrue(inUse.location.contains("a simulator is running"))
    }

    func testRuntimesThatXcodeCannotOrShouldNotTouchAreNotListedAtAll() throws {
        let box = try Sandbox()
        let titles = try full(box).1.scanSimulators().map(\.title).joined(separator: " | ")
        XCTAssertFalse(titles.contains("tvOS"), "Bundled with Xcode")
        XCTAssertFalse(titles.contains("15.5"), "Xcode says it cannot delete it")
        XCTAssertFalse(titles.contains("14.5"), "No size")
        XCTAssertEqual(titles.components(separatedBy: "iOS 17.0").count - 1, 1, "The one that is verifying is skipped")
    }

    func testTheNewestRuntimeOfAPlatformIsNeverOffered() throws {
        let box = try Sandbox()
        let found = try full(box).1.scanSimulators().filter { $0.isActionable }
        XCTAssertFalse(found.contains { $0.title.contains("27.0") || $0.title.contains("watchOS 11") || $0.title.contains("visionOS") })
    }

    func testDevicesThatNobodyUses() throws {
        let box = try Sandbox()
        // The list gives no size for "iPhone SE". It is read from the folder of the device.
        let se = box.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(uid("4"))/data/x")
        try FileManager.default.createDirectory(at: se.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: se)

        let (_, s) = try full(box)
        let found = s.scanSimulators().filter { $0.id.hasPrefix("xcode.device:") }
        XCTAssertEqual(Set(found.map(\.title)), [
            "Simulator · iPhone 15 (iOS 17.5)",       // not started for 303 days
            "Simulator · iPad Air (iOS 17.5)",        // never started
            "Simulator · Apple Watch (watchOS 10.5)", // never started
            "Simulator · iPhone SE (iOS 17.0)",       // size read from disk
        ])
        XCTAssertTrue(found.allSatisfy { $0.tier == .review && $0.rebuild == .recreate && $0.owner != nil })
        XCTAssertTrue(found.first { $0.title.contains("iPhone 15") }!.location.contains("not started for 303 days"))
        XCTAssertTrue(found.first { $0.title.contains("iPad Air") }!.location.contains("never started"))
    }

    func testARunningOrRecentlyUsedDeviceIsNeverOffered() throws {
        let box = try Sandbox()
        let titles = try full(box).1.scanSimulators().map(\.title).joined(separator: " | ")
        XCTAssertFalse(titles.contains("iPhone 15 Pro"), "It is running")
        XCTAssertFalse(titles.contains("iPhone 16"), "Started 4 days ago")
        XCTAssertFalse(titles.contains("iPhone 17"), "Started yesterday")
        XCTAssertFalse(titles.contains("iPhone 13"), "Its data folder is outside the Devices folder")
        // A device that runs, but whose start time is old or missing. Only the state keeps it out.
        XCTAssertFalse(titles.contains("Old Booted"), "Booted")
        XCTAssertFalse(titles.contains("Stuck Booting"), "Booting")
        XCTAssertFalse(titles.contains("Slow Shutdown"), "Shutting down")
    }

    func testTheLimitComesFromTheSetting() throws {
        let box = try Sandbox()
        let fake = try FakeSimctl(box: box, runtimesFixture: "runtimes-full", devicesFixture: "devices-full")
        func offered(_ days: Int) -> Set<String> {
            Set(scanner(box, fake, staleDays: days).scanSimulators().filter { $0.id.hasPrefix("xcode.device:") }.map(\.title))
        }
        // "iPhone 16" started 4.1 days ago, "iPhone 17" 1.1 days ago, "iPhone 15" 303 days ago.
        XCTAssertFalse(offered(1000).contains("Simulator · iPhone 15 (iOS 17.5)"), "303 days is recent when the limit is 1000")
        XCTAssertTrue(offered(3).contains("Simulator · iPhone 16 (iOS 18.2)"), "4.1 days is stale when the limit is 3")
        XCTAssertFalse(offered(3).contains("Simulator · iPhone 17 (iOS 27.0)"), "1.1 days is still recent")
        XCTAssertFalse(offered(5).contains("Simulator · iPhone 16 (iOS 18.2)"), "4.1 days is recent when the limit is 5")
    }

    func testUnavailableSimulatorsAreOneSafeItem() throws {
        let box = try Sandbox()
        let item = try XCTUnwrap(try full(box).1.scanSimulators().first { $0.id == "xcode.sim.unavailable" })
        XCTAssertEqual(item.bytes, 400_000_000, "300 MB + 100 MB")
        XCTAssertEqual(item.tier, .safe)
        if case .owner(.simctlDeleteUnavailable) = item.action {} else { XCTFail("Apple's own command") }
    }

    /// S-11 d. Apple's command can remove more than the shown size, so the row says "up to" and the dialog says what the tool removes.
    func testUnavailableSimulatorsShowAnUpToSizeAndTheDialogSaysWhatTheToolRemoves() throws {
        let box = try Sandbox()
        let item = try XCTUnwrap(try full(box).1.scanSimulators().first { $0.id == "xcode.sim.unavailable" })
        XCTAssertTrue(item.sizeIsUpperLimit)
        XCTAssertTrue(item.sizeText.hasPrefix("up to "), item.sizeText)
        let c = Confirmation.forOne(item, staleDays: 30)
        XCTAssertTrue(c.title.contains("up to "), c.title)
        XCTAssertTrue(c.body.contains("can remove more than this size"), c.body)
    }

    func testBrewCleanupShowsAnUpToSizeAndTheDialogSaysWhatTheToolRemoves() {
        let item = Finding(id: "brew.cleanup", ecosystem: .homebrew, title: "Old downloads and versions", location: "x", bytes: 5_000_000,
                           tier: .safe, rebuild: .download, action: .owner(.brewCleanup),
                           note: "brew cleanup --prune=all removes all old downloads and old versions of packages. It can remove more than this size.",
                           sizeIsUpperLimit: true)
        let c = Confirmation.forOne(item, staleDays: 30)
        XCTAssertTrue(c.title.contains("up to "), c.title)
        XCTAssertTrue(c.body.contains("--prune=all"), c.body)
    }

    func testNothingOnAMacWithNoXcodeOrWithNothingInstalled() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box, nil).scanSimulators().isEmpty, "No tool: nothing, and the real xcrun is never called")
        let empty = try FakeSimctl(box: box, runtimesFixture: "runtimes-empty", devicesFixture: "devices-empty")
        XCTAssertTrue(scanner(box, empty).scanSimulators().isEmpty)
        XCTAssertTrue(empty.unexpected.isEmpty)
    }

    func testBadSimctlOutputGivesNothingAndDoesNotCrash() throws {
        let box = try Sandbox()
        let fake = try FakeSimctl(box: box, runtimes: "garbage", devices: "also garbage")
        XCTAssertTrue(scanner(box, fake).scanSimulators().isEmpty)
    }
}

// MARK: - The clean

final class XcodeCleanTests: SimctlTestCase {
    private func setup(_ box: Sandbox, runtimesAfter: String? = nil, devicesAfter: String? = nil)
        throws -> (FakeSimctl, DiskScanner, Cleaner) {
        let fake = try FakeSimctl(box: box, runtimes: try FakeSimctl.fixture("runtimes-full"),
                                  devices: try FakeSimctl.fixture("devices-full"),
                                  runtimesAfter: runtimesAfter, devicesAfter: devicesAfter)
        let now = ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z")!
        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false, now: { now }, xcrunPath: fake.path)
        let cleaner = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:),
                              runningApps: FakeRunning().provider, simctl: { Simctl(xcrun: fake.path) })
        return (fake, scanner, cleaner)
    }

    private func removing(runtime id: String, from json: String) throws -> String {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        root[id] = nil
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    private func editingDevices(_ json: String, _ change: (inout [String: Any]) -> Void) throws -> String {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var devices = root["devices"] as? [String: Any] ?? [:]
        change(&devices)
        root["devices"] = devices
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    private func forged(_ action: SimulatorAction, bytes: Int64 = 1_000_000) -> Finding {
        Finding(id: "forged", ecosystem: .swift, title: "x", location: "x", bytes: bytes, tier: .review,
                rebuild: .download, action: .simulator(action))
    }

    // MARK: Runtimes

    func testDeletingOneRuntimeRunsOneExactCommandAndMeasuresIt() throws {
        let box = try Sandbox()
        let after = try removing(runtime: uid("4"), from: try FakeSimctl.fixture("runtimes-full"))
        let (fake, scanner, cleaner) = try setup(box, runtimesAfter: after)
        let target = try XCTUnwrap(scanner.scanSimulators().first { $0.title.hasSuffix("watchOS 10.5") })

        let report = cleaner.clean([target])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, 3_200_000_000, "Measured by asking simctl again")
        XCTAssertEqual(fake.deletes, ["simctl runtime delete \(uid("4"))"])
        XCTAssertTrue(fake.unexpected.isEmpty)
        XCTAssertFalse(fake.calls.contains { $0.contains(" all") || $0.contains("--") }, "No bulk form: \(fake.calls)")
    }

    func testARuntimeWithARunningSimulatorIsNeverDeleted() throws {
        let box = try Sandbox()
        let (fake, _, cleaner) = try setup(box)
        // iOS 17.5 has a booted simulator. Xcode would shut it down, so the cleaner refuses.
        let report = cleaner.clean([forged(.deleteRuntime(id: uid("1")))])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.skipped.joined().contains("is running"))
        XCTAssertTrue(fake.deletes.isEmpty)
    }

    func testASimulatorThatStartsAfterTheScanBlocksTheRuntime() throws {
        let box = try Sandbox()
        let (fake, scanner, cleaner) = try setup(box)
        let target = try XCTUnwrap(scanner.scanSimulators().first { $0.title.hasSuffix("watchOS 10.5") })

        try fake.setDevices(try editingDevices(try FakeSimctl.fixture("devices-full")) { groups in
            let key = "com.apple.CoreSimulator.SimRuntime.watchOS-10-5"
            groups[key] = (groups[key] as? [[String: Any]] ?? []).map { var d = $0; d["state"] = "Booted"; return d }
        })
        let report = cleaner.clean([target])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(fake.deletes.isEmpty, "Nothing is deleted: \(fake.calls)")
    }

    func testForgedRuntimeItemsAreRefused() throws {
        let box = try Sandbox()
        let (fake, _, cleaner) = try setup(box)
        for (name, action) in [("bundled", SimulatorAction.deleteRuntime(id: uid("6"))),
                               ("xcode cannot delete", .deleteRuntime(id: uid("9"))),
                               ("not in the list", .deleteRuntime(id: uid("e")))] {
            XCTAssertEqual(cleaner.clean([forged(action)]).removed, 0, name)
        }
        XCTAssertTrue(fake.deletes.isEmpty, "\(fake.calls)")
    }

    func testAnInvalidIdentifierRunsNothingNotEvenARead() throws {
        let box = try Sandbox()
        let (fake, _, cleaner) = try setup(box)
        for bad in ["all", "--outdated", "", "-f"] {
            XCTAssertEqual(cleaner.clean([forged(.deleteRuntime(id: bad)), forged(.deleteDevice(udid: bad))]).removed, 0)
        }
        XCTAssertTrue(fake.calls.isEmpty, "\(fake.calls)")
    }

    // MARK: Devices

    func testDeletingOneDeviceRunsOneExactCommandAndMeasuresIt() throws {
        let box = try Sandbox()
        let devicesAfter = try editingDevices(try FakeSimctl.fixture("devices-full")) { groups in
            let key = "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
            groups[key] = (groups[key] as? [[String: Any]] ?? []).filter { $0["name"] as? String != "iPhone 15" }
        }
        let (fake, scanner, cleaner) = try setup(box, devicesAfter: devicesAfter)
        let target = try XCTUnwrap(scanner.scanSimulators().first { $0.title.hasPrefix("Simulator · iPhone 15 (") })

        let report = cleaner.clean([target])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, 800_000_000)
        XCTAssertEqual(fake.deletes, ["simctl delete \(uid("d"))"])
    }

    func testARunningOrUnavailableDeviceIsNeverDeleted() throws {
        let box = try Sandbox()
        let (fake, _, cleaner) = try setup(box)
        XCTAssertEqual(cleaner.clean([forged(.deleteDevice(udid: uid("e")))]).removed, 0, "Booted")
        XCTAssertEqual(cleaner.clean([forged(.deleteDevice(udid: uid("6")))]).removed, 0, "Unavailable")
        XCTAssertEqual(cleaner.clean([forged(.deleteDevice(udid: uid("b")))]).removed, 0, "Not in the list")
        XCTAssertTrue(fake.deletes.isEmpty)
    }

    func testADeviceThatStartsAfterTheScanIsSkipped() throws {
        let box = try Sandbox()
        let (fake, scanner, cleaner) = try setup(box)
        let target = try XCTUnwrap(scanner.scanSimulators().first { $0.title.hasPrefix("Simulator · iPad Air") })
        try fake.setDevices(try editingDevices(try FakeSimctl.fixture("devices-full")) { groups in
            let key = "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
            groups[key] = (groups[key] as? [[String: Any]] ?? []).map { var d = $0; d["state"] = "Booted"; return d }
        })
        XCTAssertEqual(cleaner.clean([target]).removed, 0)
        XCTAssertTrue(fake.deletes.isEmpty)
    }

    func testUnavailableSimulatorsAreRemovedByAppleCommandAndMeasured() throws {
        let box = try Sandbox()
        let devicesAfter = try editingDevices(try FakeSimctl.fixture("devices-full")) { groups in
            groups["com.apple.CoreSimulator.SimRuntime.iOS-16-4"] = []
        }
        let (fake, scanner, cleaner) = try setup(box, devicesAfter: devicesAfter)
        let item = try XCTUnwrap(scanner.scanSimulators().first { $0.id == "xcode.sim.unavailable" })
        let report = cleaner.clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, 400_000_000)
        XCTAssertEqual(fake.deletes, ["simctl delete unavailable"])
    }

    // MARK: Running apps

    func testNothingIsDeletedWhileXcodeOrSimulatorRuns() throws {
        for app in [RunningApp(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
                    RunningApp(bundleID: "com.apple.iphonesimulator", name: "Simulator")] {
            let box = try Sandbox()
            let (fake, scanner, _) = try setup(box)
            let target = try XCTUnwrap(scanner.scanSimulators().first { $0.title.hasSuffix("watchOS 10.5") })
            let cleaner = Cleaner(guardian: scanner.guardian, runningApps: FakeRunning(apps: [app]).provider,
                                  simctl: { Simctl(xcrun: fake.path) })
            let report = cleaner.clean([target])
            XCTAssertEqual(report.removed, 0, app.name)
            XCTAssertEqual(report.blockedApps, [app.name])
            XCTAssertTrue(fake.deletes.isEmpty)
        }
    }
}

// MARK: - Archives

final class XcodeArchiveTests: XCTestCase {
    private func archive(_ box: Sandbox, _ day: String, _ name: String, bytes: Int = 4_000_000) throws -> URL {
        try box.file("Library/Developer/Xcode/Archives/\(day)/\(name).xcarchive/Products/Applications/App.app/bin", bytes: bytes)
        return box.home.appendingPathComponent("Library/Developer/Xcode/Archives/\(day)/\(name).xcarchive")
    }

    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }

    func testArchivesAreListedOneByOneAsReviewItems() throws {
        let box = try Sandbox()
        _ = try archive(box, "2026-05-01", "MyApp 5-1-26, 10.00 AM")
        _ = try archive(box, "2026-06-01", "Other App", bytes: 2_000_000)
        try box.file("Library/Developer/Xcode/Archives/2026-05-01/notes.txt", bytes: 100)            // not an archive
        try box.file("Library/Developer/Xcode/Archives/Loose.xcarchive/x", bytes: 3_000_000)         // not in a date folder
        let real = try box.file("elsewhere/Real.xcarchive/x", bytes: 3_000_000).deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(
            at: box.home.appendingPathComponent("Library/Developer/Xcode/Archives/2026-05-01/Linked.xcarchive"),
            withDestinationURL: real)                                                                // a link: never followed

        let found = scanner(box).scanArchives()
        XCTAssertEqual(Set(found.map(\.title)), ["Archive · MyApp 5-1-26, 10.00 AM", "Archive · Other App"])
        XCTAssertTrue(found.allSatisfy { $0.tier == .review && $0.isActionable && $0.owner?.name == "Xcode" })
        XCTAssertTrue(found.allSatisfy { if case .removeArchive = $0.action { return true } else { return false } })
        XCTAssertTrue(found[0].location.contains("archived"))
    }

    func testTheOneClickCleanNeverIncludesAnArchive() throws {
        let box = try Sandbox()
        _ = try archive(box, "2026-05-01", "MyApp")
        let result = ScanResult(findings: scanner(box).scanArchives(), disk: DiskUsage(total: 10, free: 5))
        XCTAssertEqual(result.reclaimable, 0, "An archive is never in the safe total")
        XCTAssertGreaterThan(result.reviewable, 0)
    }

    func testCleaningOneArchiveLeavesTheRest() throws {
        let box = try Sandbox()
        let a = try archive(box, "2026-05-01", "MyApp")
        let b = try archive(box, "2026-05-01", "Sibling")
        let s = scanner(box)
        let target = try XCTUnwrap(s.scanArchives().first { $0.title.hasSuffix("MyApp") })

        let report = Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning().provider).clean([target])
        XCTAssertEqual(report.removed, 1)
        XCTAssertGreaterThan(report.freed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path), "The sibling stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.deletingLastPathComponent().path), "The date folder stays")
    }

    func testAnArchiveIsNotRemovedWhileXcodeRuns() throws {
        let box = try Sandbox()
        let a = try archive(box, "2026-05-01", "MyApp")
        let s = scanner(box)
        let target = try XCTUnwrap(s.scanArchives().first)
        let running = FakeRunning(apps: [FakeRunning.xcode]).provider
        let report = Cleaner(guardian: s.guardian, runningApps: running).clean([target])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.blockedApps, ["Xcode"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    func testOnlyARealArchiveInTheArchivesFolderCanBeRemoved() throws {
        let box = try Sandbox()
        let precious = try box.file("Documents/work.xcarchive/thesis", bytes: 1_000).deletingLastPathComponent()
        let loose = try box.file("Library/Developer/Xcode/Archives/Loose.xcarchive/x", bytes: 1_000).deletingLastPathComponent()
        let notArchive = try box.file("Library/Developer/Xcode/Archives/2026-05-01/folder/x", bytes: 1_000).deletingLastPathComponent()
        let real = try archive(box, "2026-05-01", "Real")
        let link = box.home.appendingPathComponent("Library/Developer/Xcode/Archives/2026-05-01/Link.xcarchive")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious)
        let traversal = box.home.appendingPathComponent("Library/Developer/Xcode/Archives/2026-05-01/../../../../Documents/work.xcarchive")

        let guardian = PathGuard(home: box.home)
        for url in [precious, loose, notArchive, link, traversal] {
            let item = Finding(id: "x", ecosystem: .swift, title: "x", location: url.path, bytes: 1, tier: .review,
                               rebuild: .recreate, action: .removeArchive(url))
            XCTAssertEqual(Cleaner(guardian: guardian, runningApps: FakeRunning().provider).clean([item]).removed, 0, url.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.appendingPathComponent("thesis").path), "Documents are safe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: loose.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notArchive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
    }

    func testIsArchive() throws {
        let home = URL(fileURLWithPath: "/Users/x")
        func check(_ p: String) -> Bool { XcodeArchives.isArchive(URL(fileURLWithPath: p), home: home) }
        XCTAssertTrue(check("/Users/x/Library/Developer/Xcode/Archives/2026-05-01/App.xcarchive"))
        XCTAssertFalse(check("/Users/x/Library/Developer/Xcode/Archives/App.xcarchive"), "One level only")
        XCTAssertFalse(check("/Users/x/Library/Developer/Xcode/Archives/2026-05-01/sub/App.xcarchive"), "Three levels")
        XCTAssertFalse(check("/Users/x/Library/Developer/Xcode/Archives/2026-05-01/App"))
        XCTAssertFalse(check("/Users/x/Library/Developer/Xcode/Archives/../../../../Documents/2026/App.xcarchive"))
        XCTAssertFalse(check("/Users/y/Library/Developer/Xcode/Archives/2026-05-01/App.xcarchive"), "Another user")
    }
}

// MARK: - The words of the dialogs

final class ConfirmationTests: XCTestCase {
    private func item(_ action: Action, rebuild: Rebuild = .download, tier: Tier = .review, last: Date? = nil) -> Finding {
        Finding(id: "x", ecosystem: .swift, title: "Thing", location: "Where", bytes: 3_000_000_000, tier: tier,
                rebuild: rebuild, action: action, lastActivity: last)
    }

    private let cases: [(Confirmation.Kind, Action, Bool)] = [
        (.volume, .docker(.removeVolume(name: "data")), true),
        (.simulatorDevice, .simulator(.deleteDevice(udid: uid("1"))), true),
        (.archive, .removeArchive(URL(fileURLWithPath: "/x/Archives/d/A.xcarchive")), true),
        (.container, .docker(.removeContainer(id: "0123456789ab")), true),
        (.simulatorRuntime, .simulator(.deleteRuntime(id: uid("1"))), true),
    ]

    func testWhereAMistakeLosesDataTheDefaultButtonKeepsTheItem() {
        for (kind, action, cancelDefault) in cases {
            let c = Confirmation.forOne(item(action), staleDays: 30)
            XCTAssertEqual(Confirmation.kind(of: item(action)), kind)
            XCTAssertEqual(c.cancelIsDefault, cancelDefault, "\(kind)")
        }
        let ordinary = Confirmation.forOne(item(.owner(.brewCleanup), tier: .safe), staleDays: 30)
        XCTAssertFalse(ordinary.cancelIsDefault)
    }

    /// One sample finding for each kind, and the decision for its default button.
    /// A new `Kind` case fails this test until someone adds it here and decides.
    func testEachKindHasADecidedDefaultButton() {
        let url = URL(fileURLWithPath: "/x/item")
        let samples: [(Confirmation.Kind, Finding, Bool)] = [
            (.ordinary, item(.owner(.brewCleanup), tier: .safe), false),
            (.container, item(.docker(.removeContainer(id: "0123456789ab"))), true),
            (.volume, item(.docker(.removeVolume(name: "data"))), true),
            (.simulatorRuntime, item(.simulator(.deleteRuntime(id: uid("1")))), true),
            (.simulatorDevice, item(.simulator(.deleteDevice(udid: uid("1")))), true),
            (.archive, item(.removeArchive(url)), true),
            (.deviceSupport, item(.removeDeviceSupport(url)), true),
            (.serviceWorker, item(.removeServiceWorkerStorage(browserID: "b")), true),
            (.trash, item(.emptyTrash), true),
            (.installer, item(.removeInstaller(url)), true),
            (.oldLogs, item(.removeOldLogs(.logs)), true),
            (.brewPackage, item(.brew(.uninstall(name: "pkg"))), true),
            (.agentRuntime, item(.agent(.removeOldClaudeDesktopRuntimes(names: []))), true),
            (.vmBundle, item(.agent(.removeClaudeVMBundle)), true),
            (.localModel, item(.agent(.removeOllamaModel(name: "m"))), true),
            (.agentSessions, item(.agent(.removeOldSessions(kind: .codex, olderThan: Date(), minimumAgeDays: 30))), true),
            (.globalPackage, item(.globalPackage(manager: .npm, name: "pkg")), true),
            (.runtime, item(.removeRuntime(storeID: "s", tool: "t", name: "n")), true),
            (.cacheFolder, item(.removeCacheFolderContents(name: "Some Cache")), true),
            (.containerWithVolumes, item(.docker(.removeStoppedContainerWithVolumes(id: "0123456789ab", volumes: ["v"]))), true),
            (.runningContainer, item(.docker(.stopAndRemoveContainerWithVolumes(id: "0123456789ab", volumes: ["v"]))), true),
            (.worktree, item(.worktree(.remove(repo: URL(fileURLWithPath: "/x/repo"), path: url))), true),
            (.worktreeRecords, item(.worktree(.prune(repo: URL(fileURLWithPath: "/x/repo"), paths: ["/x/gone"]))), true),
        ]
        XCTAssertEqual(Set(samples.map { "\($0.0)" }), Set(Confirmation.Kind.allCases.map { "\($0)" }),
                       "Each kind needs a sample and a decision")
        XCTAssertEqual(samples.count, Confirmation.Kind.allCases.count)
        for (kind, finding, cancelDefault) in samples {
            XCTAssertEqual(Confirmation.kind(of: finding), kind)
            XCTAssertEqual(Confirmation.forOne(finding, staleDays: 30).cancelIsDefault, cancelDefault, "\(kind)")
        }
    }

    func testEveryDestructiveDialogSaysThatItCannotBeUndone() {
        for (kind, action, _) in cases {
            let c = Confirmation.forOne(item(action), staleDays: 30)
            XCTAssertTrue(c.footer?.contains("can't be undone") == true, "\(kind): \(c.footer ?? "nil")")
            XCTAssertNotNil(c.confirmTitle, "\(kind) has its own button text")
            XCTAssertFalse(c.confirmTitle!.hasPrefix("Free up"), "\(kind): the button says what it does")
        }
    }

    func testEachKindWarnsAboutItsOwnRisk() {
        func footer(_ a: Action) -> String { Confirmation.forOne(item(a), staleDays: 30).footer ?? "" }
        XCTAssertTrue(footer(cases[0].1).contains("database"))
        XCTAssertTrue(footer(cases[1].1).contains("Apps and data"))
        XCTAssertTrue(footer(cases[2].1).contains("dSYMs") && footer(cases[2].1).contains("crash reports"))
        XCTAssertTrue(footer(cases[3].1).contains("stored nowhere else"))
        XCTAssertTrue(footer(cases[4].1).contains("download it again") && footer(cases[4].1).contains("stop working"))
    }

    func testTitlesAreDistinctAndAskOneQuestion() {
        let titles = cases.map { Confirmation.forOne(item($0.1), staleDays: 30).title }
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertTrue(titles.allSatisfy { $0.hasSuffix("?") })
    }

    func testAnOrdinaryItemKeepsTheOldWords() {
        let now = Date()
        let c = Confirmation.forOne(item(.removeArtifact(URL(fileURLWithPath: "/x/node_modules")), rebuild: .minutes,
                                         last: now.addingTimeInterval(-3 * 86_400)), staleDays: 30, now: now)
        XCTAssertEqual(c.title, "Free up 3.0 GB?")
        XCTAssertNil(c.footer, "The default sentence is used")
        XCTAssertNil(c.confirmTitle)
        XCTAssertTrue(c.body.contains("You worked on this project 3 days ago."))
        XCTAssertTrue(Confirmation.defaultFooter.contains("can't be undone"))
    }
}
