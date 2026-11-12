import Foundation

/// The shape checks of the Cleaner, in one place. The Cleaner calls them before it deletes. `CleanPlan` (the dry run) calls the
/// same functions, so the two cannot drift. Every function here only reads. None of them changes a file or runs a program.
enum CleanRules {
    /// The same test as the Cleaner uses before it touches a path.
    static func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

    /// True when the folder can be listed. The Cleaner lists the folder of a "remove contents" item, and it fails when it cannot.
    static func isReadableFolder(_ url: URL) -> Bool { (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil }

    static func isPlain(_ url: URL) -> Bool { UpdateDownloads.isPlainPath(url) }

    /// A build folder: no link in the path, and a known build folder name.
    static func isArtifactTarget(_ url: URL) -> Bool { isPlain(url) && Catalog.isArtifactFolder(url) }

    static func isArchiveTarget(_ url: URL, home: URL) -> Bool { XcodeArchives.isArchive(url, home: home) && isPlain(url) }

    static func isDeviceSupportTarget(_ url: URL, home: URL) -> Bool { DeviceSupport.isDeviceSupport(url, home: home) && isPlain(url) }

    static func isSparkleTarget(_ sparkle: URL, home: URL) -> Bool { UpdateDownloads.isSparkleFolder(sparkle, home: home) && isPlain(sparkle) }

    /// One of the cleaned folders of the Sparkle folder, then one child of it. Nothing deeper, and no link on the way.
    static func isUpdateItemTarget(_ url: URL, sparkle: URL, home: URL) -> Bool {
        let sparklePrefix = sparkle.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        let parts = path.hasPrefix(sparklePrefix) ? path.dropFirst(sparklePrefix.count).split(separator: "/").map(String.init) : []
        return UpdateDownloads.isSparkleFolder(sparkle, home: home) && parts.count == 2
            && UpdateDownloads.cleanedFolders.contains(parts[0]) && isPlain(url)
    }

    static func isBrowserCacheTarget(_ url: URL, of browser: Browser, home: URL) -> Bool {
        BrowserCaches.isTarget(url, of: browser, home: home) && isPlain(url)
    }

    static func isOldLogTarget(_ url: URL, kind: OldLogs.Kind, home: URL) -> Bool {
        OldLogs.kind(of: url, home: home) == kind && isPlain(url)
    }

    static func isTestBrowserTarget(_ url: URL, of tool: TestBrowserTool, home: URL) -> Bool {
        TestBrowsers.isVersionFolder(url, of: tool, home: home) && isPlain(url)
    }

    /// Why a cache folder name is not accepted. nil when it is accepted.
    enum CacheFolderProblem: Equatable {
        case badName, hasOwnItem, notPlainFolder
    }

    static func cacheFolder(named name: String, home: URL) -> (folder: URL, problem: CacheFolderProblem?) {
        let folder = home.appendingPathComponent("Library/Caches", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        guard CacheExplorer.isFolderName(name) else { return (folder, .badName) }
        guard !CacheExplorer.catalogNames().contains(name) else { return (folder, .hasOwnItem) }
        guard (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType == .typeDirectory,
              isPlain(folder), isPlain(folder.deletingLastPathComponent()) else { return (folder, .notPlainFolder) }
        return (folder, nil)
    }

    /// A folder of iCloud or macOS is emptied only because the owner chose it. The guard lifts its rule for that one name.
    static func systemCacheName(_ name: String) -> String? { CacheExplorer.keepReason(name) != nil ? name : nil }

    /// True when a program runs inside the project of this build folder. `active` is the list of working folders.
    static func projectInUse(artifact url: URL, active: [String]) -> Bool {
        let project = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return active.contains(where: { $0 == project || $0.hasPrefix(project + "/") })
    }
}
