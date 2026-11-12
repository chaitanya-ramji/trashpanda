import Foundation

/// What the cleaner does with a file or a folder that it may remove.
/// `permanent` is the default: the file is deleted for good. `trash` moves it to the Trash, so the user can put it back.
/// The setting is `delete_mode = trash` in `~/.config/trashpanda/settings`.
public enum DeleteMode: String, Sendable, Equatable, CaseIterable {
    case permanent
    case trash

    public static let settingName = "delete_mode"

    /// True when the action removes files or folders by itself. In trash mode, these go to the Trash.
    /// An action that runs a tool (Docker, Homebrew, the simulator, a package manager, Ollama, `hf`) is not a file delete.
    /// It stays as it is in both modes, and the Trash is not used. Emptying the Trash is also not a file delete.
    /// A Hugging Face repository is removed by the `hf` tool when it is installed, and by a folder delete when it is not.
    /// `hfInstalled` tells which. Without `hf`, the folder goes to the Trash.
    public static func movesFiles(_ action: Action, hfInstalled: Bool = true) -> Bool {
        switch action {
        case .removeContents, .removeArtifact, .removeCacheFolderContents, .removeRuntime, .removeArchive,
             .removeOldTestBrowsers, .removeServiceWorkerSite, .removeServiceWorkerStorage, .removeBrowserCaches,
             .removeUpdateDownloads, .removeDeviceSupport, .removeOldLogs, .removeInstaller:
            return true
        case .agent(let agent):
            switch agent {
            case .removeCodexRuntime, .removeOldClaudeVersions, .removeOldClaudeDesktopRuntimes, .removeClaudeVMBundle,
                 .removeAgentCaches, .removeEditorCaches, .removeObsoleteExtensions, .removeLocalModel,
                 .removeFixedFolders, .removeOldSessions:
                return true
            case .removeHuggingFaceRepo:
                return !hfInstalled
            case .removeOllamaModel:
                return false
            }
        case .owner, .docker, .simulator, .globalPackage, .brew, .emptyTrash, .inform:
            return false
        }
    }

    /// True when `url` is in a Trash folder: `~/.Trash`, or the `.Trashes` folder of a volume.
    /// An item that is already there is never moved again.
    public static func isInTrash(_ url: URL, home: String) -> Bool {
        for path in [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path] {
            let trash = home + "/.Trash"
            if path == trash || path.hasPrefix(trash + "/") { return true }
            if path.split(separator: "/").contains(".Trashes") { return true }
        }
        return false
    }
}

/// Why an item could not go to the Trash. The text is for the report.
public enum TrashProblem: Error, Equatable, LocalizedError, Sendable {
    case alreadyInTrash
    case noTrashOnVolume
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyInTrash: return "It is already in the Trash. It was not moved"
        case .noTrashOnVolume: return "This disk has no Trash, so the item was not moved. It stays"
        case .failed(let detail): return "Could not move it to the Trash: \(detail)"
        }
    }
}

public enum TrashMover {
    /// Moves one item to the Trash with the system call. It never deletes and never runs a tool.
    /// The error of the system is turned into a `TrashProblem` by `classify`. A disk with no Trash (some external disks) is `noTrashOnVolume`.
    public static func move(_ url: URL) throws {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
    }

    /// Turns the error of the system into a reason. Tests call this with made-up errors.
    static func classify(_ error: Error) -> TrashProblem {
        if let problem = error as? TrashProblem { return problem }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.featureUnsupported.rawValue { return .noTrashOnVolume }
        return .failed(ns.localizedDescription)
    }
}

/// The words about the delete mode: in the dialog before a clean, and in the report after it.
/// Simple English. Tests check the words.
public enum DeleteModeText {
    /// The line that tells the user when the space is free.
    public static let notFreeYet = "The space is not free yet. It is free when you empty the Trash."

    /// The items that the mode matters for. The Trash item and information lines are left out.
    private static func relevant(_ findings: [Finding]) -> [Finding] {
        findings.filter { if case .emptyTrash = $0.action { return false }; if case .inform = $0.action { return false }; return true }
    }

    private static func split(_ findings: [Finding], _ hf: Bool) -> (files: Bool, tools: Bool) {
        let list = relevant(findings)
        return (list.contains { DeleteMode.movesFiles($0.action, hfInstalled: hf) },
                list.contains { !DeleteMode.movesFiles($0.action, hfInstalled: hf) })
    }

    /// The paragraph of the confirm dialog in trash mode. It names the mode, and says what happens to the space.
    /// In permanent mode (the default) it is empty: the dialogs keep their old text.
    public static func note(mode: DeleteMode, findings: [Finding], hfInstalled: Bool = true) -> String {
        guard mode == .trash else { return "" }
        let (files, tools) = split(findings, hfInstalled)
        guard files || tools else { return "" }
        var parts = ["Delete mode: move to the Trash."]
        if files {
            parts.append("Trash Panda moves the files to the Trash. You can put them back. \(notFreeYet)")
        }
        if tools {
            parts.append(files
                ? "An item that a tool removes (for example Docker or Homebrew) does not go to the Trash. The tool removes it for good."
                : "This item is not a file. A tool removes it for good. It does not go to the Trash.")
        }
        return parts.joined(separator: " ")
    }

    /// The text of the dialog under the body. In trash mode, a file can be put back, so the words "can't be undone",
    /// "for good", and "does not go to the Trash" are taken out when a file is in the list.
    public static func footer(_ footer: String, mode: DeleteMode, findings: [Finding], hfInstalled: Bool = true) -> String {
        guard mode == .trash, split(findings, hfInstalled).files else { return footer }
        return footer
            .replacingOccurrences(of: "The file is deleted for good. It does not go to the Trash. If you need it again, download it again. This can't be undone.",
                                  with: "The file goes to the Trash. If you need it again, put it back from the Trash or download it again.")
            .replacingOccurrences(of: "This can't be undone, but your tools will rebuild what they need.",
                                  with: "Your tools will rebuild what they need.")
            .replacingOccurrences(of: " This can't be undone.", with: "")
    }

    /// The text of the confirm button when the caller gave none. Trash mode never says "Free up" for bytes that only move.
    public static func confirmTitle(mode: DeleteMode, bytes: Int64, findings: [Finding], hfInstalled: Bool = true) -> String {
        let size = ByteText.string(bytes)
        guard mode == .trash else { return "Free up \(size)" }
        switch split(findings, hfInstalled) {
        case (true, false): return "Move \(size) to the Trash"
        case (true, true): return "Clean \(size)"
        default: return "Free up \(size)"
        }
    }

    /// The title of the dialog. The bulk dialogs say "Free up 3 GB?". In trash mode, files say "Move ... to the Trash?",
    /// and a list with files and tool items says "Clean ...?". A list of tool items only keeps "Free up", because a tool frees the space.
    public static func title(_ title: String, mode: DeleteMode, findings: [Finding], hfInstalled: Bool = true) -> String {
        guard mode == .trash, title.hasPrefix("Free up "), title.hasSuffix("?") else { return title }
        let rest = title.dropFirst("Free up ".count).dropLast()
        switch split(findings, hfInstalled) {
        case (true, false): return "Move \(rest) to the Trash?"
        case (true, true): return "Clean \(rest)?"
        default: return title
        }
    }

    /// The text of a menu row for a bulk clean, for example "Free up 3 GB…". In trash mode a row says "Clean": its list can hold files
    /// that only move to the Trash, and the space of those is not free.
    public static func bulkRow(_ size: String, mode: DeleteMode) -> String {
        mode == .trash ? "Clean \(size)…" : "Free up \(size)…"
    }

    /// The button of the dialog that quits an open app first.
    public static func quitAndClean(apps: String, bytes: Int64, finding: Finding, mode: DeleteMode) -> String {
        let size = ByteText.string(bytes)
        if mode == .trash, DeleteMode.movesFiles(finding.action) { return "Quit \(apps) and move \(size) to the Trash" }
        return "Quit \(apps) and free \(size)"
    }

    /// The short text in the menu bar after a clean.
    public static func flash(_ report: CleanReport) -> String {
        if report.deleteMode == .trash {
            if report.movedToTrash > 0 { return "Moved \(ByteText.string(report.movedToTrash)) to Trash" }
            return report.freed > 0 ? "Freed \(ByteText.string(report.freed))" : "Nothing moved"
        }
        return report.freed > 0 ? "Freed \(ByteText.string(report.freed))" : "Nothing to free"
    }
}
