import Foundation

/// A code editor that is a fork of VS Code: VS Code itself, Cursor, Windsurf, and Antigravity.
/// They keep rebuildable folders next to the data that must stay.
///
/// Rebuildable (community consensus, no vendor document): `CachedData` (V8 code cache, one folder for each version),
/// `CachedExtensionVSIXs` (downloaded extension packages), the Chromium caches, and `logs/<timestamp>` folders.
/// Never touched: `User` (settings, `workspaceStorage` with the chats of Copilot, `globalStorage` and `state.vscdb` with logins
/// and the chats of Cursor), `Backups` (unsaved files), `Local Storage`, `Session Storage`, `Cookies`.
public struct EditorApp: Sendable, Equatable {
    public let id: String
    /// The product part of the title. It must be in `AgentProduct.all`.
    public let product: String
    public let label: String
    public let supportRoot: String
    public let names: [String]
    /// The folder of installed extensions, relative to home, or nil. It holds `.obsolete` and `extensions.json`.
    public let extensionsRoot: String?
    public let owner: AppOwner

    public var title: String { "\(product)\(AgentProduct.separator)\(label)" }
    public var extensionsTitle: String { "\(product)\(AgentProduct.separator)obsolete extensions" }
}

public enum EditorCaches {
    /// Logs of a session are `logs/<yyyyMMdd>T<HHmmss>`. A newer folder may belong to a running window.
    public static let minimumLogAgeDays = 7
    static let editorNames = ["CachedData", "CachedExtensionVSIXs"]

    public static let apps: [EditorApp] = [
        EditorApp(id: "vscode", product: "VS Code", label: "editor caches", supportRoot: "Library/Application Support/Code",
                  names: editorNames + AgentCaches.chromiumNames, extensionsRoot: ".vscode/extensions", owner: EditorCaches.vscodeOwner),
        // Unverified: the bundle ID of Windsurf and the extensions folders of Cursor and Windsurf come from public reports.
        EditorApp(id: "cursor", product: "Cursor", label: "editor caches", supportRoot: "Library/Application Support/Cursor",
                  names: editorNames + AgentCaches.chromiumNames, extensionsRoot: ".cursor/extensions", owner: EditorCaches.cursorOwner),
        EditorApp(id: "windsurf", product: "Windsurf", label: "editor caches", supportRoot: "Library/Application Support/Windsurf",
                  names: editorNames + AgentCaches.chromiumNames, extensionsRoot: ".windsurf/extensions", owner: EditorCaches.windsurfOwner),
        // The Chromium caches of Antigravity are in `AgentCaches.electronApps`. Here are only the editor folders and the logs.
        EditorApp(id: "antigravity", product: "Antigravity", label: "editor caches", supportRoot: "Library/Application Support/Antigravity",
                  names: editorNames, extensionsRoot: nil, owner: AgentOwners.antigravity),
        EditorApp(id: "antigravity-ide", product: "Antigravity", label: "IDE editor caches",
                  supportRoot: "Library/Application Support/Antigravity IDE",
                  names: editorNames, extensionsRoot: nil, owner: AgentOwners.antigravityIDE),
    ]

    static let vscodeOwner = AppOwner(name: "VS Code", bundleIDs: ["com.microsoft.VSCode*"])
    static let cursorOwner = AppOwner(name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92*"])
    static let windsurfOwner = AppOwner(name: "Windsurf", bundleIDs: ["com.exafunction.windsurf*"])

    public static func app(id: String) -> EditorApp? { apps.first { $0.id == id } }

    static func isLogName(_ name: String) -> Bool {
        name.range(of: #"^[0-9]{8}T[0-9]{6}$"#, options: .regularExpression) != nil
    }

    /// True when `relative` is a folder of an editor that we may delete: `<root>/<name>` or `<root>/logs/<timestamp>`.
    static func isShape(relative: String) -> Bool {
        guard let p = AgentCaches.parts(relative) else { return false }
        for app in apps {
            let root = app.supportRoot.split(separator: "/").map(String.init)
            guard p.count > root.count, Array(p.prefix(root.count)) == root else { continue }
            let rest = Array(p.dropFirst(root.count))
            if rest.count == 1, app.names.contains(rest[0]) { return true }
            if rest.count == 2, rest[0] == "logs", isLogName(rest[1]) { return true }
        }
        return false
    }

    static func isPlainFolder(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
            && UpdateDownloads.isPlainPath(url)
    }

    /// The cache folders and the old log folders of one editor, now. A link and a log younger than 7 days are left out.
    public static func targets(of app: EditorApp, home: URL, now: Date) -> [URL] {
        let root = home.appendingPathComponent(app.supportRoot, isDirectory: true)
        guard isPlainFolder(root) else { return [] }
        var out = app.names.map { root.appendingPathComponent($0, isDirectory: true) }.filter(isPlainFolder)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        if isPlainFolder(logs) {
            let limit = TimeInterval(minimumLogAgeDays) * 86_400
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []).sorted() where isLogName(name) {
                let url = logs.appendingPathComponent(name, isDirectory: true)
                guard isPlainFolder(url),
                      let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) >= limit else { continue }
                out.append(url)
            }
        }
        return out
    }

    /// True when `url` is one of the folders that `targets` can return for this editor, by its path alone.
    public static func isTarget(_ url: URL, of app: EditorApp, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let prefix = home.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let relative = String(path.dropFirst(prefix.count))
        guard isShape(relative: relative), let p = AgentCaches.parts(relative) else { return false }
        let root = app.supportRoot.split(separator: "/").map(String.init)
        return Array(p.prefix(root.count)) == root
    }

    // MARK: Obsolete extensions

    /// An extension folder name, such as `ms-python.python-2025.1.0-darwin-arm64`. It cannot start with a dot or hold a slash.
    static func isExtensionFolderName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#, options: .regularExpression) != nil && !name.contains("..")
    }

    /// The folders that the editor itself marks as obsolete in `<extensions>/.obsolete`. A folder that `extensions.json`
    /// still lists as installed is left out. Only plain folders directly in the extensions folder are returned.
    public static func obsoleteExtensions(of app: EditorApp, home: URL) -> [URL] {
        guard let rel = app.extensionsRoot else { return [] }
        let dir = home.appendingPathComponent(rel, isDirectory: true)
        guard isPlainFolder(dir),
              let data = try? Data(contentsOf: dir.appendingPathComponent(".obsolete")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let installed = installedNames(in: dir)
        // Only a real JSON `true` counts. The number 1 is not a boolean here, even if Foundation can read it as one.
        func isTrue(_ value: Any) -> Bool {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
            return n.boolValue
        }
        return json.filter { isTrue($0.value) }.keys.sorted().compactMap { name in
            guard isExtensionFolderName(name), !installed.contains(name) else { return nil }
            let url = dir.appendingPathComponent(name, isDirectory: true)
            return isPlainFolder(url) ? url : nil
        }
    }

    /// The folder names that `extensions.json` lists as installed. We read every string in it, so that a changed format keeps more.
    static func installedNames(in dir: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("extensions.json")),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var names: Set<String> = []
        func walk(_ value: Any) {
            switch value {
            case let s as String: for part in s.split(separator: "/") { names.insert(String(part)) }
            case let a as [Any]: a.forEach(walk)
            case let d as [String: Any]: d.values.forEach(walk)
            default: break
            }
        }
        walk(json)
        return names
    }

    /// True when `url` is `<extensions>/<name>` for this editor, with a valid folder name.
    public static func isExtensionTarget(_ url: URL, of app: EditorApp, home: URL) -> Bool {
        guard let rel = app.extensionsRoot else { return false }
        let path = url.standardizedFileURL.path
        let prefix = home.appendingPathComponent(rel, isDirectory: true).standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let name = String(path.dropFirst(prefix.count))
        return !name.contains("/") && isExtensionFolderName(name)
    }
}
