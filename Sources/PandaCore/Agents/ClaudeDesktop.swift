import Foundation

/// Claude Desktop keeps runtimes and, for Cowork, a virtual machine. Both grow over time.
///
/// - `Claude/claude-code/<version>` and `Claude/claude-code-vm/<version>`: one runtime for each version.
///   Desktop does not remove the old ones (community report: anthropics/claude-code #62690).
/// - `Claude/vm_bundles/claudevm.bundle` and `warm`: the Cowork VM. Reports say 9 to 25 GB, and that the app downloads
///   about 10 GB again later, even when Cowork is not used (anthropics/claude-code #22543 and #61863).
///   Anthropic has not said that it is safe to remove it. The app has Settings, Storage for tasks and sessions.
///
/// Both are review items. The cleaner keeps the newest version of each family, and Claude Desktop must be closed.
public enum ClaudeDesktop {
    public static let bundleID = "com.anthropic.claudefordesktop"
    public static let changelogURL = URL(string: "https://claude.com/docs/cowork/claude-desktop-changelog")!

    public static func rootURL(home: URL) -> URL { home.appendingPathComponent(AgentCaches.claudeRoot, isDirectory: true) }

    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let family: String
        public let bytes: Int64
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// The version folders of one family: plain folders with a version name. A link is left out.
    static func versionFolders(_ family: String, home: URL) -> [URL] {
        let dir = rootURL(home: home).appendingPathComponent(family, isDirectory: true)
        guard UpdateDownloads.isPlainPath(dir), isDirectory(dir) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name in
            let url = dir.appendingPathComponent(name, isDirectory: true)
            return ClaudeVersions.isVersionName(name) && isDirectory(url) && UpdateDownloads.isPlainPath(url) ? url : nil
        }
    }

    /// The version that the app pins in `<family>/.sdk-version`, if the file names a version. It stays.
    static func pinnedVersion(_ family: String, home: URL) -> String? {
        let file = rootURL(home: home).appendingPathComponent(family, isDirectory: true).appendingPathComponent(".sdk-version")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeVersions.isVersionName(name) ? name : nil
    }

    /// The name that identifies one runtime in an action: `claude-code/2.1.309`.
    public static func runtimeName(_ entry: Entry) -> String { "\(entry.family)/\(entry.url.lastPathComponent)" }

    /// Every version except the newest of each family, and except the version that the app pins.
    public static func oldRuntimes(home: URL) -> [Entry] {
        AgentCaches.claudeRuntimeFamilies.flatMap { family -> [Entry] in
            let folders = versionFolders(family, home: home)
            guard let newest = ClaudeVersions.newest(of: folders.map(\.lastPathComponent)) else { return [] }
            let pinned = pinnedVersion(family, home: home)
            return folders.filter { $0.lastPathComponent != newest && $0.lastPathComponent != pinned }
                .sorted { ClaudeVersions.isNewer($0.lastPathComponent, than: $1.lastPathComponent) }
                .map { Entry(url: $0, family: family, bytes: Sizer.size(of: $0)) }
        }
    }

    /// The Cowork VM folders that exist now. A link is left out.
    public static func vmBundles(home: URL) -> [Entry] {
        let dir = rootURL(home: home).appendingPathComponent(AgentCaches.claudeVMRoot, isDirectory: true)
        guard UpdateDownloads.isPlainPath(dir), isDirectory(dir) else { return [] }
        return AgentCaches.claudeVMFolders.sorted().compactMap { name in
            let url = dir.appendingPathComponent(name, isDirectory: true)
            guard isDirectory(url), UpdateDownloads.isPlainPath(url) else { return nil }
            return Entry(url: url, family: AgentCaches.claudeVMRoot, bytes: Sizer.size(of: url))
        }
    }
}
