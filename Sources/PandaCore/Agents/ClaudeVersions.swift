import Foundation

/// The versions of the Claude Code command line tool that the native installer keeps:
/// `~/.local/share/claude/versions/<version>`. Each version is one program file (about 300 MB).
/// The installer never removes the old ones (community: anthropics/claude-code #48311 and #43583).
/// `~/.local/bin/claude` is a link to the version in use. `claude update` downloads a version again.
///
/// We keep: the newest version, the version that the link points to, and every version that runs now.
/// A running version is found through the file that it executes: `lsof` tells which version files are open.
/// `ps` shows only the name "claude", and `lsof` names the process by its version number, so a name filter fails.
public enum ClaudeVersions {
    public static let directory = ".local/share/claude/versions"
    public static let linkPath = ".local/bin/claude"

    public static func directoryURL(home: URL) -> URL { home.appendingPathComponent(directory, isDirectory: true) }

    /// A version name such as `2.1.321` or `2.2.0-beta.1`. It cannot hold a slash or start with a dot.
    public static func isVersionName(_ name: String) -> Bool {
        name.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    /// Compares by number, part by part. `2.1.9` is older than `2.1.10`. A name with a suffix is older than the plain version.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> ([Int], Bool) {
            let main = s.split(separator: "-", maxSplits: 1).first.map(String.init) ?? s
            let nums = main.split(separator: ".").map { Int($0) ?? 0 }
            return (nums, s.contains("-"))
        }
        let (x, xs) = parts(a), (y, ys) = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return !xs && ys
    }

    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let name: String
        public let bytes: Int64
    }

    /// Every version file in the folder: plain files with a version name. A link or a folder is left out.
    public static func entries(home: URL) -> [Entry] {
        let dir = directoryURL(home: home)
        let fm = FileManager.default
        guard UpdateDownloads.isPlainPath(dir) else { return [] }
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name in
            guard isVersionName(name) else { return nil }
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
            return Entry(url: url, name: name, bytes: Int64((attrs[.size] as? NSNumber)?.int64Value ?? 0))
        }
    }

    /// The version that `~/.local/bin/claude` points to, or nil.
    public static func linkedVersion(home: URL) -> String? {
        let link = home.appendingPathComponent(linkPath).path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return nil }
        let absolute = target.hasPrefix("/") ? target : URL(fileURLWithPath: link).deletingLastPathComponent().appendingPathComponent(target).path
        let resolved = URL(fileURLWithPath: absolute).standardizedFileURL
        guard resolved.deletingLastPathComponent().path == directoryURL(home: home).standardizedFileURL.path else { return nil }
        return resolved.lastPathComponent
    }

    /// The versions that we remove, and the names that stay. `running` holds the version files that are open now.
    public static func old(home: URL, running: [String]) -> (old: [Entry], kept: [String]) {
        let all = entries(home: home)
        guard let newest = all.map(\.name).max(by: { isNewer($1, than: $0) }) else { return ([], []) }
        let dir = directoryURL(home: home).standardizedFileURL.path + "/"
        var keep: Set<String> = [newest]
        if let linked = linkedVersion(home: home) { keep.insert(linked) }
        for path in running {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            for p in [path, resolved] where p.hasPrefix(dir) {
                keep.insert(String(p.dropFirst(dir.count)).split(separator: "/").first.map(String.init) ?? "")
            }
        }
        let stale = all.filter { !keep.contains($0.name) }.sorted { isNewer($0.name, than: $1.name) }
        return (stale, all.map(\.name).filter(keep.contains).sorted { isNewer($0, than: $1) })
    }

    /// Which of these files are open now (a running program executes its file, so it keeps it open). nil when `lsof` could not tell.
    /// We ask by file name. The process does not need to be called "claude": a running version names itself by its number.
    public static func openBinaryPaths(among files: [String]) -> [String]? {
        guard !files.isEmpty else { return [] }
        let r = Shell.run("/usr/sbin/lsof", ["-Fn", "--"] + files, timeout: 20, quiet: true)
        // lsof exits with 1 when none of the files is open. Any other failure, or a timeout, means that we do not know.
        guard !r.timedOut, r.status == 0 || r.status == 1 else { return nil }
        return Array(Set(r.stdout.split(separator: "\n").compactMap { $0.hasPrefix("n/") ? String($0.dropFirst()) : nil }))
    }
}
