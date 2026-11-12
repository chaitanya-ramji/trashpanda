import Foundation

/// The words of the dialog that asks the user to confirm one delete.
/// It lives in the core, so that tests can check the wording and the default button of each kind.
public struct Confirmation: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Text under the body. When nil, the dialog uses `defaultFooter`.
    public let footer: String?
    /// Text of the confirm button. When nil, it says "Free up <size>".
    public let confirmTitle: String?
    /// When true, the first (default) button keeps the item, so the Return key cannot delete it.
    public let cancelIsDefault: Bool

    public static let defaultFooter =
        "Your code and settings are not touched. This can't be undone, but your tools will rebuild what they need."

    /// What kind of thing the item is decides how careful the dialog is.
    public enum Kind: Equatable, Sendable, CaseIterable {
        case ordinary
        case container
        case volume
        case simulatorRuntime
        case simulatorDevice
        case archive
        case deviceSupport
        case serviceWorker
        case trash
        case installer
        case oldLogs
        case brewPackage
        case agentRuntime
        case vmBundle
        case localModel
        case agentSessions
        case globalPackage
        case runtime
        case cacheFolder
        case containerWithVolumes
        case runningContainer
        case worktree
        case worktreeRecords
    }

    public static func kind(of f: Finding) -> Kind {
        switch f.action {
        case .worktree(.remove): return .worktree
        case .worktree(.prune): return .worktreeRecords
        case .docker(.removeContainer): return .container
        case .docker(.removeVolume): return .volume
        case .docker(.removeStoppedContainerWithVolumes): return .containerWithVolumes
        case .docker(.stopAndRemoveContainerWithVolumes): return .runningContainer
        case .simulator(.deleteRuntime): return .simulatorRuntime
        case .simulator(.deleteDevice): return .simulatorDevice
        case .removeArchive: return .archive
        case .removeDeviceSupport: return .deviceSupport
        case .removeServiceWorkerStorage, .removeServiceWorkerSite: return .serviceWorker
        case .globalPackage: return .globalPackage
        case .removeRuntime: return .runtime
        case .removeCacheFolderContents: return .cacheFolder
        case .emptyTrash: return .trash
        case .removeInstaller: return .installer
        case .removeOldLogs: return .oldLogs
        case .brew: return .brewPackage
        case .agent(.removeCodexRuntime) where f.tier == .review: return .agentRuntime
        case .agent(.removeOldClaudeDesktopRuntimes): return .agentRuntime
        case .agent(.removeClaudeVMBundle): return .vmBundle
        case .agent(.removeOldSessions): return .agentSessions
        case .agent(.removeOllamaModel), .agent(.removeHuggingFaceRepo), .agent(.removeLocalModel): return .localModel
        default: return .ordinary
        }
    }

    /// A cache folder of iCloud or macOS, which the dialog warns about.
    private static func isSystemCache(_ f: Finding) -> Bool {
        if case .removeCacheFolderContents(let name) = f.action { return CacheExplorer.keepReason(name) != nil }
        return false
    }

    public static func forOne(_ f: Finding, staleDays: Int, now: Date = Date()) -> Confirmation {
        let detail = "\(f.title)\n\(f.location)"
        switch kind(of: f) {
        case .worktree:
            return Confirmation(
                title: "Remove this git worktree?", body: "\(f.title)\n\(f.location)\n\(ByteText.string(f.bytes))\n\(f.note ?? "")",
                footer: "Git removes the folder of this worktree with git worktree remove. It never forces the removal, so git refuses when the worktree has changes or a lock. Files that git ignores are deleted too. The branch stays. The main checkout and your other worktrees are not touched. Trash Panda reads the state again just before it removes the folder, but a tool such as Claude Code or Codex can still want this folder. This can't be undone. You can make a new worktree from the branch.",
                confirmTitle: "Remove worktree", cancelIsDefault: true)
        case .worktreeRecords:
            return Confirmation(
                title: "Delete the records of missing worktrees?", body: "\(f.title)\n\(f.location)",
                footer: "The folders of these worktrees are gone. Git deletes only its own records of them, with git worktree prune. No file of a project is touched, and no branch is deleted. This can't be undone.",
                confirmTitle: "Delete records", cancelIsDefault: true)
        case .volume:
            return Confirmation(
                title: "Delete this volume?", body: detail,
                footer: "Databases and files inside a volume are lost for good. If it holds a database, export it first. This can't be undone.",
                confirmTitle: "Delete volume", cancelIsDefault: true)
        case .runningContainer:
            return Confirmation(
                title: "Stop and delete this running container?", body: "\(detail)\n\(ByteText.string(f.bytes)) in all",
                footer: "It is running now. Trash Panda stops it with docker stop, which asks it to shut down and waits, and then deletes it and the volumes that only it uses. Programs and databases that use it stop working now. A volume can hold a database: export it first (for Postgres, with pg_dump). This can't be undone.",
                confirmTitle: "Stop and delete", cancelIsDefault: true)
        case .containerWithVolumes:
            return Confirmation(
                title: "Delete this container and its volumes?", body: "\(detail)\n\(ByteText.string(f.bytes)) in all",
                footer: "The container and its volumes are deleted for good. A volume can hold a database. If it does, export it first (for a Postgres database, with pg_dump). Docker keeps the images. This can't be undone.",
                confirmTitle: "Delete container and volumes", cancelIsDefault: true)
        case .container:
            return Confirmation(
                title: "Remove this container?", body: "\(detail)\n\(f.rebuild.label).",
                footer: "A container can hold data that is stored nowhere else. This can't be undone.",
                confirmTitle: "Remove", cancelIsDefault: true)
        case .simulatorDevice:
            return Confirmation(
                title: "Delete this simulator?", body: detail,
                footer: "Apps and data inside it are deleted. You can create a new simulator in Xcode. This can't be undone.",
                confirmTitle: "Delete simulator", cancelIsDefault: true)
        case .simulatorRuntime:
            return Confirmation(
                title: "Remove this simulator runtime?", body: detail,
                footer: "Simulators that use it stop working. You can download it again in Xcode Settings. This can't be undone.",
                confirmTitle: "Remove runtime", cancelIsDefault: false)
        case .archive:
            return Confirmation(
                title: "Delete this archive?", body: detail,
                footer: "An archive holds the symbol files (dSYMs) that you need to read crash reports of a build that you shipped. This can't be undone.",
                confirmTitle: "Delete archive", cancelIsDefault: true)
        case .serviceWorker:
            return Confirmation(
                title: "Remove saved website data?", body: detail,
                footer: "Websites that work offline keep their files here. After this, such a site may not open without a network until you visit it online again. This can't be undone.",
                confirmTitle: "Remove data", cancelIsDefault: true)
        case .cacheFolder where isSystemCache(f):
            return Confirmation(
                title: "Empty this system cache?", body: "\(f.title)\n\(f.location)\n\(ByteText.string(f.bytes))\n\(f.note ?? "")",
                footer: "This folder belongs to iCloud or to macOS. They build the files again, and that can take a while. Data that is not synced yet can be lost, and a system service may need a restart. Trash Panda cannot check this for you. This can't be undone.",
                confirmTitle: "Empty system cache", cancelIsDefault: true)
        case .cacheFolder:
            return Confirmation(
                title: "Empty this cache folder?", body: "\(f.title)\n\(f.location)\n\(ByteText.string(f.bytes))\n\(f.owner.map { "App: \($0.name)" } ?? "App: not known")",
                footer: "Apps can download the files in a cache folder again. Trash Panda does not know what this one holds: an app may sign you out, lose offline files, or be slow the first time. Quit the app first. The folder stays, and its contents are deleted. This can't be undone.",
                confirmTitle: "Empty folder", cancelIsDefault: true)
        case .runtime:
            return Confirmation(
                title: "Remove this runtime version?", body: "\(f.title)\n\(f.location)\n\(ByteText.string(f.bytes))",
                footer: "It is not the default, and no scanned project asks for it. A script, an editor, or a project outside the scanned folders can still use it. You can install it again with the version manager. This can't be undone.",
                confirmTitle: "Remove version", cancelIsDefault: true)
        case .globalPackage:
            return Confirmation(
                title: "Uninstall this global package?", body: "\(f.title)\n\(f.location)\n\(ByteText.string(f.bytes))",
                footer: "The package manager removes it. A program that calls this tool, for example an MCP server that an AI app starts, stops working. You can install it again. Your projects are not touched.",
                confirmTitle: "Uninstall", cancelIsDefault: true)
        case .agentSessions:
            return Confirmation(
                title: "Delete old sessions?", body: "\(f.title)\n\(f.location)\n\(ByteText.string(f.bytes))",
                footer: "You can no longer resume these conversations, and the tool may still list them. Only sessions older than the limit are deleted. This can't be undone.",
                confirmTitle: "Delete sessions", cancelIsDefault: true)
        case .localModel:
            return Confirmation(
                title: "Remove this model?", body: "\(f.title)\n\(ByteText.string(f.bytes))",
                footer: "The model is downloaded again when you need it, and that can take a while. If it shares layers with another model, those layers stay. This can't be undone.",
                confirmTitle: "Remove model", cancelIsDefault: true)
        case .vmBundle:
            return Confirmation(
                title: "Remove the Cowork VM?", body: "\(f.title)\n\(f.location)\n\(ByteText.string(f.bytes)) on your Mac",
                footer: "Claude downloads the VM again the next time it needs it. Files that Cowork saved inside the VM are lost. Try Settings, Storage in Claude first. This can't be undone.",
                confirmTitle: "Remove VM", cancelIsDefault: true)
        case .agentRuntime:
            return Confirmation(
                title: "Remove this downloaded runtime?", body: "\(f.title)\n\(f.location)\n\(f.note ?? "")",
                footer: "The app downloads it again the next time it needs it. This can't be undone.",
                confirmTitle: "Remove runtime", cancelIsDefault: true)
        case .brewPackage:
            return Confirmation(
                title: "Uninstall this package?", body: "\(f.title)\n\(f.location)",
                footer: "Homebrew removes the package. It refuses when another package needs it. You can install it again with brew install. Your own settings stay.",
                confirmTitle: "Uninstall", cancelIsDefault: true)
        case .oldLogs:
            return Confirmation(
                title: "Delete these old log files?", body: "\(f.title)\n\(f.location)",
                footer: "Only files older than \(OldLogs.minimumAgeDays) days are deleted. Newer files stay, and so does the log of Trash Panda. Keep crash reports if you are looking for a crash. This can't be undone.",
                confirmTitle: "Delete files", cancelIsDefault: true)
        case .installer:
            return Confirmation(
                title: "Delete this installer?", body: detail,
                footer: "The file is deleted for good. It does not go to the Trash. If you need it again, download it again. This can't be undone.",
                confirmTitle: "Delete installer", cancelIsDefault: true)
        case .trash:
            return Confirmation(
                title: "Empty the Trash?", body: "\(ByteText.string(f.bytes)) in your Trash",
                footer: "Finder deletes everything in the Trash for good. The first time, macOS asks if Trash Panda may control Finder. This can't be undone.",
                confirmTitle: "Empty Trash", cancelIsDefault: true)
        case .deviceSupport:
            return Confirmation(
                title: "Remove these device support files?", body: detail,
                footer: "Xcode copies them from the device again the next time you connect it. This can't be undone.",
                confirmTitle: "Remove files", cancelIsDefault: false)
        case .ordinary:
            var text = "\(f.title)\n\(f.rebuild.label)."
            if case .removeArtifact = f.action, f.tier == .review, let d = f.lastActivity {
                let days = max(0, Int(now.timeIntervalSince(d) / 86_400))
                if days < staleDays { text += " You worked on this project \(days == 0 ? "today" : "\(days) days ago")." }
            }
            if f.sizeIsUpperLimit, case .owner(let command) = f.action, command == .brewCleanup || command == .simctlDeleteUnavailable {
                // The tool decides what it removes. Say so, and show the size as the estimate that it is.
                if let note = f.note { text += " \(note)" }
                return Confirmation(title: "Clean up, \(f.sizeText)?", body: text, footer: nil,
                                    confirmTitle: "Clean up", cancelIsDefault: false)
            }
            return Confirmation(title: "Free up \(ByteText.string(f.bytes))?", body: text, footer: nil,
                                confirmTitle: nil, cancelIsDefault: false)
        }
    }
}
