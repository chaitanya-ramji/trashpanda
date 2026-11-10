import Foundation

/// What the "AI agents & local models" group can do. Each case has one fixed shape.
/// The cleaner finds its targets again at clean time, and it checks each one. It never trusts the path in a finding alone.
public enum AgentAction: Sendable, Equatable {
    /// One folder of the Codex runtime cache: a leftover install, or the downloaded runtime itself.
    case removeCodexRuntime(URL)
    /// The old versions of the Claude Code command line tool. The cleaner finds them again, and keeps the newest, the linked one, and any that runs.
    /// `names` are the versions that the preview showed. The cleaner removes only those that are still old now.
    case removeOldClaudeVersions(names: [String])
    /// The old runtimes of Claude Desktop (all but the newest of each family). The cleaner finds them again.
    /// `names` are the runtimes that the preview showed (`claude-code/2.1.309`). The cleaner removes only those that are still old now.
    case removeOldClaudeDesktopRuntimes(names: [String])
    /// The Cowork VM folders of Claude Desktop. The cleaner finds them again from fixed names.
    case removeClaudeVMBundle
    /// The cache folders of one Electron app (see `AgentCaches.electronApps`). The cleaner finds them again from the app id.
    case removeAgentCaches(appID: String)
    /// The cache folders and old logs of one VS Code style editor. The cleaner finds them again from the editor id.
    case removeEditorCaches(appID: String)
    /// The extension folders that one editor lists as obsolete (and does not list as installed).
    case removeObsoleteExtensions(appID: String)
    /// One Ollama model. The cleaner asks `ollama rm <name>`, and nothing else. A model that is loaded is skipped.
    case removeOllamaModel(name: String)
    /// One Hugging Face repository (`model/org/name`). The cleaner finds its folder again, and removes it with `hf` or by folder.
    case removeHuggingFaceRepo(id: String)
    /// One model of LM Studio, Jan, or GPT4All (`LocalModels.stores`). The cleaner finds it again from the store id and the name.
    case removeLocalModel(storeID: String, name: String)
    /// The fixed folders of one app (`FixedFolders.apps`). The cleaner finds them again from the app id.
    case removeFixedFolders(appID: String)
    /// Transcripts of one agent that were last changed at or before `olderThan`. The date is the one of the preview, so a session that
    /// became old, or that was used again, after the preview is not removed. `minimumAgeDays` is a floor that the cleaner applies against
    /// the clock of the clean, so that a wrong clock at the preview cannot make new sessions look old.
    case removeOldSessions(kind: AgentSessions.Kind, olderThan: Date, minimumAgeDays: Int)
}

/// The apps that own the folders of the AI agents group. An open app blocks its items (see #16 and #47).
/// A bundle ID that is not checked on a real install says so in a comment.
public enum AgentOwners {
    /// The Codex desktop app. Since late 2026 it shows the name "ChatGPT", and its bundle ID is still `com.openai.codex`.
    /// The `codex` command line tool uses the same runtime folders.
    /// Claude Desktop. The bundle ID is checked on a real Mac.
    public static let claudeDesktop = AppOwner(name: "Claude", bundleIDs: [ClaudeDesktop.bundleID + "*"])

    /// Antigravity and its IDE. The bundle IDs are checked on a real Mac.
    public static let antigravity = AppOwner(name: "Antigravity", bundleIDs: ["com.google.antigravity", "com.google.antigravity.helper*"])
    public static let antigravityIDE = AppOwner(name: "Antigravity IDE", bundleIDs: ["com.google.antigravity-ide", "com.google.antigravity-ide.helper*"])

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

extension Action {
    /// The names inside an agent action that carries a preview list. Tests use it.
    var agentNames: [String]? {
        switch self {
        case .agent(.removeOldClaudeVersions(let names)), .agent(.removeOldClaudeDesktopRuntimes(let names)): return names
        default: return nil
        }
    }
}
