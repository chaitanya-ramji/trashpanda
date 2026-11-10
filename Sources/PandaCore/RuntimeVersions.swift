import Foundation

/// Language runtimes that version managers install: nvm, fnm, pyenv, rustup, SDKMAN, asdf, and mise.
/// They keep every version that you ever installed, and each one can take hundreds of megabytes.
///
/// A version is offered only when ALL of these are true:
///  - it is not the default or global version of its manager,
///  - no scanned project asks for it (`.nvmrc`, `.node-version`, `.python-version`, `rust-toolchain`, `.tool-versions`, `.sdkmanrc`, `mise.toml`),
///  - it is not the newest version of its tool,
///  - no running program starts from inside it.
/// A request that we cannot read (`lts/*`, `latest`, `system`, a range) keeps every version of that tool.
/// The text says "no scanned project asks for it". It never says "unused", because a shell, a script, or an editor can use a version.
///
/// None of these managers is installed on the author's Mac. The folder layouts follow their documentation and are
/// **not checked on a real install**. The version folder is removed by its own path. That is what `uninstall` does for these managers,
/// and `nvm` and SDKMAN are shell functions that an app cannot run.
public struct RuntimeStore: Sendable, Equatable {
    public let id: String
    /// The manager, for the title: "nvm".
    public let manager: String
    /// The tool, when the whole store is one tool (`.nvm/versions/node`). nil when the folder level below the root is the tool.
    public let fixedTool: String?
    public let root: String
    /// 1: `<root>/<version>`. 2: `<root>/<tool>/<version>`.
    public let depth: Int
}

public enum RuntimeVersions {
    public static let stores: [RuntimeStore] = [
        RuntimeStore(id: "nvm", manager: "nvm", fixedTool: "node", root: ".nvm/versions/node", depth: 1),
        RuntimeStore(id: "fnm", manager: "fnm", fixedTool: "node", root: ".local/share/fnm/node-versions", depth: 1),
        RuntimeStore(id: "fnm-old", manager: "fnm", fixedTool: "node", root: ".fnm/node-versions", depth: 1),
        RuntimeStore(id: "fnm-mac", manager: "fnm", fixedTool: "node", root: "Library/Application Support/fnm/node-versions", depth: 1),
        RuntimeStore(id: "pyenv", manager: "pyenv", fixedTool: "python", root: ".pyenv/versions", depth: 1),
        RuntimeStore(id: "rustup", manager: "rustup", fixedTool: "rust", root: ".rustup/toolchains", depth: 1),
        RuntimeStore(id: "sdkman", manager: "SDKMAN", fixedTool: nil, root: ".sdkman/candidates", depth: 2),
        RuntimeStore(id: "asdf", manager: "asdf", fixedTool: nil, root: ".asdf/installs", depth: 2),
        RuntimeStore(id: "mise", manager: "mise", fixedTool: nil, root: ".local/share/mise/installs", depth: 2),
    ]

    public static func store(id: String) -> RuntimeStore? { stores.first { $0.id == id } }

    /// Names that other tools use for the same language, so that `.tool-versions` and the folders agree.
    static func normalizedTool(_ tool: String) -> String {
        let t = tool.lowercased()
        return ["nodejs": "node", "golang": "go", "rustc": "rust", "cpython": "python"][t] ?? t
    }

    static func isPart(_ s: String) -> Bool {
        s.count <= 120 && s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*\z"#, options: .regularExpression) != nil && !s.contains("..")
    }

    public struct Version: Equatable, Sendable {
        public let store: RuntimeStore
        public let tool: String
        public let name: String
        public let url: URL
        public let bytes: Int64

        /// The name that identifies it in an action: `<tool>/<name>`.
        public var key: String { "\(tool)/\(name)" }
    }

    private static func isPlainFolder(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory && UpdateDownloads.isPlainPath(url)
    }

    private static func children(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().filter(isPart)
    }

    /// Every installed version of a store, now. A link (an alias), `current`, and a name of another shape are left out.
    public static func versions(in store: RuntimeStore, home: URL, measure: Bool = true) -> [Version] {
        let root = home.appendingPathComponent(store.root, isDirectory: true)
        guard isPlainFolder(root) else { return [] }
        var out: [Version] = []
        func add(tool: String, dir: URL) {
            for name in children(dir) where name != "current" {
                let url = dir.appendingPathComponent(name, isDirectory: true)
                guard isPlainFolder(url) else { continue }
                out.append(Version(store: store, tool: tool, name: name, url: url, bytes: measure ? Sizer.size(of: url) : 0))
            }
        }
        if store.depth == 1 {
            add(tool: store.fixedTool ?? "?", dir: root)
        } else {
            for tool in children(root) {
                let dir = root.appendingPathComponent(tool, isDirectory: true)
                if isPlainFolder(dir) { add(tool: normalizedTool(tool), dir: dir) }
            }
        }
        return out
    }

    /// True when `relative` (below home) is one version folder of a store inside Application Support. The path guard allows these only.
    static func isShape(relative: String) -> Bool {
        guard let p = AgentCaches.parts(relative) else { return false }
        for store in stores where store.root.hasPrefix("Library/Application Support/") {
            let root = store.root.split(separator: "/").map(String.init)
            guard p.count == root.count + 1, Array(p.prefix(root.count)) == root else { continue }
            return isPart(p[root.count]) && p[root.count] != "current"
        }
        return false
    }

    // MARK: Which versions stay

    /// What a request asks for: a version of a tool. `exact` is false for something that we cannot read.
    public struct Request: Equatable, Sendable {
        public let tool: String
        public let spec: String
    }

    /// True when `spec` means this version. `20` and `v20` mean `v20.11.0`. `3.12` means `3.12.1`. A channel (`stable`) means
    /// `stable-aarch64-apple-darwin`. A request that we cannot read is not a match here, and `keepsAll` handles it.
    static func matches(spec: String, version: String) -> Bool {
        func strip(_ s: String) -> String { s.hasPrefix("v") || s.hasPrefix("V") ? String(s.dropFirst()) : s }
        let s = strip(spec.trimmingCharacters(in: .whitespaces)), v = strip(version)
        guard !s.isEmpty else { return false }
        return v == s || v.hasPrefix(s + ".") || v.hasPrefix(s + "-")
    }

    /// True when we cannot tell which version a request means, so every version of the tool must stay.
    static func keepsAll(spec: String, tool: String) -> Bool {
        let s = spec.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return true }
        // Rust channels are folder prefixes (`stable-aarch64-apple-darwin`). For every other tool these words are aliases that move.
        let channels: Set<String> = tool == "rust" ? ["stable", "beta", "nightly"] : []
        if ["system", "latest", "lts", "node", "stable", "beta", "nightly", "current", "default", "*"].contains(s) && !channels.contains(s) { return true }
        if s.hasPrefix("lts/") || s.hasPrefix("lts-") { return true }
        // A range or wildcard (`20.x`, `3.10.*`, `^18`, `>=3.9`, `a || b`): anything that is not a plain version or a channel.
        if s.split(whereSeparator: { ".-".contains($0) }).contains(where: { $0 == "x" || $0 == "*" }) { return true }
        return s.range(of: #"^[a-z0-9]+([.+_-][a-z0-9]+)*\z"#, options: .regularExpression) == nil
    }

    /// The versions that a manager names as its default or global version, as specs. The files are read every time.
    public static func defaults(for store: RuntimeStore, home: URL) -> [Request] {
        func read(_ rel: String) -> String? { try? String(contentsOf: home.appendingPathComponent(rel), encoding: .utf8) }
        switch store.id {
        case "nvm":
            return (read(".nvm/alias/default").map { [Request(tool: "node", spec: $0.trimmingCharacters(in: .whitespacesAndNewlines))] }) ?? []
        case "fnm", "fnm-old", "fnm-mac":
            // `<fnm dir>/aliases/default` is a link to the version folder.
            let aliases = home.appendingPathComponent(store.root).deletingLastPathComponent().appendingPathComponent("aliases/default")
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: aliases.path) else { return [] }
            let parts = target.split(separator: "/").map(String.init)
            let name = parts.last == "installation" && parts.count >= 2 ? parts[parts.count - 2] : (parts.last ?? "")
            return name.isEmpty ? [] : [Request(tool: "node", spec: name)]
        case "pyenv":
            let words = (read(".pyenv/version") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
            return words.map { Request(tool: "python", spec: $0) }
        case "rustup":
            // Every quoted string of settings.toml counts: the default toolchain, and the toolchain of each directory override.
            let text = read(".rustup/settings.toml") ?? ""
            var out: [Request] = []
            var rest = Substring(text)
            while let a = rest.firstIndex(of: "\""), let b = rest[rest.index(after: a)...].firstIndex(of: "\"") {
                let s = String(rest[rest.index(after: a)..<b])
                if !s.hasPrefix("/"), !s.isEmpty { out.append(Request(tool: "rust", spec: s)) }
                rest = rest[rest.index(after: b)...]
            }
            return out
        case "sdkman":
            // `candidates/<tool>/current` is a link to the version in use.
            let root = home.appendingPathComponent(store.root)
            return children(root).compactMap { tool in
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(tool).appendingPathComponent("current").path)
                else { return nil }
                return Request(tool: normalizedTool(tool), spec: (target as NSString).lastPathComponent)
            }
        case "asdf", "mise":
            return toolVersions(read(".tool-versions") ?? "") + (store.id == "mise" ? miseConfig(read(".config/mise/config.toml") ?? "") : [])
        default: return []
        }
    }

    // MARK: Reading the files of projects

    /// `tool 1.2.3 4.5.6` lines. A comment starts with `#`.
    static func toolVersions(_ text: String) -> [Request] {
        text.split(whereSeparator: \.isNewline).flatMap { line -> [Request] in
            let words = String(line).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard words.count >= 2 else { return [] }
            return words.dropFirst().map { Request(tool: normalizedTool(words[0]), spec: $0) }
        }
    }

    /// `tool = "1.2.3"` lines of a mise file. Only this simple form is read. Any other form of a tool keeps all of its versions.
    static func miseConfig(_ text: String) -> [Request] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> Request? in
            let t = String(line).trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), !t.hasPrefix("["), let eq = t.firstIndex(of: "=") else { return nil }
            let tool = t[..<eq].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            var value = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard isPart(tool) else { return nil }
            if value.hasPrefix("\"") || value.hasPrefix("'") { value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            else { value = "<complex>" }                        // an array or a table: not a plain version
            return Request(tool: normalizedTool(String(tool)), spec: value)
        }
    }

    /// The version requests of one project file. Unknown files give nothing.
    static func requests(inFile name: String, text: String) -> [Request] {
        let line = text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        switch name {
        case ".nvmrc", ".node-version": return line.isEmpty ? [] : [Request(tool: "node", spec: line)]
        case ".python-version":
            return text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { Request(tool: "python", spec: $0) }
        case "rust-toolchain":
            if line.hasPrefix("[") { return rustToolchainToml(text) }
            return line.isEmpty ? [] : [Request(tool: "rust", spec: line)]
        case "rust-toolchain.toml": return rustToolchainToml(text)
        case ".tool-versions": return toolVersions(text)
        case "mise.toml", ".mise.toml": return miseConfig(text)
        case ".sdkmanrc":
            return text.split(whereSeparator: \.isNewline).compactMap { l -> Request? in
                let parts = String(l).split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 && !parts[0].hasPrefix("#") ? Request(tool: normalizedTool(parts[0]), spec: parts[1]) : nil
            }
        default: return []
        }
    }

    static func rustToolchainToml(_ text: String) -> [Request] {
        guard let m = text.range(of: #"channel\s*=\s*"([^"]+)""#, options: .regularExpression), let q = text[m].firstIndex(of: "\"") else {
            return [Request(tool: "rust", spec: "*")]            // a file that we cannot read keeps all versions of Rust
        }
        return [Request(tool: "rust", spec: String(text[m][text[m].index(after: q)...].dropLast()))]
    }

    static let projectFiles: Set<String> = [".nvmrc", ".node-version", ".python-version", "rust-toolchain", "rust-toolchain.toml", ".tool-versions",
                                            ".sdkmanrc", "mise.toml", ".mise.toml"]

    /// The version requests of the projects below the roots. A folder that holds build output or packages is not entered.
    public static func projectRequests(roots: [URL], maxDepth: Int = 6, maxFiles: Int = 20_000) -> [Request] {
        var out: [Request] = []
        var visited = 0
        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth, visited < maxFiles, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names.sorted() {
                visited += 1
                let url = dir.appendingPathComponent(name)
                let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
                if type == .typeRegular, projectFiles.contains(name), let text = try? String(contentsOf: url, encoding: .utf8) {
                    out += requests(inFile: name, text: text)
                } else if type == .typeDirectory, !Catalog.skipDescend.contains(name), !Catalog.isArtifactName(name), name != ".git" {
                    walk(url, depth: depth + 1)
                }
            }
        }
        roots.forEach { walk($0, depth: 0) }
        return out
    }

    /// The numbers in a version folder name: `v20.11.0` and `20.11.0` give `20.11.0`. nil when the name has no dotted number.
    static func versionKey(_ name: String) -> String? {
        guard let r = name.range(of: #"[0-9]+(\.[0-9]+)+"#, options: .regularExpression) else { return nil }
        return String(name[r])
    }

    // MARK: The decision

    public struct Decision: Equatable, Sendable {
        public let removable: [Version]
        /// For each version that stays, why. Tests and the log use it.
        public let kept: [String: String]
    }

    /// Splits the installed versions into those that we offer and those that stay.
    public static func decide(home: URL, requests projectRequests: [Request], running programs: [String], measure: Bool = true) -> Decision {
        var removable: [Version] = []
        var kept: [String: String] = [:]
        for store in stores {
            let all = versions(in: store, home: home, measure: measure)
            let defaults = defaults(for: store, home: home)
            let byTool = Dictionary(grouping: all, by: \.tool)
            for (tool, list) in byTool {
                let wanted = (projectRequests + defaults).filter { $0.tool == tool }
                let keepsAll = wanted.contains { keepsAll(spec: $0.spec, tool: tool) }
                // The newest version stays, when the names are versions. Rust channels are updated in place, so they have no newest.
                let keys = Dictionary(uniqueKeysWithValues: list.map { ($0.name, versionKey($0.name)) })
                let newest = store.id == "rustup" ? nil : ClaudeVersions.newest(of: keys.values.compactMap { $0 })
                for v in list {
                    let key = "\(store.id)/\(v.key)"
                    if keepsAll { kept[key] = "a request keeps every version of \(tool)"; continue }
                    if defaults.contains(where: { $0.tool == tool && matches(spec: $0.spec, version: v.name) }) { kept[key] = "default"; continue }
                    if projectRequests.contains(where: { $0.tool == tool && matches(spec: $0.spec, version: v.name) }) { kept[key] = "a project asks for it"; continue }
                    if let n = newest, keys[v.name] ?? nil == n { kept[key] = "newest"; continue }
                    let folder = v.url.resolvingSymlinksInPath().path + "/"
                    if programs.contains(where: { $0.hasPrefix(folder) }) { kept[key] = "a program runs from it"; continue }
                    removable.append(v)
                }
            }
        }
        return Decision(removable: removable.sorted { ($0.bytes, $1.url.path) > ($1.bytes, $0.url.path) }, kept: kept)
    }
}
