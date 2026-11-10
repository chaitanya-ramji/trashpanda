import Foundation
import PandaCore

/// Made-up scan results for screenshots (`trashpanda --demo light` or `--demo dark`).
/// They contain no real project names. Demo mode never scans and never deletes.
enum DemoData {
    /// One made-up item for `--demo light --dialog volume|container|safe`. It is used to check the wording.
    static func dialogFinding(_ kind: String) -> Finding? {
        let place = "Docker engine: OrbStack"
        switch kind {
        case "volume":
            return Finding(id: "v", ecosystem: .docker, title: "Unused volume · scratch_data",
                           location: "\(place) · no container uses it", bytes: 40_000_000, tier: .review,
                           rebuild: .never, action: .docker(.removeVolume(name: "scratch_data")))
        case "container":
            return Finding(id: "c", ecosystem: .docker, title: "Stopped container · old-db",
                           location: "\(place) · image postgres:17 · Exited (0) 4 months ago", bytes: 217_000,
                           tier: .review, rebuild: .recreate, action: .docker(.removeContainer(id: "0123456789ab")))
        case "runtime":
            return Finding(id: "r", ecosystem: .swift, title: "Simulator runtime · iOS 17.5",
                           location: "Xcode simulators · build 21F79 · last used 126 days ago · 3 simulators run on it",
                           bytes: 7_000_000_000, tier: .review, rebuild: .download,
                           action: .simulator(.deleteRuntime(id: "11111111-1111-1111-1111-111111111111")))
        case "device":
            return Finding(id: "d", ecosystem: .swift, title: "Simulator · iPhone 15 (iOS 17.5)",
                           location: "Xcode simulators · not started for 303 days", bytes: 800_000_000, tier: .review,
                           rebuild: .recreate, action: .simulator(.deleteDevice(udid: "22222222-2222-2222-2222-222222222222")))
        case "archive":
            return Finding(id: "a", ecosystem: .swift, title: "Archive · MyApp 5-1-26, 10.00 AM",
                           location: "~/Library/Developer/Xcode/Archives/2026-05-01/MyApp 5-1-26, 10.00 AM.xcarchive · archived 192 days ago",
                           bytes: 1_800_000_000, tier: .review, rebuild: .recreate,
                           action: .removeArchive(URL(fileURLWithPath: "/tmp/none.xcarchive")))
        case "trash":
            return Finding(id: "t", ecosystem: .trash, title: "Trash", location: "~/.Trash · Finder empties it",
                           bytes: 5_300_000_000, tier: .review, rebuild: .never, action: .emptyTrash)
        case "safe":
            return Finding(id: "s", ecosystem: .javascript, title: "node_modules · storefront",
                           location: "~/Projects/storefront/node_modules", bytes: 1_300_000_000, tier: .safe,
                           rebuild: .minutes, action: .removeArtifact(URL(fileURLWithPath: "/tmp/none")))
        default: return nil
        }
    }

    static func result() -> ScanResult {
        let ago = { (days: Double) in Date().addingTimeInterval(-days * 86_400) }
        func item(_ id: String, _ eco: Ecosystem, _ title: String, _ bytes: Int64, _ tier: Tier,
                  _ rebuild: Rebuild, place: String = "~/Projects", last: Date? = nil,
                  action: Action = .owner(.brewCleanup), note: String? = nil, help: URL? = nil,
                  owner: AppOwner? = nil) -> Finding {
            Finding(id: id, ecosystem: eco, title: title, location: place, bytes: bytes, tier: tier,
                    rebuild: rebuild, action: action, lastActivity: last, note: note, helpURL: help, owner: owner)
        }
        let dk = "Docker engine: Docker Desktop"
        let xcode = AppOwner(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"])
        let findings: [Finding] = [
            item("1", .swift, "Xcode build data", 4_200_000_000, .safe, .minutes, owner: xcode),
            item("2", .swift, "Unavailable simulators", 2_100_000_000, .safe, .seconds),
            item("3", .swift, "iOS device support · iPhone15,2 17.4 (21E219)", 3_800_000_000, .review, .minutes,
                 action: .removeDeviceSupport(URL(fileURLWithPath: "/tmp/none")), owner: xcode),
            item("27", .swift, "iOS device support · iPhone15,2 18.0 (22A3354) · newest, kept", 4_100_000_000, .review, .minutes,
                 action: .inform),
            item("4", .rust, "Build output · cli-tool", 2_400_000_000, .safe, .minutes, last: ago(90)),
            item("5", .javascript, "node_modules · storefront", 1_300_000_000, .safe, .minutes, last: ago(75)),
            item("6", .javascript, "node_modules · admin-panel", 640_000_000, .safe, .minutes, last: ago(48)),
            item("7", .javascript, "npm cache", 229_000_000, .safe, .download),
            item("8", .javascript, "Build cache · web", 1_500_000_000, .review, .seconds, last: ago(3)),
            item("9", .python, "uv cache", 880_000_000, .safe, .download),
            item("10", .python, "Virtual environment · pipeline", 716_000_000, .review, .minutes, last: ago(9)),
            item("11", .go, "Go build cache", 650_000_000, .safe, .minutes),
            item("12", .docker, "Build cache", 568_000_000, .safe, .minutes, place: dk),
            item("21", .swift, "Simulator runtime · iOS 17.5", 7_000_000_000, .review, .download,
                 place: "Xcode simulators", action: .simulator(.deleteRuntime(id: "11111111-1111-1111-1111-111111111111"))),
            item("22", .swift, "Simulator runtime · watchOS 10.5", 3_200_000_000, .review, .download,
                 place: "Xcode simulators", action: .simulator(.deleteRuntime(id: "44444444-4444-4444-4444-444444444444"))),
            item("23", .swift, "Simulator · iPhone 15 (iOS 17.5)", 800_000_000, .review, .recreate,
                 place: "Xcode simulators", action: .simulator(.deleteDevice(udid: "22222222-2222-2222-2222-222222222222"))),
            item("24", .swift, "Archive · MyApp 5-1-26", 1_800_000_000, .review, .recreate,
                 place: "~/Library/Developer/Xcode/Archives", action: .removeArchive(URL(fileURLWithPath: "/tmp/none.xcarchive"))),
            item("25", .swift, "iOS 27.0 runtime · newest, kept", 9_000_000_000, .review, .download,
                 place: "Xcode simulators", action: .inform),
            item("26", .swift, "iOS 18.2 runtime · in use", 8_000_000_000, .review, .download,
                 place: "Xcode simulators", action: .inform),
            item("30", .browsers, "Browser caches · Arc", 228_000_000, .safe, .download, place: "~/Library/Caches/Arc/User Data"),
            item("14", .docker, "Untagged images", 150_000_000, .safe, .minutes, place: dk),
            item("15", .docker, "Image · web-api:latest", 290_000_000, .review, .download, place: dk),
            item("16", .docker, "Stopped container · old-db", 1_200_000, .review, .recreate, place: dk),
            item("17", .docker, "Unused volume · scratch_data", 40_000_000, .review, .never, place: dk),
            item("18", .docker, "Volume · app_pgdata", 244_000_000, .review, .never, place: "\(dk) · used by 1 container", action: .inform),
            item("19", .docker, "Volume · cache_data", 118_000_000, .review, .never, place: "\(dk) · used by 1 container", action: .inform),
            item("20", .docker, "Docker Desktop disk image", 6_400_000_000, .review, .never, place: dk, action: .inform,
                 note: "Holds 3.0 GB of data. The file can stay large after a clean.", help: DockerDesktopDisk.helpURL),
            item("51", .aiAgents, "Codex · old sessions", 2_400_000_000, .review, .never,
                 place: "212 sessions older than 30 days · the oldest is 140 days old",
                 action: .agent(.removeOldSessions(kind: .codex, olderThan: Date()))),
            item("50", .aiAgents, "Zed · caches and language servers", 380_000_000, .safe, .download,
                 place: "~/Library/Caches/Zed, ~/Library/Application Support/Zed/languages",
                 action: .agent(.removeFixedFolders(appID: "zed")), note: "Your settings, extensions, and chats stay.", owner: FixedFolders.apps[0].owner),
            item("49", .aiAgents, "LM Studio · model lmstudio-community/Llama-3-8B-GGUF", 4_900_000_000, .review, .download,
                 place: "~/.lmstudio/models", action: .agent(.removeLocalModel(storeID: "lmstudio", name: "lmstudio-community/Llama-3-8B-GGUF")),
                 note: "Downloaded again when you need it. Your chats and settings stay."),
            item("48", .aiAgents, "Hugging Face · model mistralai/Mistral-7B-v0.1", 14_500_000_000, .review, .download,
                 place: "~/.cache/huggingface/hub · downloaded 88 days ago",
                 action: .agent(.removeHuggingFaceRepo(id: "model/mistralai/Mistral-7B-v0.1")), note: "Downloaded again when you need it."),
            item("47", .aiAgents, "Ollama · model llama3:70b", 39_000_000_000, .review, .download,
                 place: "Ollama · pulled 120 days ago · layers that other models share stay",
                 action: .agent(.removeOllamaModel(name: "llama3:70b")), note: "Downloaded again when you need it."),
            item("46", .aiAgents, "VS Code · editor caches", 410_000_000, .safe, .download,
                 place: "~/Library/Application Support/Code · 9 cache folders, 4 old logs · settings and chats stay",
                 action: .agent(.removeEditorCaches(appID: "vscode")), owner: EditorCaches.vscodeOwner),
            item("45", .aiAgents, "Claude · app caches", 290_000_000, .safe, .download,
                 place: "~/Library/Application Support/Claude · 9 cache folders · logins and chats stay",
                 action: .agent(.removeAgentCaches(appID: "claude")), owner: AgentOwners.claudeDesktop),
            item("43", .aiAgents, "Claude · old Desktop runtimes", 263_000_000, .review, .download,
                 place: "~/Library/Application Support/Claude · claude-code 2.1.309 · the newest of each stays",
                 action: .agent(.removeOldClaudeDesktopRuntimes(names: ["claude-code/2.1.309"])), owner: AgentOwners.claudeDesktop),
            item("44", .aiAgents, "Claude · Cowork VM", 9_800_000_000, .review, .download,
                 place: "~/Library/Application Support/Claude/vm_bundles", action: .agent(.removeClaudeVMBundle),
                 note: "Claude downloads about 10 GB again when it needs it. Settings, Storage in Claude removes old tasks first.",
                 help: ClaudeDesktop.changelogURL, owner: AgentOwners.claudeDesktop),
            item("42", .aiAgents, "Claude · old Code versions", 573_000_000, .safe, .download,
                 place: "~/.local/share/claude/versions · 2 older versions · 2.1.321 stays",
                 action: .agent(.removeOldClaudeVersions(names: ["2.1.314"]))),
            item("40", .aiAgents, "Codex · leftover runtime install", 1_900_000_000, .safe, .download,
                 place: "~/.cache/codex-runtimes/codex-runtime-install-odLBYG · 1 days old",
                 action: .agent(.removeCodexRuntime(URL(fileURLWithPath: "/tmp/none"))), owner: AgentOwners.codex),
            item("41", .aiAgents, "Codex · downloaded runtime", 1_600_000_000, .review, .download,
                 place: "~/.cache/codex-runtimes/codex-primary-runtime",
                 action: .agent(.removeCodexRuntime(URL(fileURLWithPath: "/tmp/none2"))),
                 note: "The app downloads it again (about 1.7 GB). Document and spreadsheet tools stop until then.", owner: AgentOwners.codex),
            item("34", .homebrew, "Package · ffmpeg", 910_000_000, .review, .download,
                 place: "Nothing else needs it · installed 412 days ago", action: .brew(.uninstall(name: "ffmpeg"))),
            item("33", .logs, "Old logs", 310_000_000, .review, .never, place: "~/Library/Logs · 1,204 files older than 30 days",
                 action: .removeOldLogs(.logs)),
            item("32", .installers, "Installer · Docker-4.30.dmg", 720_000_000, .review, .download, place: "~/Downloads/Docker-4.30.dmg · 142 days old",
                 action: .removeInstaller(URL(fileURLWithPath: "/tmp/none.dmg"))),
            item("31", .trash, "Trash", 5_300_000_000, .review, .never, place: "~/.Trash · Finder empties it", action: .emptyTrash),
            item("13", .homebrew, "Old downloads and versions", 412_000_000, .safe, .download),
        ]
        return ScanResult(findings: findings.sorted { $0.bytes > $1.bytes },
                          disk: DiskUsage(total: 245_000_000_000, free: 61_000_000_000))
    }
}
