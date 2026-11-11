import AppKit
import XCTest
@testable import PandaCore

/// A fake view of what runs. It counts how often the cleaner looks.
final class FakeRunning: @unchecked Sendable {
    var apps: [RunningApp]
    var processes: Set<String>
    private(set) var looks = 0

    init(apps: [RunningApp] = [], processes: Set<String> = []) {
        self.apps = apps
        self.processes = processes
    }

    var provider: RunningApps {
        RunningApps { [self] in
            looks += 1
            return RunningSnapshot(apps: apps, processes: processes)
        }
    }

    static let xcode = RunningApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")
}

final class RunningAppTests: XCTestCase {
    // MARK: Matching

    func testBundleIDsMatchExactlyOrByFamily() {
        let xcode = AppOwner(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"])
        XCTAssertTrue(xcode.matches(bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(xcode.matches(bundleID: "COM.APPLE.DT.XCODE"), "Bundle IDs are not case sensitive")
        XCTAssertFalse(xcode.matches(bundleID: "com.apple.dt.Xcode.Beta"), "An exact ID is exact")
        XCTAssertFalse(xcode.matches(bundleID: "com.apple.Safari"))

        let family = AppOwner(name: "JetBrains", bundleIDs: ["com.jetbrains.*"])
        XCTAssertTrue(family.matches(bundleID: "com.jetbrains.pycharm"))
        XCTAssertTrue(family.matches(bundleID: "com.jetbrains.intellij.ce"))
        XCTAssertFalse(family.matches(bundleID: "com.jetbrainsfake.app"), "The dot is part of the family")
        XCTAssertFalse(family.matches(bundleID: "org.jetbrains.x"))
        XCTAssertFalse(AppOwner(name: "None", bundleIDs: []).matches(bundleID: "com.apple.dt.Xcode"))
    }

    func testTheSnapshotNamesTheProgramsThatRun() {
        let owner = AppOwner(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"], processNames: ["xcodebuild"])
        let both = RunningSnapshot(apps: [FakeRunning.xcode, RunningApp(bundleID: "com.apple.Safari", name: "Safari")],
                                   processes: ["xcodebuild", "zsh"])
        XCTAssertEqual(both.running(owner), ["Xcode", "xcodebuild"])
        XCTAssertEqual(RunningSnapshot(apps: [], processes: ["xcodebuild"]).running(owner), ["xcodebuild"])
        XCTAssertTrue(RunningSnapshot(apps: [RunningApp(bundleID: "com.apple.Safari", name: "Safari")],
                                      processes: ["zsh"]).running(owner).isEmpty)
    }

    // MARK: The cleaner

    /// A real DerivedData folder in a fake home folder, found by the real scan.
    private func derivedData(_ box: Sandbox) throws -> (DiskScanner, Finding, URL) {
        let file = try box.file("Library/Developer/Xcode/DerivedData/App-abc/Build/Products/x.o", bytes: 3_000_000)
        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let finding = try XCTUnwrap(scanner.scanCaches().first { $0.id.hasPrefix("xcode.derived") })
        return (scanner, finding, file)
    }

    func testNothingIsCleanedWhileItsAppRuns() throws {
        let box = try Sandbox()
        let (scanner, finding, file) = try derivedData(box)
        XCTAssertEqual(finding.owner?.name, "Xcode", "The scan names the owner")

        let fake = FakeRunning(apps: [FakeRunning.xcode])
        let report = Cleaner(guardian: scanner.guardian, runningApps: fake.provider).clean([finding])

        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.blockedApps, ["Xcode"], "The report names the app to quit")
        XCTAssertTrue(report.skipped.joined().contains("Xcode is running"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The file is untouched")
    }

    func testTheItemIsCleanedWhenTheAppIsNotRunning() throws {
        let box = try Sandbox()
        let (scanner, finding, file) = try derivedData(box)
        let fake = FakeRunning(apps: [RunningApp(bundleID: "com.apple.Safari", name: "Safari")], processes: ["zsh"])

        let report = Cleaner(guardian: scanner.guardian, runningApps: fake.provider).clean([finding])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(report.blockedApps.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Other running apps do not block")
    }

    func testAnXcodebuildProcessBlocksToo() throws {
        let box = try Sandbox()
        let (scanner, finding, file) = try derivedData(box)
        let fake = FakeRunning(processes: ["xcodebuild"])
        let report = Cleaner(guardian: scanner.guardian, runningApps: fake.provider).clean([finding])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.blockedApps, ["xcodebuild"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testOnlyTheBlockedItemsAreSkipped() throws {
        let box = try Sandbox()
        let (scanner, derived, derivedFile) = try derivedData(box)
        let npmFile = try box.file(".npm/_cacache/content/blob", bytes: 3_000_000)
        let npm = try XCTUnwrap(scanner.scanCaches().first { $0.id.hasPrefix("npm.cache") })
        XCTAssertNil(npm.owner)

        let fake = FakeRunning(apps: [FakeRunning.xcode])
        let report = Cleaner(guardian: scanner.guardian, runningApps: fake.provider).clean([derived, npm])

        XCTAssertEqual(report.removed, 1, "The npm cache goes. The Xcode data stays.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: derivedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: npmFile.path))
        XCTAssertEqual(report.blockedApps, ["Xcode"])
    }

    func testAnAppThatStartsAfterTheScanBlocksTheClean() throws {
        let box = try Sandbox()
        let (scanner, finding, file) = try derivedData(box)
        let fake = FakeRunning()                       // Xcode is closed at scan time
        let cleaner = Cleaner(guardian: scanner.guardian, runningApps: fake.provider)

        fake.apps = [FakeRunning.xcode]                // the user opens Xcode before they confirm
        let report = cleaner.clean([finding])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testTheCleanLooksAgainForEachItem() throws {
        let box = try Sandbox()
        let (scanner, derived, _) = try derivedData(box)
        _ = try box.file("Library/Developer/Xcode/DocumentationCache/d", bytes: 3_000_000)
        let docs = try XCTUnwrap(scanner.scanCaches().first { $0.id.hasPrefix("xcode.docs") })
        let fake = FakeRunning()
        _ = Cleaner(guardian: scanner.guardian, runningApps: fake.provider).clean([derived, docs])
        XCTAssertEqual(fake.looks, 2, "One look for each item that has an owner")
    }

    func testAnItemWithNoOwnerNeverTriggersALook() throws {
        let box = try Sandbox()
        _ = try box.file(".npm/_cacache/content/blob", bytes: 3_000_000)
        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let npm = try XCTUnwrap(scanner.scanCaches().first { $0.id.hasPrefix("npm.cache") })
        let fake = FakeRunning(apps: [FakeRunning.xcode])
        let report = Cleaner(guardian: scanner.guardian, runningApps: fake.provider).clean([npm])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(fake.looks, 0, "No owner, no check, no cost")
    }

    func testJetBrainsAndAndroidStudioFamilies() throws {
        let box = try Sandbox()
        _ = try box.file("Library/Caches/JetBrains/PyCharm2026/index/x", bytes: 3_000_000)
        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let finding = try XCTUnwrap(scanner.scanCaches().first { $0.id.hasPrefix("jetbrains.cache") })

        for app in [RunningApp(bundleID: "com.jetbrains.pycharm", name: "PyCharm"),
                    RunningApp(bundleID: "com.google.android.studio", name: "Android Studio"),
                    RunningApp(bundleID: "com.google.android.studio-EAP", name: "Android Studio Preview")] {
            let fake = FakeRunning(apps: [app])
            let report = Cleaner(guardian: scanner.guardian, runningApps: fake.provider).clean([finding])
            XCTAssertEqual(report.removed, 0, app.name)
            XCTAssertEqual(report.blockedApps, [app.name])
        }
    }

    // MARK: The catalog

    /// If someone adds a cache of an IDE and forgets the owner, this test says so.
    func testCachesThatAnAppUsesHaveAnOwner() {
        for spec in Catalog.caches where spec.id.hasPrefix("xcode.") && spec.id != "xcode.sim.unavailable" {
            XCTAssertNotNil(spec.owner, "\(spec.id) belongs to Xcode or the Simulator")
        }
        for id in ["swiftpm.cache", "jetbrains.cache", "dart.analysis"] {
            XCTAssertNotNil(Catalog.caches.first { $0.id == id }?.owner, id)
        }
        XCTAssertNil(Catalog.caches.first { $0.id == "npm.cache" }?.owner, "A package cache has no app")
    }

    // MARK: The real system

    /// This test asks the real macOS. It needs a login session with at least one app. It skips otherwise.
    func testTheRealSystemSeesARunningApp() throws {
        let live = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil && $0.localizedName != nil }
        try XCTSkipIf(live == nil, "No app runs in this session (for example on a machine with no login)")
        let app = try XCTUnwrap(live)
        let owner = AppOwner(name: "x", bundleIDs: [app.bundleIdentifier!])

        let snapshot = RunningApps.system.take()
        XCTAssertEqual(snapshot.running(owner), [app.localizedName!], "The real list names \(app.localizedName!)")
        XCTAssertTrue(snapshot.processes.contains("launchd"), "The real process list holds launchd")
        XCTAssertTrue(RunningApps.system.take().running(AppOwner(name: "x", bundleIDs: ["com.example.not-running"])).isEmpty)
    }

    /// No fakes. A real item, a real cleaner, and the real list of running apps.
    /// Finder runs in every login session, so a cache that Finder owns must not be cleaned.
    func testARealRunningAppBlocksARealClean() throws {
        let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
        try XCTSkipIf(finder == nil, "Finder does not run in this session")

        let box = try Sandbox()
        let file = try box.file(".cache/finder-test/blob", bytes: 3_000_000)
        let dir = file.deletingLastPathComponent()
        let item = Finding(id: "real", ecosystem: .swift, title: "A cache that Finder owns", location: dir.path,
                           bytes: 3_000_000, tier: .safe, rebuild: .seconds, action: .removeContents(dir),
                           owner: AppOwner(name: "Finder", bundleIDs: ["com.apple.finder"]))

        let report = Cleaner(guardian: PathGuard(home: box.home)).clean([item])      // runningApps: .system
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.blockedApps, [finder!.localizedName ?? "Finder"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The file is untouched")

        // The same item with an owner that does not run is cleaned.
        let free = Finding(id: "free", ecosystem: .swift, title: "x", location: dir.path, bytes: 3_000_000,
                           tier: .safe, rebuild: .seconds, action: .removeContents(dir),
                           owner: AppOwner(name: "Nobody", bundleIDs: ["com.example.not-running"]))
        XCTAssertEqual(Cleaner(guardian: PathGuard(home: box.home)).clean([free]).removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTheRealSystemCanBeReadFromABackgroundThread() {
        let done = expectation(description: "read")
        DispatchQueue.global().async {
            _ = RunningApps.system.take()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    // MARK: The cache

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testReadingTheCacheNeverRunsTheReader() {
        let runs = Counter()
        let apps = RunningApps { runs.bump(); return RunningSnapshot(apps: [RunningApp(bundleID: "com.example.a", name: "A")]) }
        for _ in 0..<10 { _ = apps.cached.running(AppOwner(name: "x", bundleIDs: ["com.example.a"])) }
        XCTAssertEqual(runs.value, 0, "The menu reads the cache only. It starts no process")
        XCTAssertTrue(apps.cached.apps.isEmpty, "The cache is empty before the first refresh")
    }

    func testRefreshRunsTheReaderOnceAndFillsTheCache() {
        let runs = Counter()
        let apps = RunningApps {
            runs.bump()
            return RunningSnapshot(apps: [RunningApp(bundleID: "com.example.a", name: "A")], processes: ["tool"])
        }
        let done = expectation(description: "refresh")
        apps.refresh {
            XCTAssertTrue(Thread.isMainThread, "The callback runs on the main queue")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(runs.value, 1)
        XCTAssertEqual(apps.cached.running(AppOwner(name: "x", bundleIDs: ["com.example.a"], processNames: ["tool"])), ["A", "tool"])
        for _ in 0..<10 { _ = apps.cached }
        XCTAssertEqual(runs.value, 1, "Reading the cache again starts nothing")
    }

    func testRefreshDoesNotReadOnTheMainThread() {
        let onMain = Counter()
        let apps = RunningApps { if Thread.isMainThread { onMain.bump() }; return RunningSnapshot(apps: []) }
        let done = expectation(description: "refresh")
        apps.refresh { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(onMain.value, 0)
    }
}
