import Foundation

/// The runtime cache of the Codex desktop app: `~/.cache/codex-runtimes`.
/// The app downloads a bundle of Python, Node, and office tools there (about 1.7 GB) for its document skills.
/// An install that does not finish can leave a `codex-runtime-install-XXXXXX` folder behind. On one Mac that was 1.9 GB.
///
/// Evidence: community reports (Simon Willison on the runtime, and openai/codex #28093 and #28673 on staging folders).
/// There is no OpenAI cleanup document. The staging folder is inferred to be a leftover, so it must be at least a day old.
public enum CodexRuntimes {
    public static let root = ".cache/codex-runtimes"
    public static let primaryName = "codex-primary-runtime"
    static let stagingPrefix = "codex-runtime-install-"
    /// An install that is younger than this can still be running.
    public static let minimumAgeDays = 1

    public enum Kind: Equatable, Sendable { case staging, primary }

    public static func rootURL(home: URL) -> URL { home.appendingPathComponent(root, isDirectory: true) }

    /// The name of a staging folder: the prefix and six letters or digits.
    static func isStagingName(_ name: String) -> Bool {
        name.range(of: "^\(stagingPrefix)[A-Za-z0-9]{6}\\z", options: .regularExpression) != nil
    }

    /// What a path is, or nil. It must be `~/.cache/codex-runtimes/<name>` with no link in any part.
    public static func kind(of url: URL, home: URL) -> Kind? {
        let path = url.standardizedFileURL.path
        let prefix = rootURL(home: home).standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        guard !name.contains("/"), UpdateDownloads.isPlainPath(url),
              (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory else { return nil }
        if name == primaryName { return .primary }
        return isStagingName(name) ? .staging : nil
    }

    /// Days since the folder changed, or nil when it cannot be read.
    public static func ageDays(of url: URL, now: Date) -> Int? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return max(0, Int(now.timeIntervalSince(modified) / 86_400))
    }

    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let kind: Kind
        public let ageDays: Int
    }

    /// The folders that we offer. A staging folder younger than a day is left out. A link is left out.
    public static func list(home: URL, now: Date) -> [Entry] {
        let dir = rootURL(home: home)
        guard UpdateDownloads.isPlainPath(dir) else { return [] }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        return names.compactMap { name in
            let url = dir.appendingPathComponent(name, isDirectory: true)
            guard let kind = kind(of: url, home: home), let age = ageDays(of: url, now: now) else { return nil }
            if kind == .staging, age < minimumAgeDays { return nil }
            return Entry(url: url, kind: kind, ageDays: age)
        }
    }

    /// True when a running program starts from inside the folder.
    public static func isInUse(_ url: URL, programs: [String]) -> Bool {
        let folder = url.resolvingSymlinksInPath().path + "/"
        return programs.contains { $0.hasPrefix(folder) }
    }
}
