import Foundation

/// Local models of Ollama. Ollama keeps them in `~/.ollama/models` as shared layers (`blobs`) and small descriptions (`manifests`).
/// A layer can belong to more than one model, so deleting a file by hand can break other models. Only `ollama rm` is safe.
/// This code never touches a file in `~/.ollama`. The path guard refuses the whole folder.
///
/// Source: the Ollama docs (`ollama ls`, `ollama rm`, `OLLAMA_MODELS`) and community reports on shared layers.
/// Ollama is not installed on the author's Mac, so the output format of `ollama ls` and `ollama ps` is not checked on a real install.
public struct Ollama: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    public struct Model: Equatable, Sendable {
        public let name: String
        public let bytes: Int64
        /// Days since the model was pulled or changed, or nil when the text could not be read.
        public let ageDays: Int?
    }

    /// A model name: `llama3:8b`, `hf.co/user/model:Q4_K_M`, `library/x`. It cannot start with a dash or a slash,
    /// and it cannot hold `..`, a space, or a shell sign, so it can never be read as an option or a path.
    public static func isModelName(_ text: String) -> Bool {
        text.count <= 200 && !text.contains("..") && text.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*(:[A-Za-z0-9._-]{1,128})?\z"#, options: .regularExpression) != nil
    }

    /// "4.7 GB" -> bytes. Ollama uses decimal units.
    static func parseSize(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let m = t.range(of: #"^([0-9]+(\.[0-9]+)?)\s*(B|KB|MB|GB|TB)\z"#, options: [.regularExpression, .caseInsensitive]),
              let split = t[m].range(of: #"[A-Za-z]+\z"#, options: .regularExpression),
              let value = Double(t[m][..<split.lowerBound].trimmingCharacters(in: .whitespaces)) else { return nil }
        let scale: Double
        switch t[m][split.lowerBound...].uppercased() {
        case "B": scale = 1
        case "KB": scale = 1_000
        case "MB": scale = 1_000_000
        case "GB": scale = 1_000_000_000
        default: scale = 1_000_000_000_000
        }
        return Int64(value * scale)
    }

    /// "2 weeks ago", "About an hour ago", "a day ago" -> days. nil when the text has another shape.
    static func parseAgeDays(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let r = t.range(of: #"^(about\s+)?([0-9]+|an?)\s+(second|minute|hour|day|week|month|year)s?\s+ago\z"#, options: .regularExpression) else { return nil }
        let words = t[r].split(separator: " ").map(String.init)
        let unit = words[words.count - 2].trimmingCharacters(in: CharacterSet(charactersIn: "s"))
        let countWord = words[words.count - 3]
        guard let n = Int(countWord) ?? (["a", "an"].contains(countWord) ? 1 : nil) else { return nil }
        switch unit {
        case "second", "minute", "hour": return 0
        case "day": return n
        case "week": return n * 7
        case "month": return n * 30
        default: return n * 365
        }
    }

    /// Reads the table of `ollama ls`: NAME, ID, SIZE, MODIFIED, separated by two or more spaces.
    static func parseList(_ output: String) -> [Model] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> Model? in
            let cols = String(line).components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard cols.count >= 4, cols[0] != "NAME", isModelName(cols[0]), let bytes = parseSize(cols[2]) else { return nil }
            return Model(name: cols[0], bytes: bytes, ageDays: parseAgeDays(cols[3]))
        }
    }

    /// Reads the first column of `ollama ps`: the models that are loaded now.
    static func parseLoaded(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let first = String(line).components(separatedBy: "  ").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return first.isEmpty || first == "NAME" ? nil : first
        })
    }

    /// The models that are downloaded, or nil when Ollama did not answer (the server may not run).
    public func models() -> [Model]? {
        let r = Shell.run(path, ["ls"], timeout: 20, quiet: true)
        return r.status == 0 && !r.timedOut ? Self.parseList(r.stdout) : nil
    }

    /// The models that are loaded in memory now, or nil when Ollama did not answer.
    public func loaded() -> Set<String>? {
        let r = Shell.run(path, ["ps"], timeout: 20, quiet: true)
        return r.status == 0 && !r.timedOut ? Self.parseLoaded(r.stdout) : nil
    }

    /// The only command that removes a model. There is no `-a` and no `--force`.
    public static func removeArguments(_ name: String) -> [String]? { isModelName(name) ? ["rm", name] : nil }

    public func remove(_ name: String) -> ShellResult? {
        Self.removeArguments(name).map { Shell.run(path, $0, timeout: 120) }
    }

    /// Where Ollama keeps its models by default. We only read the size of it to measure what a remove frees.
    public static func modelsFolder(home: URL) -> URL { home.appendingPathComponent(".ollama/models", isDirectory: true) }
}
