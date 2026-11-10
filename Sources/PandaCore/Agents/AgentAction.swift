import Foundation

/// What the "AI agents & local models" group can do. Each case has one fixed shape.
/// The cleaner finds its targets again at clean time, and it checks each one. It never trusts the path in a finding alone.
public enum AgentAction: Sendable, Equatable {
    /// One folder of the Codex runtime cache: a leftover install, or the downloaded runtime itself.
    case removeCodexRuntime(URL)
}

/// The apps that own the folders of the AI agents group. An open app blocks its items (see #16 and #47).
/// A bundle ID that is not checked on a real install says so in a comment.
public enum AgentOwners {
    /// The Codex desktop app. Since late 2026 it shows the name "ChatGPT", and its bundle ID is still `com.openai.codex`.
    /// The `codex` command line tool uses the same runtime folders.
    public static let codex = AppOwner(name: "Codex", bundleIDs: ["com.openai.codex*"], processNames: ["codex"])
}

/// The product that an item belongs to. The title starts with it ("Codex · downloaded runtime"),
/// and the menu groups and draws the items by it.
public enum AgentProduct {
    public static let separator = " · "

    /// How the menu draws a product: the icon of its app when it is installed, and a system symbol when it is not.
    public struct Info: Equatable, Sendable {
        public let name: String
        /// Bundle IDs of the app, without wildcards, to find its icon. A tool with no app has none.
        /// An ID marked "unverified" comes from public reports and is not checked on a real install.
        public let iconBundleIDs: [String]
        /// An SF Symbol for when no app is installed.
        public let symbol: String
    }

    public static let all: [Info] = [
        Info(name: "Claude", iconBundleIDs: ["com.anthropic.claudefordesktop"], symbol: "sparkles"),
        Info(name: "Codex", iconBundleIDs: ["com.openai.codex"], symbol: "terminal"),
        Info(name: "ChatGPT", iconBundleIDs: ["com.openai.chat"], symbol: "bubble.left.and.bubble.right"),
        Info(name: "Antigravity", iconBundleIDs: ["com.google.antigravity", "com.google.antigravity-ide"], symbol: "arrow.up.circle"),
        Info(name: "VS Code", iconBundleIDs: ["com.microsoft.VSCode"], symbol: "chevron.left.forwardslash.chevron.right"),
        Info(name: "Cursor", iconBundleIDs: ["com.todesktop.230313mzl4w4u92"], symbol: "cursorarrow.rays"),
        // Unverified: Windsurf, LM Studio, Jan, and Ollama IDs come from public reports.
        Info(name: "Windsurf", iconBundleIDs: ["com.exafunction.windsurf"], symbol: "wind"),
        Info(name: "Zed", iconBundleIDs: ["dev.zed.Zed"], symbol: "bolt"),
        Info(name: "Ollama", iconBundleIDs: ["com.electron.ollama"], symbol: "shippingbox"),
        Info(name: "LM Studio", iconBundleIDs: ["ai.elementlabs.lmstudio"], symbol: "cube"),
        Info(name: "Jan", iconBundleIDs: ["jan.ai.app"], symbol: "bubble.left"),
        Info(name: "GPT4All", iconBundleIDs: [], symbol: "cpu"),
        Info(name: "Hugging Face", iconBundleIDs: [], symbol: "face.smiling"),
        Info(name: "uv", iconBundleIDs: [], symbol: "hare"),
        Info(name: "Gemini", iconBundleIDs: [], symbol: "star"),
    ]

    /// "Codex" for "Codex · downloaded runtime". nil when the title has no product part.
    public static func name(ofTitle title: String) -> String? {
        guard let range = title.range(of: separator) else { return nil }
        let name = String(title[..<range.lowerBound])
        return name.isEmpty ? nil : name
    }

    public static func info(forTitle title: String) -> Info? {
        name(ofTitle: title).flatMap { n in all.first { $0.name == n } }
    }
}
