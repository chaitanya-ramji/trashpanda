import Foundation

/// Old files in `~/Library/Logs`. Logs and crash reports can grow large, and nobody reads the old ones.
///
/// We list plain files that are at least 30 days old. We never touch a folder, a link, or a newer file.
/// The log of Trash Panda itself is never touched. The user chooses each of the two groups.
public enum OldLogs {
    public static let minimumAgeDays = 30

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// Everything in `~/Library/Logs` except the crash report folders.
        case logs
        /// `DiagnosticReports` and `CrashReporter` (the crash logs of connected devices).
        case crashReports

        public var findingID: String { "logs.\(rawValue)" }
        public var title: String { self == .logs ? "Old logs" : "Old crash reports" }
    }

    /// The top-level folders of `Logs` that hold crash reports.
    static let crashFolders: Set<String> = ["diagnosticreports", "crashreporter", "diagnosticreportsfornewhardware"]
    /// The folder of Trash Panda in `Logs`. Never touched.
    static let ownFolder = "trashpanda"

    public static func root(home: URL) -> URL { home.appendingPathComponent("Library/Logs", isDirectory: true) }

    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let bytes: Int64
    }

    /// Which group a path belongs to, or nil when it is not a candidate.
    /// The path must be `Library/Logs/<top>/...` or `Library/Logs/<file>`. The Trash Panda folder is never a candidate.
    static func kind(of url: URL, home: URL) -> Kind? {
        let prefix = root(home: home).standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map { String($0).lowercased() }
        guard let top = parts.first, !parts.contains(where: { $0 == ".." }) else { return nil }
        if top == ownFolder { return nil }
        if path == Log.fileURL.standardizedFileURL.path { return nil }
        return crashFolders.contains(top) ? .crashReports : .logs
    }

    /// The old plain files of one group, read now. Links and folders are never included.
    public static func entries(_ kind: Kind, home: URL, now: Date, minAgeDays: Int = minimumAgeDays) -> [Entry] {
        let base = root(home: home)
        guard UpdateDownloads.isPlainPath(base),
              (try? FileManager.default.attributesOfItem(atPath: base.path))?[.type] as? FileAttributeType == .typeDirectory,
              let walker = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .totalFileAllocatedSizeKey],
                options: [], errorHandler: { _, _ in true }) else { return [] }
        let limit = TimeInterval(minAgeDays) * 86_400
        var out: [Entry] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                                                           .totalFileAllocatedSizeKey]),
                  v.isSymbolicLink != true, v.isRegularFile == true,
                  let modified = v.contentModificationDate, now.timeIntervalSince(modified) >= limit,
                  Self.kind(of: url, home: home) == kind else { continue }
            out.append(Entry(url: url, bytes: Int64(v.totalFileAllocatedSize ?? 0)))
        }
        return out
    }

    public static func bytes(_ kind: Kind, home: URL, now: Date) -> Int64 {
        entries(kind, home: home, now: now).reduce(0) { $0 + $1.bytes }
    }
}
