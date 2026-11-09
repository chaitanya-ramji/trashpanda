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
        system.log("\(level, privacy: .public) \(message, privacy: .public)")
        let line = "\(stamp.string(from: Date())) \(level) \(message)\n"
        queue.sync {
            let fm = FileManager.default
            let url = fileURL
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            }
        }
    }
}
