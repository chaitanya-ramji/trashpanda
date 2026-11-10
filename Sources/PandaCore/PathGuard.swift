import Foundation

public enum Refusal: Error, Equatable, CustomStringConvertible {
    case notAbsolute
    case symlink
    case outsideHome
    case tooShallow
    case criticalPath
    case protectedData(String)
    case kept

    public var description: String {
        switch self {
        case .notAbsolute: return "path is not absolute"
        case .symlink: return "path is a symbolic link"
        case .outsideHome: return "path is outside the home folder"
        case .tooShallow: return "path is too close to the home folder"
        case .criticalPath: return "path is a system path"
        case .protectedData(let name): return "path is protected (\(name))"
        case .kept: return "path is on the keep list"
        }
    }
}

/// Last line of defense. Every delete passes through this check.
public struct PathGuard: Sendable {
    public let home: String
    public let keep: [String]

    /// Personal data, secrets, and tool state. We never delete these, even inside a cache folder.
    static let protectedHomeTrees: [String] = [
        "Documents", "Desktop", "Pictures", "Movies", "Music", "Public",
        "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage",
        "Library/Mail", "Library/Messages", "Library/Safari", "Library/Preferences",
        "Library/Application Support", "Library/Group Containers", "Library/Containers",
        ".ssh", ".gnupg", ".aws", ".kube", ".docker", ".orbstack", ".config",
        // Chats, settings, and history of coding tools. No cleaner touches them. These are backstops against a future mistake.
        ".lmstudio/conversations", ".lmstudio/settings.json", ".claude/settings.json", ".claude/history.jsonl",
        ".codex/config.toml", ".codex/history.jsonl", ".codex/skills", ".codex/memories",
        // Ollama models are shared layers. Only `ollama rm` may remove a model, so no path in this folder is ever deleted by us.
        ".ollama",
        // Package manager stores that hold the only copy of some data.
        ".yarn/berry", ".local/share/jupyter", "Library/Jupyter",
        // Installed Dart tools. Deleting them breaks the commands that the user installed.
        ".pub-cache/bin", ".pub-cache/global_packages",
        // Installed Elixir archives (such as phx_new) and the Hex login.
        ".mix", ".hex/hex.config",
        // Interpreters and tools that uv installed (`uv python install`, `uv tool install`). Deleting them breaks commands.
        ".local/share/uv/python", ".local/share/uv/tools",
    ]

    /// Files that hold a login or a secret. Neither the file nor any folder that contains it may be deleted.
    /// The folder above a file is protected too, so a bulk delete of the parent cannot take the file.
    static let protectedFiles: [String] = [
        // Hugging Face login. The documented place is $HF_HOME/token.
        ".cache/huggingface/token", ".cache/huggingface/stored_tokens",
        // The login of Codex and of Claude Code.
        ".codex/auth.json", ".claude/.credentials.json",
    ]

    /// Folders in `~/Library/Caches` that we never delete. Lower case, because the file system ignores the case.
    static let protectedCacheFolders: Set<String> = ["cloudkit", "familycircle", "geoservices"]

    static let criticalExact: Set<String> = [
        "/", "/Applications", "/Library", "/Volumes", "/Network", "/cores", "/etc", "/home", "/net",
        "/tmp", "/var", "/private", "/private/tmp", "/private/var", "/private/var/tmp",
        "/private/var/folders", "/Users", "/Users/Shared", "/opt", "/opt/homebrew",
    ]

    static let criticalTrees: [String] = [
        "/bin", "/dev", "/sbin", "/usr", "/System", "/private/etc", "/private/var/db",
        "/private/var/root", "/private/var/audit", "/Library/Apple", "/Library/Extensions",
        "/Library/Keychains", "/Applications/Finder.app", "/Applications/Safari.app",
    ]

    public init(home: URL, keep: [String] = []) {
        self.home = home.resolvingSymlinksInPath().path
        self.keep = keep.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    /// Returns nil when the path may be deleted. Returns the reason when it may not.
    /// `allowingSystemCache` is for one thing only: the owner chose to empty ONE folder in `~/Library/Caches` that is iCloud data or belongs
    /// to macOS (the cache explorer). It names that folder, and it lifts the rule for that folder only, not for the other protected ones.
    /// `Library/Caches` itself, and every other rule, stay.
    public func check(_ url: URL, allowingSystemCache: String? = nil) -> Refusal? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), !path.contains("\0") else { return .notAbsolute }

        if let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            return .symlink
        }

        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(home + "/") else { return .outsideHome }

        if Self.criticalExact.contains(resolved) { return .criticalPath }
        for tree in Self.criticalTrees where resolved == tree || resolved.hasPrefix(tree + "/") {
            return .criticalPath
        }

        let relative = String(resolved.dropFirst(home.count + 1))
        if relative.split(separator: "/").count < 2 { return .tooShallow }

        // `Library/Caches` itself, and the folders in it that are not ours to empty. They hold iCloud data, or they belong to macOS.
        // The cache explorer (#20) offers them as review items with the strongest dialog, and only through `removeCacheFolderContents`, which names the folder.
        if relative == "Library/Caches" { return .protectedData("Library/Caches") }
        let cachePieces = relative.split(separator: "/").map { $0.lowercased() }
        if cachePieces.count >= 3, cachePieces[2] != allowingSystemCache?.lowercased(), cachePieces[0] == "library", cachePieces[1] == "caches",
           Self.protectedCacheFolders.contains(cachePieces[2]) || cachePieces[2].hasPrefix("com.apple.") {
            return .protectedData("Library/Caches/\(cachePieces[2])")
        }

        for tree in Self.protectedHomeTrees where relative == tree || relative.hasPrefix(tree + "/") {
            // The one exception: a cache folder of a browser, in the exact shape <root>/<profile>/<cache name>.
            // Cookies, logins, history, and every other folder of the profile stay protected.
            // Service Worker storage is the second one. It is only offered as a review item.
            if BrowserCaches.isCleanableShape(relative: relative) || AgentCaches.isCleanableShape(relative: relative) { break }
            return .protectedData(tree)
        }

        // The auto memory of Claude Code: `.claude/projects/<project>/memory` and everything in it.
        let pieces = relative.split(separator: "/")
        if pieces.count >= 4, pieces[0] == ".claude", pieces[1] == "projects", pieces[3] == "memory" { return .protectedData(".claude/projects/*/memory") }
        // The folders that hold those memory folders: deleting one of them would delete the memory with it.
        if pieces.count == 2 || pieces.count == 3, pieces[0] == ".claude", pieces[1] == "projects" { return .protectedData(".claude/projects") }

        for file in Self.protectedFiles where relative == file || relative.hasPrefix(file + "/") || file.hasPrefix(relative + "/") {
            return .protectedData(file)
        }

        for entry in keep where resolved == entry || resolved.hasPrefix(entry + "/") || entry.hasPrefix(resolved + "/") {
            return .kept
        }
        return nil
    }
}
