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
        if isElectronShape(relative: relative) || EditorCaches.isShape(relative: relative) || LocalModels.isShape(relative: relative) || FixedFolders.isShape(relative: relative) { return true }
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

// MARK: Electron apps

/// An Electron app (a Chromium app) whose cache folders we clean. Chromium keeps its caches in folders with fixed names.
/// The names are documented Chromium behaviour. That these apps use them is read from folders on a real Mac.
public struct ElectronApp: Sendable, Equatable {
    public let id: String
    /// The product part of the title, for example "Claude". It must be in `AgentProduct.all`.
    public let product: String
    /// The title after the product, for example "app caches".
    public let label: String
    /// The folder in Application Support, relative to the home folder.
    public let supportRoot: String
    /// The cache folder names. They are allowed in the root and in `Partitions/<name>`.
    public let names: [String]
    /// Cache folders in `Library/Caches`: the folder, and the names in it.
    public let cachesRoot: String?
    public let cachesNames: [String]
    public let owner: AppOwner

    public var title: String { "\(product)\(AgentProduct.separator)\(label)" }
}

extension AgentCaches {
    /// Chromium cache folders that every app below uses.
    static let chromiumNames = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache", "Shared Dictionary"]

    public static let electronApps: [ElectronApp] = [
        ElectronApp(id: "claude", product: "Claude", label: "app caches", supportRoot: "Library/Application Support/Claude",
                    names: chromiumNames, cachesRoot: nil, cachesNames: [], owner: AgentOwners.claudeDesktop),
        // The Codex app has two cache places. Its component and extension download caches are rebuilt by Chromium.
        ElectronApp(id: "codex", product: "Codex", label: "app caches", supportRoot: "Library/Application Support/Codex",
                    names: chromiumNames + ["component_crx_cache", "extensions_crx_cache"],
                    cachesRoot: "Library/Caches/Codex/Default", cachesNames: ["Cache", "Code Cache"], owner: AgentOwners.codex),
        ElectronApp(id: "antigravity", product: "Antigravity", label: "app caches", supportRoot: "Library/Application Support/Antigravity",
                    names: chromiumNames, cachesRoot: nil, cachesNames: [], owner: AgentOwners.antigravity),
        ElectronApp(id: "antigravity-ide", product: "Antigravity", label: "IDE app caches",
                    supportRoot: "Library/Application Support/Antigravity IDE",
                    names: chromiumNames, cachesRoot: nil, cachesNames: [], owner: AgentOwners.antigravityIDE),
    ]

    public static func electronApp(id: String) -> ElectronApp? { electronApps.first { $0.id == id } }

    /// A partition name is plain: letters, digits, dot, dash, underscore. It cannot be `.` or `..`.
    static func isPartitionName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil && !name.contains("..")
    }

    /// True when `relative` is a cache folder of an Electron app: `<root>/<name>` or `<root>/Partitions/<partition>/<name>`.
    static func isElectronShape(relative: String) -> Bool {
        guard let p = parts(relative) else { return false }
        for app in electronApps {
            let root = app.supportRoot.split(separator: "/").map(String.init)
            guard p.count > root.count, Array(p.prefix(root.count)) == root else { continue }
            let rest = Array(p.dropFirst(root.count))
            if rest.count == 1, app.names.contains(rest[0]) { return true }
            if rest.count == 3, rest[0] == "Partitions", isPartitionName(rest[1]), app.names.contains(rest[2]) { return true }
        }
        return false
    }

    /// The cache folders of one app that exist now. A link, a file, and a missing folder are left out.
    public static func targets(of app: ElectronApp, home: URL) -> [URL] {
        let fm = FileManager.default
        func isDirectory(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory }
        func plainFolder(_ url: URL) -> Bool { isDirectory(url) && UpdateDownloads.isPlainPath(url) }
        var out: [URL] = []
        let root = home.appendingPathComponent(app.supportRoot, isDirectory: true)
        if plainFolder(root) {
            for name in app.names where plainFolder(root.appendingPathComponent(name, isDirectory: true)) {
                out.append(root.appendingPathComponent(name, isDirectory: true))
            }
            let partitions = root.appendingPathComponent("Partitions", isDirectory: true)
            if plainFolder(partitions) {
                for partition in ((try? fm.contentsOfDirectory(atPath: partitions.path)) ?? []).sorted() where isPartitionName(partition) {
                    let base = partitions.appendingPathComponent(partition, isDirectory: true)
                    guard plainFolder(base) else { continue }
                    for name in app.names where plainFolder(base.appendingPathComponent(name, isDirectory: true)) {
                        out.append(base.appendingPathComponent(name, isDirectory: true))
                    }
                }
            }
        }
        if let cachesRoot = app.cachesRoot {
            let base = home.appendingPathComponent(cachesRoot, isDirectory: true)
            if plainFolder(base) {
                for name in app.cachesNames where plainFolder(base.appendingPathComponent(name, isDirectory: true)) {
                    out.append(base.appendingPathComponent(name, isDirectory: true))
                }
            }
        }
        return out
    }

    /// True when `url` is one of the folders that `targets` can return for this app.
    public static func isTarget(_ url: URL, of app: ElectronApp, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let prefix = home.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let relative = String(path.dropFirst(prefix.count))
        if let cachesRoot = app.cachesRoot, let p = parts(relative) {
            let root = cachesRoot.split(separator: "/").map(String.init)
            if p.count == root.count + 1, Array(p.prefix(root.count)) == root, app.cachesNames.contains(p[root.count]) { return true }
        }
        guard isElectronShape(relative: relative), let p = parts(relative) else { return false }
        return app.supportRoot.split(separator: "/").map(String.init) == Array(p.prefix(app.supportRoot.split(separator: "/").count))
    }
}
