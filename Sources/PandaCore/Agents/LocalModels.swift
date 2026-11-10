import Foundation

/// Local model files of desktop apps: LM Studio, Jan, and GPT4All. One review item for each model.
///
/// None of these apps is installed on the author's Mac, so every path here comes from public documentation or reports and is
/// **not checked on a real install**. Bundle IDs are marked in the table. The apps have no documented delete command
/// (LM Studio has `lms ls`, but we do not rely on its JSON format), so a model is removed by deleting its own folder or file,
/// only at the exact depth that the table says, and only when the app is closed.
///
/// Never touched: the chats (`Jan/data/threads`), settings, `.internal` folders, the app's own files, and anything else in the same folder.
public struct ModelStore: Sendable, Equatable {
    public enum Layout: Sendable, Equatable {
        /// `<root>/<part>/…`: a folder at this depth is one model (`depth` 2 is `<publisher>/<model>`).
        case folders(depth: Int)
        /// `<root>/<file>.<ext>`: one file is one model.
        case files(ext: String)
    }

    public let id: String
    public let product: String
    public let root: String
    public let layout: Layout
    public let owner: AppOwner
}

public enum LocalModels {
    public static let stores: [ModelStore] = [
        // LM Studio: `~/.lmstudio/models/<publisher>/<model>` (default), `~/.cache/lm-studio/models` in older versions.
        ModelStore(id: "lmstudio", product: "LM Studio", root: ".lmstudio/models", layout: .folders(depth: 2),
                   owner: AppOwner(name: "LM Studio", bundleIDs: ["ai.elementlabs.lmstudio*"])),            // unverified bundle ID
        ModelStore(id: "lmstudio-old", product: "LM Studio", root: ".cache/lm-studio/models", layout: .folders(depth: 2),
                   owner: AppOwner(name: "LM Studio", bundleIDs: ["ai.elementlabs.lmstudio*"])),
        // Jan: the data folder is documented in more than one way (`~/jan`, `Application Support/Jan/data`). Only the second is used.
        ModelStore(id: "jan", product: "Jan", root: "Library/Application Support/Jan/data/models", layout: .folders(depth: 1),
                   owner: AppOwner(name: "Jan", bundleIDs: ["jan.ai.app*"])),                                // unverified bundle ID
        // GPT4All: model files in the app folder, and the Python bindings cache.
        ModelStore(id: "gpt4all", product: "GPT4All", root: "Library/Application Support/nomic.ai/GPT4All", layout: .files(ext: "gguf"),
                   owner: AppOwner(name: "GPT4All", bundleIDs: [], processNames: ["gpt4all"])),             // unverified process name
        ModelStore(id: "gpt4all-py", product: "GPT4All", root: ".cache/gpt4all", layout: .files(ext: "gguf"),
                   owner: AppOwner(name: "GPT4All", bundleIDs: [], processNames: ["gpt4all"])),
    ]

    public static func store(id: String) -> ModelStore? { stores.first { $0.id == id } }

    /// One path part: letters, digits, and `. _ + ( ) -` and spaces inside. It cannot start with a dot or a space, so `.internal` is out.
    static func isPart(_ text: String) -> Bool {
        text.count <= 200 && !text.contains("..") && !text.hasSuffix(" ")
            && text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+() -]*\z"#, options: .regularExpression) != nil
    }

    public struct Model: Equatable, Sendable {
        public let store: ModelStore
        /// The path inside the root: `publisher/model` or `file.gguf`.
        public let name: String
        public let url: URL
        public let bytes: Int64
    }

    /// True when `name` has the shape of one model of the store.
    static func isModelName(_ name: String, in store: ModelStore) -> Bool {
        let p = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard p.allSatisfy(isPart) else { return false }
        switch store.layout {
        case .folders(let depth): return p.count == depth
        case .files(let ext): return p.count == 1 && p[0].lowercased().hasSuffix("." + ext) && p[0].count > ext.count + 1
        }
    }

    private static func attributes(_ url: URL) -> [FileAttributeKey: Any]? { try? FileManager.default.attributesOfItem(atPath: url.path) }

    /// The models of one store, now. A link, a hidden name, a file or a folder of another shape, and an empty model are left out.
    public static func models(in store: ModelStore, home: URL) -> [Model] {
        let root = home.appendingPathComponent(store.root, isDirectory: true)
        guard attributes(root)?[.type] as? FileAttributeType == .typeDirectory, UpdateDownloads.isPlainPath(root) else { return [] }
        let fm = FileManager.default
        var out: [Model] = []
        func list(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().filter(isPart) }
        switch store.layout {
        case .files:
            for file in list(root) where isModelName(file, in: store) {
                let url = root.appendingPathComponent(file)
                guard attributes(url)?[.type] as? FileAttributeType == .typeRegular, UpdateDownloads.isPlainPath(url) else { continue }
                out.append(Model(store: store, name: file, url: url, bytes: Sizer.size(of: url)))
            }
        case .folders(let depth):
            var level: [(String, URL)] = [("", root)]
            for step in 1...depth {
                var next: [(String, URL)] = []
                for (prefix, dir) in level {
                    for name in list(dir) {
                        let url = dir.appendingPathComponent(name, isDirectory: true)
                        guard attributes(url)?[.type] as? FileAttributeType == .typeDirectory, UpdateDownloads.isPlainPath(url) else { continue }
                        next.append((prefix.isEmpty ? name : "\(prefix)/\(name)", url))
                    }
                }
                level = next
                if step == depth {
                    for (name, url) in level where isModelName(name, in: store) {
                        let bytes = Sizer.size(of: url)
                        if bytes > 0 { out.append(Model(store: store, name: name, url: url, bytes: bytes)) }
                    }
                }
            }
        }
        return out
    }

    public static func model(storeID: String, name: String, home: URL) -> Model? {
        guard let store = store(id: storeID), isModelName(name, in: store) else { return nil }
        return models(in: store, home: home).first { $0.name == name }
    }

    /// True when `relative` (below home) is one model of a store that is inside Application Support. The guard allows these only.
    static func isShape(relative: String) -> Bool {
        guard let p = AgentCaches.parts(relative) else { return false }
        for store in stores where store.root.hasPrefix("Library/Application Support/") {
            let root = store.root.split(separator: "/").map(String.init)
            guard p.count > root.count, Array(p.prefix(root.count)) == root else { continue }
            if isModelName(p.dropFirst(root.count).joined(separator: "/"), in: store) { return true }
        }
        return false
    }
}
