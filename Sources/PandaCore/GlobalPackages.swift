import Foundation

/// A JavaScript package manager with global packages.
public enum PackageManager: String, CaseIterable, Sendable {
    case npm, pnpm, yarn, bun

    public var tool: String { rawValue }
    public var label: String { rawValue }

    /// The command that lists global packages.
    var listArguments: [String] {
        switch self {
        case .npm: return ["ls", "-g", "--depth=0", "--json"]
        case .pnpm: return ["ls", "-g", "--json"]
        case .yarn: return ["global", "list"]
        case .bun: return ["pm", "ls", "-g"]
        }
    }

    /// The command that prints the folder of the global packages. Bun has a fixed folder in the home folder.
    var rootArguments: [String]? {
        switch self {
        case .npm: return ["root", "-g"]
        case .pnpm: return ["root", "-g"]
        case .yarn: return ["global", "dir"]
        case .bun: return nil
        }
    }

    /// The only command that removes one package. The name is checked before.
    func removeArguments(_ name: String) -> [String]? {
        guard GlobalPackages.isPackageName(name) else { return nil }
        switch self {
        case .npm: return ["uninstall", "-g", name]
        case .pnpm: return ["remove", "-g", name]
        case .yarn: return ["global", "remove", name]
        case .bun: return ["remove", "-g", name]
        }
    }
}

/// Packages that were installed with `npm install -g`, `pnpm add -g`, `yarn global add`, or `bun add -g`.
/// People install a tool once and forget it. No manager says when a tool was last used, so we show the date of the package
/// folder (installed or updated) and never call a package "unused". The manager itself removes the package.
///
/// A program that calls the tool (for example an MCP server that an AI app starts) stops working when the package is removed.
/// The dialog says so, and it keeps the package by default.
/// `npm` is checked on a real Mac. The output of `pnpm`, `yarn`, and `bun` follows their documentation, and is not checked on a real install.
public enum GlobalPackages {
    /// The managers and their helpers. Removing them would break the tool that removes the rest.
    static let protectedNames: Set<String> = ["npm", "npx", "pnpm", "pnpx", "yarn", "yarnpkg", "bun", "bunx", "corepack", "node"]

    /// An npm package name: `name` or `@scope/name`, at most 214 characters. It cannot start with a dash or a dot.
    public static func isPackageName(_ text: String) -> Bool {
        text.count <= 214 && !text.contains("..") && text.range(
            of: #"^(@[A-Za-z0-9][A-Za-z0-9._~-]*/)?[A-Za-z0-9][A-Za-z0-9._~-]*\z"#, options: .regularExpression) != nil
    }

    public struct Package: Equatable, Sendable {
        public let manager: PackageManager
        public let name: String
        public let version: String
        public let folder: URL
        public let bytes: Int64
        public let ageDays: Int?
    }

    // MARK: Reading the output

    /// The `name` and `version` pairs in the output of the list command. Names that are not valid are dropped.
    static func parse(_ manager: PackageManager, _ output: String) -> [(name: String, version: String)] {
        var found: [(String, String)] = []
        func dependencies(_ object: Any?) {
            guard let deps = (object as? [String: Any])?["dependencies"] as? [String: Any] else { return }
            for (name, value) in deps.sorted(by: { $0.key < $1.key }) {
                found.append((name, ((value as? [String: Any])?["version"] as? String) ?? ""))
            }
        }
        switch manager {
        case .npm:
            guard let data = output.data(using: .utf8) else { return [] }
            dependencies(try? JSONSerialization.jsonObject(with: data))
        case .pnpm:
            guard let data = output.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
            if let list = json as? [Any] { list.forEach(dependencies) } else { dependencies(json) }
        case .yarn:
            // `info "name@1.2.3" has binaries:` for each package.
            for line in output.split(whereSeparator: \.isNewline) {
                if let m = String(line).range(of: #"^info "((@[^/"@]+/)?[^@"/]+)@([^"]*)""#, options: .regularExpression) {
                    let text = String(line)[m].dropFirst(6).dropLast()
                    if let at = text.lastIndex(of: "@") { found.append((String(text[..<at]), String(text[text.index(after: at)...]))) }
                }
            }
        case .bun:
            // `├── name@1.2.3` and `└── name@1.2.3`.
            for line in output.split(whereSeparator: \.isNewline) {
                guard let m = String(line).range(of: #"[├└]── ((@[^/@\s]+/)?[^@\s/]+)@(\S+)"#, options: .regularExpression) else { continue }
                let text = String(line)[m].dropFirst(4)
                if let at = text.lastIndex(of: "@") { found.append((String(text[..<at]), String(text[text.index(after: at)...]))) }
            }
        }
        var seen: Set<String> = []
        return found.filter { isPackageName($0.0) && seen.insert($0.0).inserted }
    }

    // MARK: Reading the disk

    private static func isPlainFolder(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory && UpdateDownloads.isPlainPath(url)
    }

    /// The folder that holds the global packages, or nil.
    static func root(_ manager: PackageManager, tool: String, home: URL) -> URL? {
        if let args = manager.rootArguments {
            let r = Shell.run(tool, args, timeout: 15, quiet: true)
            guard r.status == 0, !r.timedOut else { return nil }
            let text = r.stdout.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            guard text.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: text, isDirectory: true)
            return manager == .yarn ? url.appendingPathComponent("node_modules", isDirectory: true) : url
        }
        return home.appendingPathComponent(".bun/install/global/node_modules", isDirectory: true)
    }

    /// The global packages of one manager. nil when the manager did not answer. Managers and helpers are left out.
    /// A package whose folder cannot be found, or is a link, is left out too, because we could not measure it.
    public static func list(_ manager: PackageManager, tool: String, home: URL, now: Date) -> [Package]? {
        let r = Shell.run(tool, manager.listArguments, timeout: 30, quiet: true)
        guard r.status == 0, !r.timedOut else { return nil }
        guard let root = root(manager, tool: tool, home: home), isPlainFolder(root) else { return [] }
        return parse(manager, r.stdout).compactMap { name, version in
            guard !protectedNames.contains(name) else { return nil }
            let folder = name.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
            guard isPlainFolder(folder) else { return nil }
            let modified = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date
            return Package(manager: manager, name: name, version: version, folder: folder, bytes: Sizer.size(of: folder),
                           ageDays: modified.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) })
        }
    }
}
