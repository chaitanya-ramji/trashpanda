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

    public var label: String {
        switch self {
        case .seconds: return "Comes back in seconds"
        case .minutes: return "Rebuilds in a few minutes"
        case .download: return "Downloads again when needed"
        }
    }
}

/// Language or tool group. Phase 1 groups ship now. Phase 2 groups are planned.
public enum Ecosystem: String, CaseIterable, Sendable {
    case swift, javascript, python, jvm, dotnet, cpp, go, rust, php, ruby, dart, elixir, homebrew, docker

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
        case .homebrew: return "Homebrew"
        case .docker: return "Docker"
        }
    }
}

/// Fixed commands that the owning tool runs. We never run free-form commands.
public enum OwnerCommand: String, Sendable, CaseIterable {
    case simctlDeleteUnavailable
    case dockerBuilderPrune
    case brewCleanup
    case uvCacheClean
    case goCleanCache
    case goCleanModcache

    public var toolName: String {
        switch self {
        case .simctlDeleteUnavailable: return "xcrun"
        case .dockerBuilderPrune: return "docker"
        case .brewCleanup: return "brew"
        case .uvCacheClean: return "uv"
        case .goCleanCache, .goCleanModcache: return "go"
        }
    }

    public var arguments: [String] {
        switch self {
        case .simctlDeleteUnavailable: return ["simctl", "delete", "unavailable"]
        case .dockerBuilderPrune: return ["builder", "prune", "-f"]
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

public enum Action: Sendable {
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

    public init(id: String, ecosystem: Ecosystem, title: String, location: String, bytes: Int64,
                tier: Tier, rebuild: Rebuild, action: Action, lastActivity: Date? = nil) {
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

    public var reclaimable: Int64 { findings.filter { $0.tier == .safe }.reduce(0) { $0 + $1.bytes } }
    public var reviewable: Int64 { findings.filter { $0.tier == .review }.reduce(0) { $0 + $1.bytes } }

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
    public init() {}
}
