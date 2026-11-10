import Foundation

/// Old installer files in `~/Downloads`. An installer stays there after the app is installed.
///
/// Only two file types count: `.dmg` and `.pkg`. Only files that lie directly in the Downloads folder count.
/// A file must be at least 30 days old. The user chooses each file.
public enum Installers {
    /// The only file types that we list. Compared without case.
    public static let extensions: Set<String> = ["dmg", "pkg"]
    public static let minimumAgeDays = 30

    public static func folder(home: URL) -> URL { home.appendingPathComponent("Downloads", isDirectory: true) }

    /// True when the name ends in `.dmg` or `.pkg`, in any case. A hidden file never counts.
    public static func isInstallerName(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        return extensions.contains((name as NSString).pathExtension.lowercased())
    }

    public struct Installer: Sendable, Equatable {
        public let url: URL
        public let bytes: Int64
        public let ageDays: Int
    }

    /// True only for `Downloads/<name>` with an installer name, and no link in any part of the path.
    public static func isInstallerPath(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let prefix = folder(home: home).standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let name = String(path.dropFirst(prefix.count))
        return !name.contains("/") && isInstallerName(name) && UpdateDownloads.isPlainPath(url)
    }

    /// One installer, read now. nil when it is not a plain file of the right kind, or is younger than the limit.
    public static func read(_ url: URL, home: URL, now: Date, minAgeDays: Int = minimumAgeDays) -> Installer? {
        guard isInstallerPath(url, home: home),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        let age = now.timeIntervalSince(modified)
        guard age >= TimeInterval(minAgeDays) * 86_400 else { return nil }
        return Installer(url: url, bytes: Int64((attrs[.size] as? NSNumber)?.int64Value ?? 0), ageDays: Int(age / 86_400))
    }

    /// The old installers in the Downloads folder, the largest first. We do not look inside folders.
    public static func list(home: URL, now: Date) -> [Installer] {
        let dir = folder(home: home)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            isInstallerName(name) ? read(dir.appendingPathComponent(name), home: home, now: now) : nil
        }.sorted { ($0.bytes, $1.url.path) > ($1.bytes, $0.url.path) }
    }

    /// The disk images that are mounted now. We never remove an image that is in use.
    public static func mountedImagePaths() -> [String] {
        guard let hdiutil = Shell.resolve("hdiutil") else { return [] }
        let r = Shell.run(hdiutil, ["info", "-plist"], timeout: 15, quiet: true)
        guard r.status == 0, let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { $0["image-path"] as? String }
    }
}
