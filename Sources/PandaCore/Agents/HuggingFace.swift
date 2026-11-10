import Foundation

/// The Hugging Face hub cache: `~/.cache/huggingface/hub/<type>--<org>--<name>`.
/// Each repository has its own folder with `blobs`, `refs`, and `snapshots` (documented layout, huggingface_hub "manage-cache").
/// MLX and recent llama.cpp downloads use the same cache. The login (`token`, `stored_tokens`) is in the parent folder and is
/// protected by the path guard (#57).
///
/// One review item for each repository. We remove with `hf cache rm <type>/<org>/<name> --yes` when `hf` is installed.
/// Without `hf`, we delete that one repository folder, which is what the command does. The folder holds its own blobs.
/// Left out: `hf cache prune`, because it cannot be previewed, and `huggingface-cli delete-cache`, because it is interactive.
/// Neither `hf` nor a Hugging Face cache is on the author's Mac, so this is not checked on a real install.
public enum HuggingFace {
    public static let hubFolder = ".cache/huggingface/hub"
    /// A download that is not done has a `.incomplete` file in `blobs`. A repository with a fresh one is left alone.
    public static let incompleteGrace: TimeInterval = 86_400

    public enum Kind: String, Sendable, CaseIterable {
        case model, dataset, space
        var folderPrefix: String { rawValue + "s--" }
    }

    public struct Repo: Equatable, Sendable {
        public let kind: Kind
        /// `org/name`, or `name` for an old repository without an organization.
        public let name: String
        public let folder: URL
        public let bytes: Int64
        public let ageDays: Int?

        /// The identifier that `hf cache rm` takes: `model/org/name`.
        public var id: String { "\(kind.rawValue)/\(name)" }
    }

    public static func hubURL(home: URL) -> URL { home.appendingPathComponent(hubFolder, isDirectory: true) }

    private static let part = "[A-Za-z0-9][A-Za-z0-9._-]*"

    /// `model/org/name` or `model/name`. It cannot start with a dash, and it cannot hold `..`.
    public static func isRepoID(_ text: String) -> Bool {
        text.count <= 200 && !text.contains("..") && !text.contains("--")
            && text.range(of: "^(model|dataset|space)/\(part)(/\(part))?\\z", options: .regularExpression) != nil
    }

    /// The folder name of a repository: `models--org--name`. nil when the name has another shape.
    static func parseFolderName(_ folder: String) -> (Kind, String)? {
        for kind in Kind.allCases where folder.hasPrefix(kind.folderPrefix) {
            let rest = String(folder.dropFirst(kind.folderPrefix.count))
            let pieces = rest.components(separatedBy: "--")
            guard (1...2).contains(pieces.count), pieces.allSatisfy({ $0.range(of: "^\(part)\\z", options: .regularExpression) != nil }) else { return nil }
            let name = pieces.joined(separator: "/")
            return isRepoID("\(kind.rawValue)/\(name)") ? (kind, name) : nil
        }
        return nil
    }

    static func folderName(kind: Kind, name: String) -> String { kind.folderPrefix + name.replacingOccurrences(of: "/", with: "--") }

    private static func isPlainFolder(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory && UpdateDownloads.isPlainPath(url)
    }

    /// True when a download into this repository may still run.
    static func hasFreshIncomplete(_ folder: URL, now: Date) -> Bool {
        let blobs = folder.appendingPathComponent("blobs", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: blobs.path)) ?? []).contains { name in
            guard name.hasSuffix(".incomplete"),
                  let modified = (try? FileManager.default.attributesOfItem(atPath: blobs.appendingPathComponent(name).path))?[.modificationDate] as? Date
            else { return false }
            return now.timeIntervalSince(modified) < incompleteGrace
        }
    }

    /// The repositories in the cache now. A link, a folder with another shape, and a repository with a fresh download are left out.
    public static func repos(home: URL, now: Date) -> [Repo] {
        let hub = hubURL(home: home)
        guard isPlainFolder(hub) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: hub.path)) ?? []).sorted().compactMap { folder in
            guard let (kind, name) = parseFolderName(folder) else { return nil }
            let url = hub.appendingPathComponent(folder, isDirectory: true)
            let fm = FileManager.default
            guard isPlainFolder(url),
                  ["blobs", "snapshots", "refs"].contains(where: { fm.fileExists(atPath: url.appendingPathComponent($0).path) }),
                  !hasFreshIncomplete(url, now: now) else { return nil }
            let snapshots = url.appendingPathComponent("snapshots")
            let modified = ((try? fm.attributesOfItem(atPath: snapshots.path))?[.modificationDate] as? Date)
                ?? (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return Repo(kind: kind, name: name, folder: url, bytes: Sizer.size(of: url),
                        ageDays: modified.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) })
        }
    }

    public static func repo(id: String, home: URL, now: Date) -> Repo? {
        guard isRepoID(id) else { return nil }
        return repos(home: home, now: now).first { $0.id == id }
    }

    /// The only command that removes a repository through the tool.
    public static func removeArguments(_ id: String) -> [String]? { isRepoID(id) ? ["cache", "rm", id, "--yes"] : nil }
}
