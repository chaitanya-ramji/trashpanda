import Foundation

/// An app whose rebuildable data is in a few folders with exact, fixed paths. Each folder is removed as a whole.
/// The path guard allows exactly these paths (for the ones inside Application Support) and nothing below or beside them.
public struct FixedFolderApp: Sendable, Equatable {
    public let id: String
    /// The product part of the title. It must be in `AgentProduct.all`.
    public let product: String
    public let label: String
    /// Folders relative to the home folder.
    public let folders: [String]
    public let owner: AppOwner

    public var title: String { "\(product)\(AgentProduct.separator)\(label)" }
}

public enum FixedFolders {
    public static let apps: [FixedFolderApp] = [
        // Zed (documented: the Zed FAQ and the uninstall guide). `languages` holds downloaded language servers, which Zed fetches again.
        // `db` (workspace state), `extensions`, and the conversations are never allowed.
        FixedFolderApp(id: "zed", product: "Zed", label: "caches and language servers",
                       folders: ["Library/Caches/Zed", "Library/Caches/dev.zed.Zed", "Library/Application Support/Zed/languages"],
                       owner: AppOwner(name: "Zed", bundleIDs: ["dev.zed.Zed*"])),
    ]

    public static func app(id: String) -> FixedFolderApp? { apps.first { $0.id == id } }

    /// True when `relative` is exactly one of the folders of an app.
    static func isShape(relative: String) -> Bool {
        guard AgentCaches.parts(relative) != nil else { return false }
        return apps.contains { $0.folders.contains(relative) }
    }

    /// The folders of one app that exist now. A link and a file are left out.
    public static func targets(of app: FixedFolderApp, home: URL) -> [URL] {
        app.folders.compactMap { rel in
            let url = home.appendingPathComponent(rel, isDirectory: true)
            guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory,
                  UpdateDownloads.isPlainPath(url) else { return nil }
            return url
        }
    }

    public static func isTarget(_ url: URL, of app: FixedFolderApp, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let prefix = home.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        return app.folders.contains(String(path.dropFirst(prefix.count)))
    }
}
