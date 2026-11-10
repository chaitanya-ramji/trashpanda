import Foundation

/// Old session transcripts of coding agents. A transcript lets the tool resume a conversation. Deleting it ends that.
///
/// - Codex: `~/.codex/sessions/YYYY/MM/DD/*.jsonl` (and `.jsonl.zst`) and `~/.codex/archived_sessions`. Growth to tens of GB is reported
///   (openai/codex #41806, #34061). There is no OpenAI cleanup command. Codex may still list a deleted session in its own index.
/// - Claude Code: `~/.claude/projects/<project>/<uuid>.jsonl`. Claude Code deletes these itself after `cleanupPeriodDays` (30 by default),
///   so there is little to gain, and the dialog names the setting. Transcripts of Claude Desktop and Cowork are kept on purpose by the app,
///   and we cannot tell them apart, so this is a review item.
///
/// Never touched: `memory` folders of Claude Code (its auto memory), `history.jsonl`, the databases and the login of Codex,
/// the settings, and every file that is not a transcript. Only files whose last change is older than the stale limit.
public enum AgentSessions {
    public enum Kind: String, Sendable, CaseIterable {
        case codex, claude

        var roots: [String] { self == .codex ? [".codex/sessions", ".codex/archived_sessions"] : [".claude/projects"] }
        public var title: String { self == .codex ? "Codex · old sessions" : "Claude · old Code sessions" }
        public var findingID: String { "agent.sessions.\(rawValue)" }
    }

    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let bytes: Int64
        public let modified: Date
    }

    private static func isPart(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._-]{1,200}$"#, options: .regularExpression) != nil && s != "." && s != ".." && !s.contains("..")
    }

    private static func isUUID(_ s: String) -> Bool {
        s.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil
    }

    /// True when `relative` (the path inside a root) is a transcript of this kind.
    static func isTranscript(_ relative: [String], kind: Kind) -> Bool {
        guard relative.allSatisfy(isPart), let name = relative.last else { return false }
        switch kind {
        case .codex:
            // Folders of date (up to 3 deep), then `rollout-…jsonl` or `….jsonl.zst`. Nothing with another ending.
            return (1...4).contains(relative.count) && (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")) && !name.hasPrefix(".")
        case .claude:
            // `<project>/<uuid>.jsonl`, and nothing deeper. A `memory` folder is deeper, so it never matches.
            return relative.count == 2 && name.hasSuffix(".jsonl") && isUUID(String(name.dropLast(6)))
        }
    }

    /// The transcripts that were last changed at or before `cutoff`. A link, a folder, and any other file are left out.
    public static func entries(_ kind: Kind, home: URL, olderThan cutoff: Date) -> [Entry] {
        let fm = FileManager.default
        var out: [Entry] = []
        for rootRel in kind.roots {
            let root = home.appendingPathComponent(rootRel, isDirectory: true)
            guard (try? fm.attributesOfItem(atPath: root.path))?[.type] as? FileAttributeType == .typeDirectory,
                  UpdateDownloads.isPlainPath(root),
                  let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .totalFileAllocatedSizeKey],
                                             options: [], errorHandler: { _, _ in true }) else { continue }
            let base = root.standardizedFileURL.path + "/"
            for case let url as URL in walker {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base),
                      let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .totalFileAllocatedSizeKey]),
                      v.isSymbolicLink != true, v.isRegularFile == true, let modified = v.contentModificationDate, modified <= cutoff,
                      isTranscript(path.dropFirst(base.count).split(separator: "/").map(String.init), kind: kind) else { continue }
                out.append(Entry(url: url, bytes: Int64(v.totalFileAllocatedSize ?? 0), modified: modified))
            }
        }
        return out.sorted { $0.modified < $1.modified }
    }

    /// True when `url` is a transcript of this kind by its path alone.
    public static func isTranscriptPath(_ url: URL, kind: Kind, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        for rootRel in kind.roots {
            let base = home.appendingPathComponent(rootRel, isDirectory: true).standardizedFileURL.path + "/"
            if path.hasPrefix(base), isTranscript(path.dropFirst(base.count).split(separator: "/").map(String.init), kind: kind) { return true }
        }
        return false
    }

    /// The size of the chats of Gemini CLI (`~/.gemini/tmp/<hash>/chats`). We only tell about it. Gemini has its own commands.
    public static func geminiChatBytes(home: URL) -> Int64 {
        let tmp = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
        guard UpdateDownloads.isPlainPath(tmp) else { return 0 }
        return ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).sorted().reduce(Int64(0)) { sum, name in
            let chats = tmp.appendingPathComponent(name, isDirectory: true).appendingPathComponent("chats", isDirectory: true)
            return UpdateDownloads.isPlainPath(chats) ? sum + Sizer.size(of: chats) : sum
        }
    }
}
