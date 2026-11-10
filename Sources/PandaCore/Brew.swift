import Foundation

/// A Homebrew formula that the user can remove. We ask `brew` for the list, and `brew` does the remove.
/// Trash Panda never deletes a file of Homebrew itself, and it never uses `--force` or `--ignore-dependencies`.
public struct Brew: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    /// `/opt/homebrew/bin/brew` has the prefix `/opt/homebrew`.
    public var prefix: URL { URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent() }
    public var cellar: URL { prefix.appendingPathComponent("Cellar", isDirectory: true) }

    /// A formula name, as `brew leaves` prints it: lower case, digits, and `@ + . _ -`.
    /// It may have a tap in front (`user/tap/name`). It cannot start with a dash, so it can never be read as an option.
    public static func isFormulaName(_ text: String) -> Bool {
        text.count <= 120 && text.range(
            of: #"^[a-z0-9][a-z0-9@+._-]*(/[a-z0-9][a-z0-9@+._-]*){0,2}\z"#, options: .regularExpression) != nil
            && !text.contains("..")
    }

    /// The folder of a formula in the Cellar. For `user/tap/name` it is `name`.
    func folder(of name: String) -> URL {
        cellar.appendingPathComponent(String(name.split(separator: "/").last ?? ""), isDirectory: true)
    }

    /// The formulae that no other formula needs, or nil when brew fails.
    public func leaves() -> [String]? {
        let r = Shell.run(path, ["leaves"], timeout: 60, quiet: true)
        guard r.status == 0, !r.timedOut else { return nil }
        return r.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter(Self.isFormulaName)
    }

    public struct Package: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        /// Days since the install. nil when the receipt has no date.
        public let installedDaysAgo: Int?
        /// False when Homebrew installed it only because another formula needed it.
        public let onRequest: Bool
    }

    /// What we know about one installed formula, from its folder and its install receipt.
    public func package(_ name: String, now: Date) -> Package? {
        let dir = folder(of: name)
        let fm = FileManager.default
        guard Self.isFormulaName(name), UpdateDownloads.isPlainPath(dir),
              (try? fm.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType == .typeDirectory else { return nil }
        let versions = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
        let newest = versions.max { a, b in
            let da = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(a).path))?[.modificationDate] as? Date ?? .distantPast
            let db = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(b).path))?[.modificationDate] as? Date ?? .distantPast
            return da < db
        }
        var days: Int?
        var onRequest = true
        if let newest,
           let data = try? Data(contentsOf: dir.appendingPathComponent(newest).appendingPathComponent("INSTALL_RECEIPT.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let time = (json["time"] as? NSNumber)?.doubleValue { days = max(0, Int((now.timeIntervalSince1970 - time) / 86_400)) }
            if let flag = json["installed_on_request"] as? Bool { onRequest = flag }
        }
        return Package(name: name, bytes: Sizer.size(of: dir), installedDaysAgo: days, onRequest: onRequest)
    }

    /// Bytes of one formula that are on the disk now. Zero when it is gone.
    public func bytes(of name: String) -> Int64 {
        let dir = folder(of: name)
        return FileManager.default.fileExists(atPath: dir.path) ? Sizer.size(of: dir) : 0
    }
}

/// One Homebrew command for one formula. The command has a fixed shape. The name is checked.
public enum BrewAction: Sendable, Equatable {
    case uninstall(name: String)

    public var name: String { if case .uninstall(let n) = self { return n } else { return "" } }

    /// The arguments after `brew`, or nil when the name is not valid.
    /// Brew itself refuses to remove a formula that another formula needs, because we never pass a force option.
    public var arguments: [String]? {
        guard Brew.isFormulaName(name) else { return nil }
        return ["uninstall", "--formula", name]
    }

    public var timeout: TimeInterval { 300 }
}
