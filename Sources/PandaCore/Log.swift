import Foundation
import os

/// A plain text log at ~/Library/Logs/TrashPanda/trashpanda.log, plus the system log.
/// Every scan, every command, and every delete is written here, so each result can be checked later.
public enum Log {
    /// The real app writes to `~/Library/Logs/TrashPanda/trashpanda.log`. When a test run loads this code (a `.xctest` bundle is
    /// loaded), the default is a file in a private folder of the temp folder instead, so that no test can write or rotate the real
    /// log, however the test is started (for example `swift test --filter SomeTests`, where no test makes a `Sandbox`).
    /// Only the loaded bundle decides this. An environment variable does not, because the real app could be started with one.
    /// The real app never loads a `.xctest` bundle, so its default does not change.
    public static var fileURL: URL = defaultFileURL()

    static func defaultFileURL(underTest: Bool = isRunningUnderXCTest) -> URL {
        chooseDefault(underTest: underTest, home: realHome(), temp: NSTemporaryDirectory())
    }

    /// True for a path that starts with `/`, has no zero byte, and is not empty. A path like `~`, `.`, `sub`, or `` is not plain.
    /// This check reads the text only. It never expands `~` and it never standardizes the path.
    static func isPlainAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0")
    }

    /// The home folder for the log file. `CFFIXED_USER_HOME` and `HOME` are read as text first. When one of them is set but is not a
    /// plain absolute path (for example `~`), the system calls that expand it are NOT used: `FileManager.homeDirectoryForCurrentUser`
    /// asks the home folder, expands the `~` in the answer, and asks again, so it calls itself until the stack is full (SIGSEGV).
    /// The home folder from the user database is used instead. `normal` is the usual way, and a test can replace it.
    static func realHome(cffixed: String? = environmentValue("CFFIXED_USER_HOME"), home: String? = environmentValue("HOME"),
                         passwd: () -> String? = passwdHome,
                         normal: () -> URL = { FileManager.default.homeDirectoryForCurrentUser }) -> URL {
        let plain = [cffixed, home].allSatisfy { $0 == nil || isPlainAbsolute($0 ?? "") }
        if plain { return normal() }
        // `fileURLWithPath` with a plain absolute path does not expand anything.
        let fallback = passwd().flatMap { isPlainAbsolute($0) ? $0 : nil } ?? "/var/empty"
        return URL(fileURLWithPath: fallback, isDirectory: true)
    }

    private static func environmentValue(_ name: String) -> String? { getenv(name).map { String(cString: $0) } }

    private static func passwdHome() -> String? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }

    /// The pure rule, with the inputs given. A test can call it with `underTest: false` and see the path of the real app.
    /// The private folder `trashpanda-tests` (mode 0700, made by `openHandle`) holds the temp log, so the shared temp folder is
    /// never changed.
    static func chooseDefault(underTest: Bool, home: URL, temp: String) -> URL {
        if underTest {
            return URL(fileURLWithPath: temp, isDirectory: true)
                .appendingPathComponent("trashpanda-tests", isDirectory: true).appendingPathComponent("trashpanda-tests.log")
        }
        return home.appendingPathComponent("Library/Logs/TrashPanda/trashpanda.log")
    }

    static var isRunningUnderXCTest: Bool {
        Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
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
        guard prepareFolder(folder) else { return nil }
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

    /// Makes the log folder, and never makes the home folder. The real log is `<home>/Library/Logs/TrashPanda/trashpanda.log`. For that
    /// path the log owns only the last 3 parts (`Library/Logs/TrashPanda`). The folder before them (the home) must already exist and
    /// be a folder. If it does not, nothing is made and the log writes nothing. A missing home must stay missing, so that a run with
    /// a wrong home never makes a new home with a log in it. Any other path is for a test and is made as a whole.
    static func prepareFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard folder.path.hasSuffix("/Library/Logs/TrashPanda") else {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return fm.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
        }
        var current = folder
        for _ in 0..<3 { current.deleteLastPathComponent() }
        guard fm.fileExists(atPath: current.path, isDirectory: &isFolder), isFolder.boolValue else { return false }
        for name in folder.pathComponents.suffix(3) {
            current.appendPathComponent(name, isDirectory: true)
            if !fm.fileExists(atPath: current.path) {
                // One level at a time, never with intermediate folders.
                try? fm.createDirectory(at: current, withIntermediateDirectories: false,
                                        attributes: current.path == folder.path ? [.posixPermissions: 0o700] : nil)
            }
        }
        return fm.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
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
        return exportForReport(from: fileURL, home: realHome().path)
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
