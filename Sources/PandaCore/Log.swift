import Foundation
import os

/// A plain text log at ~/Library/Logs/TrashPanda/trashpanda.log, plus the system log.
/// Every scan, every command, and every delete is written here, so each result can be checked later.
public enum Log {
    /// The real app writes to `~/Library/Logs/TrashPanda/trashpanda.log`. When a test run loads this code (XCTest is present),
    /// the default is a file in the temp folder instead, so that no test can write or rotate the real log, however the test is
    /// started (for example `swift test --filter SomeTests`, where no test makes a `Sandbox`). The real app never loads XCTest,
    /// so its default does not change.
    public static var fileURL: URL = defaultFileURL()

    static func defaultFileURL(underTest: Bool = isRunningUnderXCTest) -> URL {
        if underTest {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("trashpanda-tests.log")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TrashPanda/trashpanda.log")
    }

    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

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

    // These are used only on `queue`.
    private static var handle: FileHandle?
    private static var openedURL: URL?
    private static var written = 0
    private static var syncScheduled = false

    private static func write(_ level: String, _ message: String) {
        // The system log is read by other processes. The message can hold paths and command lines,
        // so only the level is public. The full text stays in the log file.
        system.log("\(level, privacy: .public) \(message, privacy: .private)")
        let line = Data("\(stamp.string(from: Date())) \(level) \(message)\n".utf8)
        let url = fileURL
        queue.async {
            guard let handle = openHandle(for: url) else { return }
            try? handle.write(contentsOf: line)
            written += line.count
            scheduleSync()
        }
    }

    /// The one open file. It opens again when the file name changed, when the file is gone, or after a rotation.
    private static func openHandle(for url: URL) -> FileHandle? {
        let fm = FileManager.default
        if let handle, openedURL == url, fm.fileExists(atPath: url.path), written <= maxBytes { return handle }
        closeHandle()
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
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        written = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
        openedURL = url
        return opened
    }

    private static func closeHandle() {
        try? handle?.close()
        handle = nil
        openedURL = nil
        written = 0
    }

    /// Writes to the disk a moment after the last line, so that a clean that just ended is saved.
    private static func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        queue.asyncAfter(deadline: .now() + 1) {
            syncScheduled = false
            try? handle?.synchronize()
        }
    }

    /// Waits until every line is written, and saves the file to the disk. Call it before the app quits.
    public static func flush() {
        queue.sync { try? handle?.synchronize() }
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
        flush()
        return exportForReport(from: fileURL, home: FileManager.default.homeDirectoryForCurrentUser.path)
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
