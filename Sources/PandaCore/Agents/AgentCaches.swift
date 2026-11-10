import Foundation

/// The narrow exceptions that the path guard makes inside `Library/Application Support` for AI agent apps.
/// The guard protects Application Support as a whole: it holds logins, chat stores, settings, and databases.
/// A path passes only when it has exactly one of the shapes below. Anything else under these roots is refused.
///
/// A shape is a pure function of the path text. It never reads the disk. The parts `.`, `..`, and empty are refused.
public enum AgentCaches {
    /// `Library/Application Support/Claude`, the folder of Claude Desktop.
    static let claudeRoot = "Library/Application Support/Claude"
    /// Folders in the Claude folder that hold one runtime for each version.
    static let claudeRuntimeFamilies = ["claude-code", "claude-code-vm"]
    /// The Cowork VM folder, and the two folders in it that we may remove.
    static let claudeVMRoot = "vm_bundles"
    static let claudeVMFolders: Set<String> = ["claudevm.bundle", "warm"]

    static func parts(_ relative: String) -> [String]? {
        let p = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return p.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) ? nil : p
    }

    /// True when `relative` (a path below the home folder) is a folder that an AI agent cleaner may delete.
    public static func isCleanableShape(relative: String) -> Bool {
        guard let p = parts(relative) else { return false }
        let root = claudeRoot.split(separator: "/").map(String.init)
        guard p.count > root.count, Array(p.prefix(root.count)) == root else { return false }
        let rest = Array(p.dropFirst(root.count))
        // Claude/claude-code/<version> and Claude/claude-code-vm/<version>
        if rest.count == 2, claudeRuntimeFamilies.contains(rest[0]), ClaudeVersions.isVersionName(rest[1]) { return true }
        // Claude/vm_bundles/claudevm.bundle and Claude/vm_bundles/warm
        if rest.count == 2, rest[0] == claudeVMRoot, claudeVMFolders.contains(rest[1]) { return true }
        return false
    }
}
