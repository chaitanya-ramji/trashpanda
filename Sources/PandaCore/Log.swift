import Foundation
import os

/// A plain text log at ~/Library/Logs/TrashPanda/trashpanda.log, plus the system log.
/// Every scan, every command, and every delete is written here, so each result can be checked later.
public enum Log {
    public static var fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TrashPanda/trashpanda.log")

    private static let queue = DispatchQueue(label: "dev.trashpanda.log")
    private static let system = Logger(subsystem: "dev.trashpanda.app", category: "app")
    private static let maxBytes = 1_000_000

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func info(_ message: String) { write("INFO ", message) }
    public static func warn(_ message: String) { write("WARN ", message) }
    public static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        // The system log is read by other processes. The message can hold paths and command lines,
        // so only the level is public. The full text stays in the log file.
        system.log("\(level, privacy: .public) \(message, privacy: .private)")
        let line = "\(stamp.string(from: Date())) \(level) \(message)\n"
        queue.sync {
            let fm = FileManager.default
            let url = fileURL
            let folder = url.deletingLastPathComponent()
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            }
        }
    }

    // MARK: Privacy helpers

    /// Replaces the home folder with `~`.
    public static func redact(_ text: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return text.replacingOccurrences(of: base + "/", with: "~/")
            .replacingOccurrences(of: base, with: "~")
    }

    /// The last 200 lines of the log, for a person to read before sharing.
    /// Each path keeps its first two parts under the home folder. The rest becomes a count.
    public static func exportForReport() -> String {
        exportForReport(from: fileURL, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static func exportForReport(from url: URL, home: String, maxLines: Int = 200) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(maxLines)
        return lines.map { shorten(redact(String($0), home: home)) }.joined(separator: "\n")
    }

    private static let pathPattern = try! NSRegularExpression(pattern: #"(?:~|(?<![\w.~:/-]))/[^\s"'<>]*|~(?![\w/])"#)

    /// Keeps the first two parts of each path and counts the rest: `~/Library/Caches/(3 more)`.
    static func shorten(_ line: String) -> String {
        let ns = line as NSString
        var out = ""
        var last = 0
        for m in pathPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var token = ns.substring(with: m.range)
            var tail = ""
            while let c = token.last, ",;:.)]".contains(c) { tail = String(c) + tail; token.removeLast() }
            out += shortenPath(token) + tail
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    private static func shortenPath(_ path: String) -> String {
        let home = path.hasPrefix("~")
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let names = home ? Array(parts.dropFirst()) : parts
        guard names.count > 2 else { return path }
        let head = (home ? "~/" : "/") + names.prefix(2).joined(separator: "/")
        return head + "/(\(names.count - 2) more)"
    }
}
