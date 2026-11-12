import XCTest
@testable import PandaCore

/// Step 2b of #197: the plan checks again now, with the same functions as the Cleaner, what it can check without a program.
/// Each action has: a good case, a forged case, an item that became a link after the scan, and a parent folder that became a link.
final class CleanPlanRecheckTests: XCTestCase {
    private let notThere = "not there now"
    private let wrongShape = "not the kind of path that the clean takes"
    private let link = "a folder in the path is a link"

    private func item(_ action: Action, _ box: Sandbox, keep: [String] = [], running: RunningSnapshot = RunningSnapshot(apps: []),
                      owner: AppOwner? = nil, active: [String]? = nil, now: Date = Date()) -> CleanPlan.Item {
        let f = Finding(id: "x", ecosystem: .swift, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .seconds, action: action, owner: owner)
        let plan = CleanPlan(ScanResult(findings: [f], disk: DiskUsage(total: 1, free: 1)), guardian: PathGuard(home: box.home, keep: keep),
                             running: running, deleteMode: .permanent, activeDirectories: active, now: now)
        return plan.items[0]
    }

    private func symlink(_ at: URL, to: URL) throws {
        try? FileManager.default.removeItem(at: at)
        try FileManager.default.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: at, withDestinationURL: to)
    }

    private func url(_ box: Sandbox, _ rel: String) -> URL { box.home.appendingPathComponent(rel) }

    /// Runs the real Cleaner on one finding in a copy of the same state, and returns true when the path is gone.
    /// It is the proof that the plan says the same as the Cleaner. It is a test: the plan itself never calls it.
    private func cleanerRemoves(_ action: Action, _ box: Sandbox, probe: URL) -> Bool {
        let cleaner = Cleaner(guardian: PathGuard(home: box.home), runningApps: RunningApps { RunningSnapshot(apps: []) },
                              programPaths: { [] }, mountedImages: { [] }, freeSpace: { _ in 0 })
        cleaner.activeDirectories = { [] }
        let f = Finding(id: "x", ecosystem: .swift, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .seconds, action: action)
        _ = cleaner.clean([f])
        return !FileManager.default.fileExists(atPath: probe.path)
    }

    // MARK: removeContents (guard and exists)

    func testContentsFolderThatIsGoneIsNotThereNow() throws {
        let box = try Sandbox()
        let gone = item(.removeContents(url(box, "Library/Caches/Gone")), box)
        XCTAssertFalse(gone.wouldClean)
        XCTAssertEqual(gone.skipReason, notThere)
        XCTAssertTrue(gone.checkedNow)
        try box.file("Library/Caches/Here/a", bytes: 1)
        XCTAssertTrue(item(.removeContents(url(box, "Library/Caches/Here")), box).wouldClean)
    }

    func testKeepListAndGuardAreCheckedNow() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Kept/a", bytes: 1)
        let kept = item(.removeContents(url(box, "Library/Caches/Kept")), box, keep: [url(box, "Library/Caches/Kept").path])
        XCTAssertEqual(kept.skipReason, "on the keep list")
        XCTAssertTrue(kept.checkedNow)
        try box.file("Library/Caches/Fine/a", bytes: 1)
        try symlink(url(box, "Library/Caches/Link"), to: url(box, "Library/Caches/Fine"))
        XCTAssertEqual(item(.removeContents(url(box, "Library/Caches/Link")), box).skipReason, "refused by the path guard: path is a symbolic link")
    }

    // MARK: Build folder

    private func makeProject(_ box: Sandbox) throws -> URL {
        try box.file("Developer/app/package.json", bytes: 5)
        return try box.file("Developer/app/node_modules/x/a", bytes: 5).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testArtifactGoodForgedLinkAndParentLink() throws {
        let box = try Sandbox()
        let build = try makeProject(box)
        let good = item(.removeArtifact(build), box)
        XCTAssertTrue(good.wouldClean, good.skipReason)
        XCTAssertTrue(good.checkedNow)
        XCTAssertEqual(good.checkedAtCleanTime, "project use is read again")

        // Forged: a folder with a name that is no build folder, and one that is not there.
        try box.file("Developer/app/src/main.swift", bytes: 5)
        XCTAssertEqual(item(.removeArtifact(url(box, "Developer/app/src")), box).skipReason, wrongShape)
        XCTAssertEqual(item(.removeArtifact(url(box, "Developer/app/dist")), box).skipReason, notThere)

        // A parent folder became a link that leads to another place INSIDE the home folder. The guard sees nothing wrong, because the
        // real path is inside the home folder. The Cleaner refuses it (isPlainPath), so the plan must refuse it too.
        try symlink(url(box, "Developer/applink"), to: url(box, "Developer/app"))
        let viaLink = url(box, "Developer/applink/node_modules")
        XCTAssertNil(PathGuard(home: box.home).check(viaLink), "the guard alone accepts it")
        let parent = item(.removeArtifact(viaLink), box)
        XCTAssertFalse(parent.wouldClean)
        XCTAssertEqual(parent.skipReason, link)
        XCTAssertFalse(cleanerRemoves(.removeArtifact(viaLink), box, probe: url(box, "Developer/app/node_modules/x/a")),
                       "the Cleaner refuses it too")

        // The folder itself became a link.
        try FileManager.default.removeItem(at: build)
        try symlink(build, to: url(box, "Developer/app/src"))
        XCTAssertEqual(item(.removeArtifact(build), box).skipReason, "refused by the path guard: path is a symbolic link")
    }

    func testProjectInUseIsReadWhenTheListIsGiven() throws {
        let box = try Sandbox()
        let build = try makeProject(box)
        XCTAssertTrue(item(.removeArtifact(build), box, active: []).wouldClean)
        XCTAssertTrue(item(.removeArtifact(build), box, active: nil).wouldClean, "unknown: the Cleaner reads it again")
        XCTAssertTrue(item(.removeArtifact(build), box, active: [url(box, "Developer/other").path]).wouldClean)
        let inUse = item(.removeArtifact(build), box, active: [box.home.path + "/Developer/app/src"])
        XCTAssertFalse(inUse.wouldClean)
        XCTAssertEqual(inUse.skipReason, "project is in use")
        XCTAssertTrue(inUse.checkedNow)
        XCTAssertEqual(item(.removeArtifact(build), box, active: [box.home.path + "/Developer/app"]).skipReason, "project is in use")
        // The same function as the Cleaner uses.
        XCTAssertTrue(CleanRules.projectInUse(artifact: build, active: [box.home.path + "/Developer/app/x"]))
        XCTAssertFalse(CleanRules.projectInUse(artifact: build, active: [box.home.path + "/Developer/app2"]))
    }

    // MARK: Archive and device support

    func testArchive() throws {
        let box = try Sandbox()
        let archive = try box.file("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist", bytes: 5)
            .deletingLastPathComponent()
        let good = item(.removeArchive(archive), box)
        XCTAssertTrue(good.wouldClean, good.skipReason)
        XCTAssertEqual(good.checkedAtCleanTime, "")
        // Forged: the wrong name, and the wrong depth.
        try box.file("Library/Developer/Xcode/Archives/2026-01-01/Other/x", bytes: 5)
        XCTAssertEqual(item(.removeArchive(url(box, "Library/Developer/Xcode/Archives/2026-01-01/Other")), box).skipReason, wrongShape)
        XCTAssertEqual(item(.removeArchive(url(box, "Library/Developer/Xcode/Archives/2026-01-01")), box).skipReason, wrongShape)
        XCTAssertEqual(item(.removeArchive(url(box, "Library/Developer/Xcode/Archives/2026-01-01/Gone.xcarchive")), box).skipReason, notThere)
        // A parent folder is a link that leads to another place in the home folder.
        let real = url(box, "Elsewhere")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url(box, "Library/Developer/Xcode/Archives"), to: real)
        try symlink(url(box, "Library/Developer/Xcode/Archives"), to: real)
        let parent = item(.removeArchive(archive), box)
        XCTAssertEqual(parent.skipReason, link)
        XCTAssertFalse(cleanerRemoves(.removeArchive(archive), box, probe: url(box, "Elsewhere/2026-01-01/App.xcarchive/Info.plist")))
        // The archive itself became a link.
        try FileManager.default.removeItem(at: real.appendingPathComponent("2026-01-01/App.xcarchive"))
        try symlink(real.appendingPathComponent("2026-01-01/App.xcarchive"), to: url(box, "Documents"))
        XCTAssertFalse(item(.removeArchive(archive), box).wouldClean)
    }

    func testDeviceSupport() throws {
        let box = try Sandbox()
        let name = "iPhone14,2 17.0 (21A329)"
        let folder = try box.file("Library/Developer/Xcode/iOS DeviceSupport/\(name)/Symbols/x", bytes: 5)
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(item(.removeDeviceSupport(folder), box).wouldClean)
        try box.file("Library/Developer/Xcode/iOS DeviceSupport/NotAVersion/x", bytes: 5)
        XCTAssertEqual(item(.removeDeviceSupport(url(box, "Library/Developer/Xcode/iOS DeviceSupport/NotAVersion")), box).skipReason, wrongShape)
        XCTAssertEqual(item(.removeDeviceSupport(url(box, "Library/Developer/Xcode/iOS DeviceSupport/17.1 (21B80)")), box).skipReason, notThere)
        // The platform folder became a link to another place in the home folder.
        let real = url(box, "Elsewhere")
        try FileManager.default.moveItem(at: url(box, "Library/Developer/Xcode/iOS DeviceSupport"), to: real)
        try symlink(url(box, "Library/Developer/Xcode/iOS DeviceSupport"), to: real)
        XCTAssertEqual(item(.removeDeviceSupport(folder), box).skipReason, link)
        XCTAssertFalse(cleanerRemoves(.removeDeviceSupport(folder), box, probe: real.appendingPathComponent("\(name)/Symbols/x")))
        // The folder itself became a link.
        try FileManager.default.removeItem(at: real.appendingPathComponent(name))
        try symlink(real.appendingPathComponent(name), to: url(box, "Documents"))
        XCTAssertFalse(item(.removeDeviceSupport(folder), box).wouldClean)
    }

    // MARK: Update downloads

    func testUpdateDownloads() throws {
        let box = try Sandbox()
        let sparkle = url(box, "Library/Caches/com.example.app/org.sparkle-project.Sparkle")
        let old = try box.file("Library/Caches/com.example.app/org.sparkle-project.Sparkle/Installation/old.zip", bytes: 5, age: 20)
        let good = item(.removeUpdateDownloads(sparkle), box)
        XCTAssertTrue(good.wouldClean, good.skipReason)
        XCTAssertEqual(good.checkedAtCleanTime, "age is read again")
        // A new file is not old: nothing to clean now.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: old.path)
        XCTAssertEqual(item(.removeUpdateDownloads(sparkle), box).skipReason, "nothing to clean now")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -20 * 86_400)], ofItemAtPath: old.path)
        // Forged: not a Sparkle folder.
        try box.file("Library/Caches/com.example.app/Other/x", bytes: 5, age: 20)
        XCTAssertEqual(item(.removeUpdateDownloads(url(box, "Library/Caches/com.example.app/Other")), box).skipReason, wrongShape)
        XCTAssertEqual(item(.removeUpdateDownloads(url(box, "Library/Caches/com.example.gone/org.sparkle-project.Sparkle")), box).skipReason, notThere)
        // A parent folder (the app folder) became a link to another place in the home folder.
        let real = url(box, "Elsewhere")
        try FileManager.default.moveItem(at: url(box, "Library/Caches/com.example.app"), to: real)
        try symlink(url(box, "Library/Caches/com.example.app"), to: real)
        XCTAssertEqual(item(.removeUpdateDownloads(sparkle), box).skipReason, link)
        XCTAssertFalse(cleanerRemoves(.removeUpdateDownloads(sparkle), box, probe: real.appendingPathComponent("org.sparkle-project.Sparkle/Installation/old.zip")))
        // A file in the folder became a link: it is not listed as old, so nothing is left to clean.
        try FileManager.default.removeItem(at: url(box, "Library/Caches/com.example.app"))
        try box.file("Library/Caches/com.example.app/org.sparkle-project.Sparkle/Installation/x", bytes: 5)
        try symlink(url(box, "Library/Caches/com.example.app/org.sparkle-project.Sparkle/Installation/l"), to: url(box, "Documents"))
        XCTAssertFalse(item(.removeUpdateDownloads(sparkle), box).wouldClean)
    }

    // MARK: Cache folder (cache explorer)

    func testCacheFolderContents() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/Foo/a", bytes: 5)
        let good = item(.removeCacheFolderContents(name: "Foo"), box)
        XCTAssertTrue(good.wouldClean, good.skipReason)
        XCTAssertTrue(good.checkedNow)
        // Forged names.
        XCTAssertEqual(item(.removeCacheFolderContents(name: "Gone"), box).skipReason, notThere)
        XCTAssertFalse(item(.removeCacheFolderContents(name: "../Documents"), box).wouldClean)
        // A name that has its own item in the group of its tool.
        try box.file("Library/Caches/pip/a", bytes: 5)
        XCTAssertEqual(item(.removeCacheFolderContents(name: "pip"), box).skipReason, wrongShape)
        // A file, not a folder.
        try box.file("Library/Caches/AFile", bytes: 5)
        XCTAssertEqual(item(.removeCacheFolderContents(name: "AFile"), box).skipReason, wrongShape)
        // The folder became a link.
        try symlink(url(box, "Library/Caches/Linked"), to: url(box, "Library/Caches/Foo"))
        XCTAssertEqual(item(.removeCacheFolderContents(name: "Linked"), box).skipReason, "refused by the path guard: path is a symbolic link")
        // The Caches folder itself became a link to another place in the home folder.
        let real = url(box, "RealCaches")
        try FileManager.default.moveItem(at: url(box, "Library/Caches"), to: real)
        try symlink(url(box, "Library/Caches"), to: real)
        XCTAssertEqual(item(.removeCacheFolderContents(name: "Foo"), box).skipReason, link)
        XCTAssertFalse(cleanerRemoves(.removeCacheFolderContents(name: "Foo"), box, probe: real.appendingPathComponent("Foo/a")))
    }

    // MARK: Browser caches, old logs, old test browsers

    func testBrowserCaches() throws {
        let box = try Sandbox()
        XCTAssertEqual(item(.removeBrowserCaches(browserID: "chrome"), box).skipReason, "nothing to clean now")
        let cache = try box.file("Library/Caches/Google/Chrome/Default/Cache/a", bytes: 5).deletingLastPathComponent()
        let good = item(.removeBrowserCaches(browserID: "chrome"), box)
        XCTAssertTrue(good.wouldClean, good.skipReason)
        XCTAssertTrue(good.checkedNow)
        XCTAssertEqual(good.checkedAtCleanTime, "targets are found again")
        // Forged id.
        XCTAssertEqual(item(.removeBrowserCaches(browserID: "nope"), box).skipReason, wrongShape)
        // The keep list reaches the resolved folders.
        XCTAssertEqual(item(.removeBrowserCaches(browserID: "chrome"), box, keep: [cache.path]).skipReason, "on the keep list")
        // The cache folder became a link: the list of targets drops it, so nothing is left to clean.
        try FileManager.default.removeItem(at: cache)
        try symlink(cache, to: url(box, "Documents"))
        XCTAssertEqual(item(.removeBrowserCaches(browserID: "chrome"), box).skipReason, "nothing to clean now")
        // A parent (the root of the browser) became a link to another place in the home folder.
        try FileManager.default.removeItem(at: cache)
        try box.file("Library/Caches/Google/Chrome/Default/Cache/a", bytes: 5)
        let real = url(box, "Elsewhere")
        try FileManager.default.moveItem(at: url(box, "Library/Caches/Google"), to: real)
        try symlink(url(box, "Library/Caches/Google"), to: real)
        XCTAssertFalse(item(.removeBrowserCaches(browserID: "chrome"), box).wouldClean)
    }

    func testOldLogs() throws {
        let box = try Sandbox()
        XCTAssertEqual(item(.removeOldLogs(.logs), box).skipReason, "nothing to clean now")
        try box.file("Library/Logs/old.log", bytes: 5, age: 60)
        let good = item(.removeOldLogs(.logs), box)
        XCTAssertTrue(good.wouldClean, good.skipReason)
        XCTAssertEqual(good.checkedAtCleanTime, "age is read again")
        XCTAssertEqual(item(.removeOldLogs(.crashReports), box).skipReason, "nothing to clean now")
        // A new file is not old.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url(box, "Library/Logs/old.log").path)
        XCTAssertEqual(item(.removeOldLogs(.logs), box).skipReason, "nothing to clean now")
        // The file became a link: it is not listed.
        try FileManager.default.removeItem(at: url(box, "Library/Logs/old.log"))
        try symlink(url(box, "Library/Logs/old.log"), to: url(box, "Documents"))
        XCTAssertEqual(item(.removeOldLogs(.logs), box).skipReason, "nothing to clean now")
        // The Logs folder became a link to another place in the home folder.
        try FileManager.default.removeItem(at: url(box, "Library/Logs/old.log"))
        try box.file("Library/Logs/old.log", bytes: 5, age: 60)
        let real = url(box, "Elsewhere")
        try FileManager.default.moveItem(at: url(box, "Library/Logs"), to: real)
        try symlink(url(box, "Library/Logs"), to: real)
        XCTAssertFalse(item(.removeOldLogs(.logs), box).wouldClean)
    }

    func testOldTestBrowsers() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/ms-playwright/chromium-1000/a", bytes: 5)
        XCTAssertEqual(item(.removeOldTestBrowsers(toolID: "playwright"), box).skipReason, "nothing to clean now", "the newest stays")
        try box.file("Library/Caches/ms-playwright/chromium-1001/a", bytes: 5)
        let good = item(.removeOldTestBrowsers(toolID: "playwright"), box)
        XCTAssertTrue(good.wouldClean, good.skipReason)
        XCTAssertEqual(good.checkedAtCleanTime, "running programs are read again")
        XCTAssertEqual(item(.removeOldTestBrowsers(toolID: "nope"), box).skipReason, wrongShape)
        XCTAssertEqual(item(.removeOldTestBrowsers(toolID: "playwright"), box, keep: [url(box, "Library/Caches/ms-playwright/chromium-1000").path]).skipReason,
                       "on the keep list")
        // The old version became a link: it is not listed.
        try FileManager.default.removeItem(at: url(box, "Library/Caches/ms-playwright/chromium-1000"))
        try symlink(url(box, "Library/Caches/ms-playwright/chromium-1000"), to: url(box, "Documents"))
        XCTAssertEqual(item(.removeOldTestBrowsers(toolID: "playwright"), box).skipReason, "nothing to clean now")
        // The root became a link to another place in the home folder.
        try FileManager.default.removeItem(at: url(box, "Library/Caches/ms-playwright/chromium-1000"))
        try box.file("Library/Caches/ms-playwright/chromium-1000/a", bytes: 5)
        let real = url(box, "Elsewhere")
        try FileManager.default.moveItem(at: url(box, "Library/Caches/ms-playwright"), to: real)
        try symlink(url(box, "Library/Caches/ms-playwright"), to: real)
        XCTAssertFalse(item(.removeOldTestBrowsers(toolID: "playwright"), box).wouldClean)
    }

    /// The lists of the browser, the logs, and the test browsers come from functions that already drop links, so the shape check of the
    /// list cannot fail on a real disk. It is a second line of defence, the same as in the Cleaner. This test gives it a forged list.
    func testAForgedResolvedListIsCheckedAgainstTheShape() throws {
        let box = try Sandbox()
        try box.file("Elsewhere/Logs/old.log", bytes: 5, age: 60)
        try symlink(url(box, "Library/Logs"), to: url(box, "Elsewhere/Logs"))
        let plain = try Sandbox()
        let plainLog = try plain.file("Library/Logs/old.log", bytes: 5, age: 60)
        let f = Finding(id: "x", ecosystem: .swift, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .seconds, action: .removeOldLogs(.logs))
        func decide(_ list: [URL], in home: URL) -> CleanPlan.Decision {
            CleanPlan.decide(f, guardian: PathGuard(home: home), running: RunningSnapshot(apps: []), active: nil, now: Date()) { _, _, _ in
                var i = CleanPlan.Inspection()
                i.resolved = list
                i.resolvedShape = { CleanRules.isOldLogTarget($0, kind: .logs, home: home) }
                return i
            }
        }
        XCTAssertEqual(decide([url(box, "Library/Logs/old.log")], in: box.home).reason, link)
        XCTAssertEqual(decide([url(box, "Documents/x")], in: box.home).reason, "refused by the path guard: path is protected (Documents)")
        XCTAssertEqual(decide([plain.home.appendingPathComponent("Library/Logs/trashpanda/x.log")], in: plain.home).reason, wrongShape)
        XCTAssertNil(decide([plainLog], in: plain.home).reason, "a file in a plain place with the right shape is accepted")
        XCTAssertEqual(decide([], in: plain.home).reason, "nothing to clean now")
    }

    // MARK: Installer

    func testInstaller() throws {
        let box = try Sandbox()
        let dmg = try box.file("Downloads/App.dmg", bytes: 5, age: 60)
        let good = item(.removeInstaller(dmg), box)
        XCTAssertTrue(good.wouldClean, good.skipReason)
        XCTAssertEqual(good.checkedAtCleanTime, "mounted disk images are read again")
        // Too new.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dmg.path)
        XCTAssertEqual(item(.removeInstaller(dmg), box).skipReason, wrongShape)
        // Forged name, forged place, and not there.
        try box.file("Downloads/notes.txt", bytes: 5, age: 60)
        XCTAssertEqual(item(.removeInstaller(url(box, "Downloads/notes.txt")), box).skipReason, wrongShape)
        XCTAssertEqual(item(.removeInstaller(url(box, "Downloads/Gone.dmg")), box).skipReason, notThere)
        // The file became a link.
        try FileManager.default.removeItem(at: dmg)
        try symlink(dmg, to: url(box, "Documents/letter.txt"))
        XCTAssertEqual(item(.removeInstaller(dmg), box).skipReason, "refused by the path guard: path is a symbolic link")
        // The Downloads folder became a link to another place in the home folder.
        try FileManager.default.removeItem(at: dmg)
        try box.file("Downloads/App.dmg", bytes: 5, age: 60)
        let real = url(box, "Elsewhere")
        try FileManager.default.moveItem(at: url(box, "Downloads"), to: real)
        try symlink(url(box, "Downloads"), to: real)
        XCTAssertEqual(item(.removeInstaller(dmg), box).skipReason, link)
    }

    // MARK: Honest labels for the rest

    func testToolAndFindAgainActionsSayWhatIsDecidedLater() throws {
        let box = try Sandbox()
        for action in [Action.emptyTrash, .docker(.removeVolume(name: "v")), .brew(.uninstall(name: "x"))] {
            let i = item(action, box)
            XCTAssertTrue(i.wouldClean)
            XCTAssertFalse(i.checkedNow)
            XCTAssertEqual(i.checkedAtCleanTime, "tool decides")
        }
        for action in [Action.removeRuntime(storeID: "a", tool: "b", name: "c"), .removeServiceWorkerStorage(browserID: "chrome"),
                       .agent(.removeFixedFolders(appID: "x"))] {
            let i = item(action, box)
            XCTAssertTrue(i.wouldClean)
            XCTAssertFalse(i.checkedNow)
            XCTAssertEqual(i.checkedAtCleanTime, "targets are found again")
        }
        // A tool item with an owner app: both are named, and an open app skips it.
        let owner = AppOwner(name: "Example", bundleIDs: ["com.example"])
        XCTAssertEqual(item(.emptyTrash, box, owner: owner).checkedAtCleanTime, "tool decides; app state is read again")
        let open = RunningSnapshot(apps: [RunningApp(bundleID: "com.example", name: "Example")])
        let skipped = item(.emptyTrash, box, running: open, owner: owner)
        XCTAssertEqual(skipped.skipReason, "owner app is open (Example)")
        XCTAssertEqual(skipped.checkedAtCleanTime, "")
    }
}
