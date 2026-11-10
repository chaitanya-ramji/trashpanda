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
        // Package manager stores that hold the only copy of some data.
        ".yarn/berry", ".local/share/jupyter", "Library/Jupyter",
        // Installed Dart tools. Deleting them breaks the commands that the user installed.
        ".pub-cache/bin", ".pub-cache/global_packages",
        // Installed Elixir archives (such as phx_new) and the Hex login.
        ".mix", ".hex/hex.config",
    ]

    /// Files that hold a login or a secret. Neither the file nor any folder that contains it may be deleted.
    /// The folder above a file is protected too, so a bulk delete of the parent cannot take the file.
    static let protectedFiles: [String] = [
        // Hugging Face login. The documented place is $HF_HOME/token.
        ".cache/huggingface/token", ".cache/huggingface/stored_tokens",
    ]

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
    public func check(_ url: URL) -> Refusal? {
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

        for tree in Self.protectedHomeTrees where relative == tree || relative.hasPrefix(tree + "/") {
            // The one exception: a cache folder of a browser, in the exact shape <root>/<profile>/<cache name>.
            // Cookies, logins, history, and every other folder of the profile stay protected.
            // Service Worker storage is the second one. It is only offered as a review item.
            if BrowserCaches.isCleanableShape(relative: relative) { break }
            return .protectedData(tree)
        }

        for file in Self.protectedFiles where relative == file || relative.hasPrefix(file + "/") || file.hasPrefix(relative + "/") {
            return .protectedData(file)
        }

        for entry in keep where resolved == entry || resolved.hasPrefix(entry + "/") || entry.hasPrefix(resolved + "/") {
            return .kept
        }
        return nil
    }
}
