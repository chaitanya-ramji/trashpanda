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

    /// A version name such as `2.1.321` or `2.2.0-beta.1`: three numbers, and an optional pre-release part after a dash.
    /// A fourth number, a dot suffix (`2.1.10.tmp`), or a number with more than nine digits is not a version name,
    /// so that a leftover file can never tie with a real version.
    public static func isVersionName(_ name: String) -> Bool {
        name.range(of: #"^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}(-[A-Za-z0-9]+(\.[A-Za-z0-9]+)*)?$"#, options: .regularExpression) != nil
    }

    /// Orders two version names like semantic versions. `2.1.9` is older than `2.1.10`. A pre-release is older than
    /// its plain version. Pre-release parts are compared one by one: numbers by value, and a number before a word.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func split(_ s: String) -> ([Int], [String]) {
            let halves = s.split(separator: "-", maxSplits: 1).map(String.init)
            let nums = halves[0].split(separator: ".").map { Int($0) ?? 0 }
            let pre = halves.count > 1 ? halves[1].split(separator: ".").map(String.init) : []
            return (nums, pre)
        }
        let (x, xp) = split(a), (y, yp) = split(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        if xp.isEmpty || yp.isEmpty { return xp.isEmpty && !yp.isEmpty }
        for i in 0..<min(xp.count, yp.count) where xp[i] != yp[i] {
            switch (Int(xp[i]), Int(yp[i])) {
            case let (m?, n?): return m > n
            case (_?, nil): return false
            case (nil, _?): return true
            default: return xp[i] > yp[i]
            }
        }
        return xp.count > yp.count
    }

    /// The newest of some version names. When two names mean the same version, the larger text wins, so the answer never depends on the order.
    public static func newest(of names: [String]) -> String? {
        names.max { a, b in isNewer(b, than: a) || (!isNewer(a, than: b) && a < b) }
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
        let link = home.appendingPathComponent(linkPath)
        // Resolve every link on the way: a folder above the link may be a link, and a link may point to another link.
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else { return nil }
        let resolved = link.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent().path == directoryURL(home: home).resolvingSymlinksInPath().path else { return nil }
        return resolved.lastPathComponent
    }

    /// The versions that we remove, and the names that stay. `running` holds the version files that are open now.
    public static func old(home: URL, running: [String]) -> (old: [Entry], kept: [String]) {
        let all = entries(home: home)
        guard let newest = newest(of: all.map(\.name)) else { return ([], []) }
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
        return interpret(status: r.status, stdout: r.stdout, stderr: r.stderr, timedOut: r.timedOut)
    }

    /// Reads the answer of lsof. Exit status 1 with no message means that none of the files is open.
    /// Exit status 1 with a message is an error, and then we do not know. Tests call this with made-up answers.
    static func interpret(status: Int32, stdout: String, stderr: String, timedOut: Bool) -> [String]? {
        guard !timedOut, status == 0 || (status == 1 && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return nil }
        return Array(Set(stdout.split(separator: "\n").compactMap { $0.hasPrefix("n/") ? String($0.dropFirst()) : nil }))
    }
}
