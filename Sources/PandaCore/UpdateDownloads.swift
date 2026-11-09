import AppKit

/// Old update files of apps that use the Sparkle updater. An app keeps each update that it downloaded in
/// `~/Library/Caches/<bundle id>/org.sparkle-project.Sparkle`. After the update is installed, the files stay.
/// On the author's Mac, one browser kept 2.6 GB this way.
///
/// We touch only the children of `Installation` and `PersistentDownloads` that are old enough.
/// We never touch `Launcher`, and we never touch the rest of the cache of the app.
public enum UpdateDownloads {
    static let folderName = "org.sparkle-project.Sparkle"
    /// The only folders inside it that we clean.
    static let cleanedFolders = ["Installation", "PersistentDownloads"]
    /// An update that is newer than this can still be in progress.
    public static let minimumAgeDays = 7

    public struct AppFolder: Sendable, Equatable {
        public let bundleID: String
        /// The Sparkle folder of the app.
        public let url: URL
        public let staleItems: [URL]
        public let staleBytes: Int64
    }

    public static func cachesRoot(home: URL) -> URL { home.appendingPathComponent("Library/Caches", isDirectory: true) }

    /// A bundle ID is a plain name. It cannot hold a slash, so it cannot leave the Caches folder.
    static func isBundleID(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil && !text.contains("..")
    }

    /// True only for `Library/Caches/<bundle id>/org.sparkle-project.Sparkle` in the home folder.
    public static func isSparkleFolder(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let prefix = cachesRoot(home: home).standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        return parts.count == 2 && isBundleID(parts[0]) && parts[1] == folderName
    }

    /// True when no part of the path is a link. A link in `Caches/<bundle id>` could lead to a project folder,
    /// and then "old update files" would be files of the user.
    static func isPlainPath(_ url: URL) -> Bool {
        url.standardizedFileURL.path == url.resolvingSymlinksInPath().path
    }

    /// The children of the cleaned folders that are older than `minAgeDays`. A link is never included.
    public static func staleItems(in sparkle: URL, now: Date, minAgeDays: Int = minimumAgeDays) -> [URL] {
        let fm = FileManager.default
        let limit = TimeInterval(minAgeDays) * 86_400
        var out: [URL] = []
        for folder in cleanedFolders {
            let dir = sparkle.appendingPathComponent(folder, isDirectory: true)
            guard (try? fm.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType == .typeDirectory else { continue }
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let child = dir.appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: child.path),
                      attrs[.type] as? FileAttributeType != .typeSymbolicLink,
                      let modified = attrs[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) >= limit else { continue }
                out.append(child)
            }
        }
        return out
    }

    public static func staleBytes(in sparkle: URL, now: Date) -> Int64 {
        staleItems(in: sparkle, now: now).reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
    }

    /// Finds the apps that have old update files. An app with none is not listed.
    public static func list(home: URL, now: Date) -> [AppFolder] {
        let fm = FileManager.default
        let root = cachesRoot(home: home)
        return ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted().compactMap { name in
            guard isBundleID(name) else { return nil }
            let sparkle = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
            guard (try? fm.attributesOfItem(atPath: sparkle.path))?[.type] as? FileAttributeType == .typeDirectory,
                  isPlainPath(sparkle) else { return nil }
            let items = staleItems(in: sparkle, now: now)
            let bytes = items.reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
            return items.isEmpty ? nil : AppFolder(bundleID: name, url: sparkle, staleItems: items, staleBytes: bytes)
        }
    }

    /// The name of an installed app, for example "Arc". nil when LaunchServices does not know the bundle ID.
    public static func systemAppName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
