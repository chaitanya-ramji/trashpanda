import Foundation

/// How much we trust an item to be safe to remove without asking.
public enum Tier: Int, Sendable, Comparable {
    /// Cheap to rebuild. Included in "Reclaim".
    case safe = 0
    /// Costly to rebuild, recent, or unclear. The user must choose it.
    case review = 1

    public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
}

/// What it costs to get the item back.
public enum Rebuild: Sendable {
    case seconds
    case minutes
    case download
    /// The item cannot be rebuilt. The user must make it again, for example a container.
    case recreate
    /// The data is gone for good. Used for Docker volumes, which can hold databases.
    case never

    public var label: String {
        switch self {
        case .seconds: return "Comes back in seconds"
        case .minutes: return "Rebuilds in a few minutes"
        case .download: return "Downloads again when needed"
        case .recreate: return "You would need to recreate it"
        case .never: return "Cannot be recovered"
        }
    }
}

/// Language or tool group. Phase 1 groups ship now. Phase 2 groups are planned.
public enum Ecosystem: String, CaseIterable, Sendable {
    case swift, javascript, python, jvm, dotnet, cpp, go, rust, php, ruby, dart, elixir, zig, homebrew, docker, apps, browsers, trash, installers, logs, scala, haskell, r

    /// A short name for places with little room, such as the legend of the bar.
    public var shortName: String {
        switch self {
        case .swift: return "Xcode"
        case .javascript: return "JavaScript"
        case .python: return "Python"
        case .jvm: return "Java"
        case .dotnet: return ".NET"
        case .cpp: return "C/C++"
        case .go: return "Go"
        case .rust: return "Rust"
        case .php: return "PHP"
        case .ruby: return "Ruby"
        case .dart: return "Dart"
        case .elixir: return "Elixir"
        case .zig: return "Zig"
        case .homebrew: return "Homebrew"
        case .docker: return "Docker"
        case .apps: return "Updates"
        case .browsers: return "Browsers"
        case .trash: return "Trash"
        case .installers: return "Installers"
        case .logs: return "Logs"
        case .r: return "R"
        case .haskell: return "Haskell"
        case .scala: return "Scala"
        }
    }

    public var name: String {
        switch self {
        case .swift: return "Xcode & Swift"
        case .javascript: return "JavaScript & TypeScript"
        case .python: return "Python"
        case .jvm: return "Java & Kotlin"
        case .dotnet: return "C# & .NET"
        case .cpp: return "C & C++"
        case .go: return "Go"
        case .rust: return "Rust"
        case .php: return "PHP"
        case .ruby: return "Ruby"
        case .dart: return "Dart & Flutter"
        case .elixir: return "Elixir & Erlang"
        case .zig: return "Zig"
        case .homebrew: return "Homebrew"
        case .docker: return "Docker"
        case .apps: return "App update downloads"
        case .browsers: return "Browser caches"
        case .trash: return "Trash"
        case .installers: return "Old installers"
        case .logs: return "Logs & crash reports"
        case .r: return "R"
        case .haskell: return "Haskell"
        case .scala: return "Scala"
        }
    }
}

/// Fixed commands that the owning tool runs. We never run free-form commands.
public enum OwnerCommand: String, Sendable, CaseIterable {
    case simctlDeleteUnavailable
    case dockerBuilderPrune
    case dockerImagePrune
    case brewCleanup
    case uvCacheClean
    case goCleanCache
    case goCleanModcache

    public var toolName: String {
        switch self {
        case .simctlDeleteUnavailable: return "xcrun"
        case .dockerBuilderPrune, .dockerImagePrune: return "docker"
        case .brewCleanup: return "brew"
        case .uvCacheClean: return "uv"
        case .goCleanCache, .goCleanModcache: return "go"
        }
    }

    public var arguments: [String] {
        switch self {
        case .simctlDeleteUnavailable: return ["simctl", "delete", "unavailable"]
        case .dockerBuilderPrune: return ["builder", "prune", "-f"]
        case .dockerImagePrune: return ["image", "prune", "-f"]
        case .brewCleanup: return ["cleanup", "--prune=all"]
        case .uvCacheClean: return ["cache", "clean"]
        case .goCleanCache: return ["clean", "-cache"]
        case .goCleanModcache: return ["clean", "-modcache"]
        }
    }

    public var timeout: TimeInterval {
        switch self {
        case .brewCleanup, .goCleanModcache: return 300
        default: return 120
        }
    }
}

/// A Docker command for one object. The identifier is checked, and the command has a fixed shape.
/// We never use -f (force) or -v (volumes), so Docker itself refuses to remove something that is in use.
public enum DockerAction: Sendable, Equatable {
    case removeContainer(id: String)
    /// Removes an image by all of its `repository:tag` names. Never forced.
    case removeImage(refs: [String])
    /// Removes one volume that no container uses. Never forced. The data is lost for good.
    case removeVolume(name: String)

    /// The arguments, or nil when the identifier is not valid. A name can hold any text.
    /// We use the hex identifier, and we accept nothing else.
    public var arguments: [String]? {
        switch self {
        case .removeContainer(let id): return Self.isHexID(id) ? ["container", "rm", id] : nil
        case .removeImage(let refs):
            guard !refs.isEmpty, refs.count <= 20, refs.allSatisfy(Self.isImageRef) else { return nil }
            return ["image", "rm"] + refs
        case .removeVolume(let name): return Self.isVolumeName(name) ? ["volume", "rm", name] : nil
        }
    }

    public var timeout: TimeInterval { 60 }

    /// `name:tag`. It starts with a letter or a digit, so it can never look like a flag.
    static func isImageRef(_ ref: String) -> Bool {
        ref.range(of: "^[a-z0-9]([a-z0-9._/:-]*[a-z0-9])?:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$",
                  options: .regularExpression) != nil
    }

    /// Docker volume names start with a letter or a digit. This also keeps a name from looking like a flag.
    static func isVolumeName(_ name: String) -> Bool {
        name.count <= 255 && name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil
    }

    static func isImageID(_ id: String) -> Bool {
        id.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    static func isHexID(_ id: String) -> Bool {
        id.range(of: "^[0-9a-f]{12,64}$", options: .regularExpression) != nil
    }
}

/// A `simctl` command for one runtime or one device. The identifier is checked, and the command has a fixed shape.
/// The bulk forms of the delete command remove more than the list shows. They are never used.
public enum SimulatorAction: Sendable, Equatable {
    /// Deletes one runtime. Xcode shuts down the simulators that run on it, so the cleaner checks first.
    case deleteRuntime(id: String)
    /// Deletes one simulator device and its data.
    case deleteDevice(udid: String)

    /// The arguments after `simctl`, or nil when the identifier is not valid.
    public var arguments: [String]? {
        switch self {
        case .deleteRuntime(let id): return Self.isUUID(id) ? ["runtime", "delete", id] : nil
        case .deleteDevice(let udid): return Self.isUUID(udid) ? ["delete", udid] : nil
        }
    }

    /// A runtime is a disk image that Xcode must unmount first, so it can take a while.
    public var timeout: TimeInterval {
        if case .deleteRuntime = self { return 300 }
        return 60
    }

    static func isUUID(_ text: String) -> Bool {
        text.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
                   options: .regularExpression) != nil
    }
}

public enum Action: Sendable {
    /// One Homebrew formula that no other formula needs. Brew removes it. The cleaner checks it again first.
    case brew(BrewAction)
    /// The old files of one group in `~/Library/Logs`. The cleaner finds the files again from the group.
    case removeOldLogs(OldLogs.Kind)
    /// One `.dmg` or `.pkg` file directly in `~/Downloads`. The cleaner reads its age again before it deletes it.
    case removeInstaller(URL)
    /// The Trash of the user. The cleaner asks Finder to empty it. We never delete those files ourselves.
    case emptyTrash
    /// One simulator runtime or device. The cleaner checks the state again before it runs.
    case simulator(SimulatorAction)
    /// One Xcode archive. It must be `Archives/<date>/<name>.xcarchive` in the home folder.
    case removeArchive(URL)
    /// The old versions of the browsers that one test tool downloaded. The newest of each kind stays.
    case removeOldTestBrowsers(toolID: String)
    /// The Service Worker storage of one browser. Offline web apps keep their files there. Review only.
    case removeServiceWorkerStorage(browserID: String)
    /// The caches of one browser. The cleaner finds the folders again from the browser id, by a fixed list of names.
    case removeBrowserCaches(browserID: String)
    /// The Sparkle folder of an app. The cleaner removes the old update files in it, and nothing else.
    case removeUpdateDownloads(URL)
    /// One folder of device support files. It must be `<platform> DeviceSupport/<name>` in the Xcode folder.
    case removeDeviceSupport(URL)
    /// Information only. Nothing can be deleted. The menu shows it as a line that cannot be chosen.
    case inform
    /// One Docker object. The cleaner checks the engine and the object again before it runs.
    case docker(DockerAction)
    /// Delete everything inside a directory. Keep the directory.
    case removeContents(URL)
    /// Delete one build output directory inside a project.
    case removeArtifact(URL)
    /// Ask the owning tool to clean itself.
    case owner(OwnerCommand)
}

public struct Finding: Identifiable, Sendable {
    public let id: String
    public let ecosystem: Ecosystem
    public let title: String
    public let location: String
    public let bytes: Int64
    public let tier: Tier
    public let rebuild: Rebuild
    public let action: Action
    public let lastActivity: Date?
    /// One short line that the menu shows under the item.
    public let note: String?
    /// A page that explains the item. The menu offers it as a link.
    public let helpURL: URL?
    /// The app that uses this item. The item is not cleaned while the app runs.
    public let owner: AppOwner?

    /// False for an information line. It has no action, so it is not part of any total.
    public var isActionable: Bool {
        if case .inform = action { return false }
        return true
    }

    public init(id: String, ecosystem: Ecosystem, title: String, location: String, bytes: Int64,
                tier: Tier, rebuild: Rebuild, action: Action, lastActivity: Date? = nil,
                note: String? = nil, helpURL: URL? = nil, owner: AppOwner? = nil) {
        self.note = note
        self.helpURL = helpURL
        self.owner = owner
        self.id = id
        self.ecosystem = ecosystem
        self.title = title
        self.location = location
        self.bytes = bytes
        self.tier = tier
        self.rebuild = rebuild
        self.action = action
        self.lastActivity = lastActivity
    }
}

public struct DiskUsage: Sendable {
    public let total: Int64
    public let free: Int64
    public var used: Int64 { max(0, total - free) }

    public init(total: Int64, free: Int64) {
        self.total = total
        self.free = free
    }

    /// Free bytes without purgeable space. This shows real change after a delete. It is for the log only.
    public static func rawFree(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0)
    }

    /// Reads the capacity that Finder shows (includes purgeable space as free).
    public static func current(for url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> DiskUsage {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = try? url.resourceValues(forKeys: keys)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return DiskUsage(total: total, free: free)
    }
}

public struct ScanResult: Sendable {
    public let findings: [Finding]
    public let disk: DiskUsage
    public let date: Date

    public var reclaimable: Int64 { findings.filter { $0.isActionable && $0.tier == .safe }.reduce(0) { $0 + $1.bytes } }
    public var reviewable: Int64 { findings.filter { $0.isActionable && $0.tier == .review }.reduce(0) { $0 + $1.bytes } }

    public init(findings: [Finding], disk: DiskUsage, date: Date = Date()) {
        self.findings = findings
        self.disk = disk
        self.date = date
    }
}

public struct CleanReport: Sendable {
    public var freed: Int64 = 0
    public var removed = 0
    public var skipped: [String] = []
    public var failed: [String] = []
    /// Apps that were running, so that their items were skipped. The user must quit them.
    public var blockedApps: [String] = []
    public init() {}
}
