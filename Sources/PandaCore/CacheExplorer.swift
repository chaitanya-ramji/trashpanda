import Foundation

/// A read-only list of the largest folders in `~/Library/Caches`.
/// Most of that folder has an owner that we do not know. On the author's Mac, 27 GB is `CloudKit`, which is iCloud data and not safe to delete.
/// The list shows what is there. It never deletes anything, and it has no action: an `unknown` folder is never removed.
public enum CacheLabel: String, Sendable, Equatable {
    /// Trash Panda already has an item for it, in its own group.
    case canClean = "can clean"
    /// Not safe to delete, or not ours to delete. The reason says why.
    case keep
    /// We do not know the owner or what it holds.
    case unknown
}

public enum CacheExplorer {
    public static let limit = 10
    /// A folder under this size is not worth a line.
    public static let minimumBytes: Int64 = 10_000_000

    /// Folders that must stay, with a short reason. Checked by exact name.
    static let keepReasons: [String: String] = [
        "CloudKit": "iCloud data. Deleting it can lose changes that are not synced yet.",
        "com.apple.bird": "The sync state of iCloud Drive.",
        "com.apple.iCloudDrive": "The sync state of iCloud Drive.",
        "com.apple.Safari": "Safari data. macOS protects it, and Trash Panda never cleans it.",
        "com.apple.photolibraryd": "The caches of your Photos library. They are slow to rebuild.",
        "com.apple.mail": "Mail data. Deleting it can lose messages that are not synced.",
        "FamilyCircle": "Family Sharing data from iCloud.",
    ]

    /// The reason to keep a folder, or nil. Any other Apple cache is managed by macOS.
    static func keepReason(_ name: String) -> String? {
        if let exact = keepReasons[name] { return exact }
        return name.hasPrefix("com.apple.") ? "An Apple system cache. macOS manages it." : nil
    }

    public struct Entry: Equatable, Sendable {
        public let folder: String
        public let displayName: String
        public let bytes: Int64
        public let label: CacheLabel
        public let reason: String
    }

    /// Folders of tools that Trash Panda cleans through the tool itself (`brew cleanup`, `go clean`), so no catalog path names them.
    static let selfCleaningTools = ["Library/Caches/Homebrew", "Library/Caches/go-build"]

    /// The first folder name below `Library/Caches` of every catalog path. These folders have an item of their own.
    static func cleanableNames(paths: [String]) -> Set<String> {
        var out: Set<String> = []
        for p in paths where p.hasPrefix("Library/Caches/") {
            if let first = p.dropFirst("Library/Caches/".count).split(separator: "/").first { out.insert(String(first)) }
        }
        return out
    }

    /// A readable name: the name of the app when the folder is a bundle ID of an installed app, and the folder name otherwise.
    static func displayName(_ folder: String, appName: (String) -> String?) -> String {
        if folder.contains("."), let name = appName(folder) { return name }
        return folder
    }

    public static func label(for folder: String, cleanable: Set<String>) -> (CacheLabel, String) {
        // An item that Trash Panda already has comes first. It has its own checks (an app that is open, the age, and so on).
        if cleanable.contains(folder) { return (.canClean, "Trash Panda has an item for it. Look in the group of its tool.") }
        if let why = keepReason(folder) { return (.keep, why) }
        return (.unknown, "We do not know what owns it, so we never remove it.")
    }

    /// The largest folders. A link, a file, and a folder under the minimum are left out. Nothing is read except the sizes.
    public static func entries(home: URL, cleanable: Set<String>, appName: (String) -> String?, limit: Int = limit) -> [Entry] {
        let root = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let fm = FileManager.default
        guard UpdateDownloads.isPlainPath(root) else { return [] }
        let sized: [(String, Int64)] = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted().compactMap { name in
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory, UpdateDownloads.isPlainPath(url) else { return nil }
            let bytes = Sizer.size(of: url)
            return bytes >= minimumBytes ? (name, bytes) : nil
        }
        return sized.sorted { ($0.1, $1.0) > ($1.1, $0.0) }.prefix(limit).map { folder, bytes in
            let (label, reason) = label(for: folder, cleanable: cleanable)
            return Entry(folder: folder, displayName: displayName(folder, appName: appName), bytes: bytes, label: label, reason: reason)
        }
    }
}
