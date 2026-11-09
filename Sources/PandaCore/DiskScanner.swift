import Foundation

/// User settings from ~/.config/trashpanda. Both files hold one path per line.
/// `keep` lists paths that we never touch. `roots` adds project folders to search.
public struct Config: Sendable {
    public var keep: [String]
    public var roots: [String]

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Config {
        func lines(_ name: String) -> [String] {
            let url = home.appendingPathComponent(".config/trashpanda/\(name)")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
                return line.hasPrefix("~") ? home.path + line.dropFirst() : line
            }
        }
        return Config(keep: lines("keep"), roots: lines("roots"))
    }

    public init(keep: [String] = [], roots: [String] = []) {
        self.keep = keep
        self.roots = roots
    }
}

public final class DiskScanner {
    public let home: URL
    public let config: Config
    public let guardian: PathGuard

    /// Items smaller than 1 MB are not shown.
    static let minimumBytes: Int64 = 1_000_000

    static let defaultRootNames = [
        "Developer", "dev", "Projects", "Code", "GitHub", "Repos", "Workspace", "Development", "src", "work", "www",
    ]

    /// When false, the scan never runs brew, docker, go, uv, or xcrun. Tests use this.
    public let useOwnerTools: Bool
    /// Path of the docker tool. Tests set it to a fake tool. The default finds the real one.
    private let dockerOverride: String?
    private let isSocket: (String) -> Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, config: Config = .load(),
                useOwnerTools: Bool = true, dockerPath: String? = nil,
                isSocket: @escaping (String) -> Bool = DockerEngine.isUnixSocket) {
        self.home = home
        self.config = config
        self.guardian = PathGuard(home: home, keep: config.keep)
        self.useOwnerTools = useOwnerTools
        self.dockerOverride = dockerPath
        self.isSocket = isSocket
    }

    /// The local Docker engine, or the reason that the app does not use Docker.
    public func dockerEngine() -> Result<DockerEngine, DockerRefusal> {
        DockerEngine.detect(dockerPath: dockerOverride ?? Shell.resolve("docker"), home: home, isSocket: isSocket)
    }

    public func scan() -> ScanResult {
        let started = Date()
        Log.info("scan start (owner tools: \(useOwnerTools))")
        var findings: [Finding] = []
        let lock = NSLock()
        func add(_ f: [Finding]) { lock.lock(); findings.append(contentsOf: f); lock.unlock() }

        var jobs: [() -> Void] = [
            { add(self.scanCaches()) },
            { add(self.scanProjects()) },
        ]
        if useOwnerTools {
            jobs += [
                { add(self.scanSimulators()) },
                { add(self.scanHomebrew()) },
                { add(self.scanDocker()) },
                { add(self.scanGo()) },
                { add(self.scanUv()) },
            ]
        }
        DispatchQueue.concurrentPerform(iterations: jobs.count) { jobs[$0]() }

        // Tiny items add noise to the menu and free almost nothing.
        let sorted = findings.filter { $0.bytes >= Self.minimumBytes }.sorted { $0.bytes > $1.bytes }
        let result = ScanResult(findings: sorted, disk: DiskUsage.current(for: home))
        for f in sorted {
            Log.info("found [\(f.tier == .safe ? "safe" : "review")] \(f.id) \(f.bytes) bytes — \(f.location)")
        }
        Log.info(String(format: "scan done in %.1fs: %d items, safe %lld bytes, review %lld bytes, free %lld of %lld",
                        Date().timeIntervalSince(started), sorted.count, result.reclaimable, result.reviewable,
                        result.disk.free, result.disk.total))
        return result
    }

    /// Measures an item again after a clean. The result is what is still on disk.
    /// For tools that keep their own files, we ask the tool again instead of counting a folder.
    public func remainingBytes(of finding: Finding) -> Int64 {
        switch finding.action {
        case .removeContents(let url), .removeArtifact(let url):
            return FileManager.default.fileExists(atPath: url.path) ? Sizer.size(of: url, exclusiveOnly: true) : 0
        case .owner(let command):
            switch command {
            case .brewCleanup: return brewReclaimableBytes()
            case .dockerBuilderPrune: return dockerBuildCacheBytes()
            case .simctlDeleteUnavailable: return scanSimulators().first?.bytes ?? 0
            case .uvCacheClean:
                return FileManager.default.fileExists(atPath: finding.location)
                    ? Sizer.size(of: URL(fileURLWithPath: finding.location)) : 0
            case .goCleanCache, .goCleanModcache:
                return Sizer.size(of: URL(fileURLWithPath: finding.location))
            }
        }
    }

    // MARK: Fixed cache folders

    func scanCaches() -> [Finding] {
        var out: [Finding] = []
        for spec in Catalog.caches {
            for rel in spec.paths {
                let url = home.appendingPathComponent(rel, isDirectory: true)
                guard FileManager.default.fileExists(atPath: url.path), guardian.check(url) == nil else { continue }
                let bytes = Sizer.size(of: url)
                guard bytes > 0 else { continue }
                out.append(Finding(id: "\(spec.id):\(rel)", ecosystem: spec.ecosystem, title: spec.title,
                                   location: url.path, bytes: bytes, tier: spec.tier, rebuild: spec.rebuild,
                                   action: .removeContents(url)))
            }
        }
        return out
    }

    // MARK: Owner-tool items

    func scanSimulators() -> [Finding] {
        let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        guard FileManager.default.fileExists(atPath: devices.path),
              let xcrun = Shell.resolve("xcrun") else { return [] }
        let r = Shell.run(xcrun, ["simctl", "list", "devices", "unavailable", "-j"], timeout: 20)
        guard r.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
              let groups = json["devices"] as? [String: [[String: Any]]] else { return [] }
        var bytes: Int64 = 0
        for (_, list) in groups {
            for device in list {
                if let udid = device["udid"] as? String, udid.range(of: "^[0-9A-Fa-f-]{36}$", options: .regularExpression) != nil {
                    bytes += Sizer.size(of: devices.appendingPathComponent(udid))
                }
            }
        }
        guard bytes > 0 else { return [] }
        return [Finding(id: "xcode.sim.unavailable", ecosystem: .swift, title: "Unavailable simulators",
                        location: devices.path, bytes: bytes, tier: .safe, rebuild: .seconds,
                        action: .owner(.simctlDeleteUnavailable))]
    }

    /// Homebrew keeps its own index (`api`) and Ruby cache (`bootsnap`) in the cache folder.
    /// `brew cleanup` never removes them, so a folder size would be wrong. We ask brew what it would free.
    func scanHomebrew() -> [Finding] {
        let bytes = brewReclaimableBytes()
        guard bytes > 0 else { return [] }
        let cache = home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
        return [Finding(id: "brew.cleanup", ecosystem: .homebrew, title: "Old downloads and versions",
                        location: cache.path, bytes: bytes, tier: .safe, rebuild: .download,
                        action: .owner(.brewCleanup))]
    }

    func brewReclaimableBytes() -> Int64 {
        guard let brew = Shell.resolve("brew") else { return 0 }
        let r = Shell.run(brew, ["cleanup", "--prune=all", "-n"], timeout: 60)
        return r.status == 0 ? Self.parseBrewFreed(r.stdout) : 0
    }

    /// Reads "==> This operation would free approximately 12.3MB of disk space."
    static func parseBrewFreed(_ output: String) -> Int64 {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("would free approximately") }),
              let range = line.range(of: "approximately ") else { return 0 }
        let token = line[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
        return parseDockerSize(token) ?? 0
    }

    func scanDocker() -> [Finding] {
        guard case .success(let engine) = dockerEngine() else { return [] }
        let bytes = dockerBuildCacheBytes(engine)
        guard bytes > 0 else { return [] }
        return [Finding(id: "docker.buildcache", ecosystem: .docker, title: "Build cache",
                        location: "Docker engine: \(engine.kind)", bytes: bytes, tier: .safe, rebuild: .minutes,
                        action: .owner(.dockerBuilderPrune))]
    }

    func dockerBuildCacheBytes() -> Int64 {
        guard case .success(let engine) = dockerEngine() else { return 0 }
        return dockerBuildCacheBytes(engine)
    }

    private func dockerBuildCacheBytes(_ engine: DockerEngine) -> Int64 {
        let r = engine.run(["system", "df", "--format", "{{json .}}"], timeout: 8)
        guard r.status == 0 else { return 0 }
        for line in r.stdout.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["Type"] as? String == "Build Cache",
                  let text = obj["Reclaimable"] as? String else { continue }
            return Self.parseDockerSize(text) ?? 0
        }
        return 0
    }

    func scanGo() -> [Finding] {
        let hasGo = Shell.resolve("go") != nil
        var out: [Finding] = []
        let build = home.appendingPathComponent("Library/Caches/go-build", isDirectory: true)
        let bytes = Sizer.size(of: build)
        if bytes > 0 {
            out.append(Finding(id: "go.build", ecosystem: .go, title: "Go build cache", location: build.path,
                               bytes: bytes, tier: .safe, rebuild: .minutes,
                               action: hasGo ? .owner(.goCleanCache) : .removeContents(build)))
        }
        // The module cache is read-only on disk, so only the go tool can remove it.
        let mod = home.appendingPathComponent("go/pkg/mod", isDirectory: true)
        let modBytes = hasGo ? Sizer.size(of: mod) : 0
        if modBytes > 0 {
            out.append(Finding(id: "go.mod", ecosystem: .go, title: "Go module cache", location: mod.path,
                               bytes: modBytes, tier: .review, rebuild: .download,
                               action: .owner(.goCleanModcache)))
        }
        return out
    }

    func scanUv() -> [Finding] {
        var dir = home.appendingPathComponent(".cache/uv", isDirectory: true)
        let uv = Shell.resolve("uv")
        if let uv, case let r = Shell.run(uv, ["cache", "dir"], timeout: 10), r.status == 0 {
            let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { dir = URL(fileURLWithPath: path, isDirectory: true) }
        }
        guard FileManager.default.fileExists(atPath: dir.path), guardian.check(dir) == nil else { return [] }
        let bytes = Sizer.size(of: dir)
        guard bytes > 0 else { return [] }
        return [Finding(id: "uv.cache", ecosystem: .python, title: "uv cache", location: dir.path,
                        bytes: bytes, tier: .safe, rebuild: .download,
                        action: uv != nil ? .owner(.uvCacheClean) : .removeContents(dir))]
    }

    // MARK: Projects

    func scanProjects() -> [Finding] {
        var roots: [URL] = []
        let fm = FileManager.default
        for name in Self.defaultRootNames {
            let url = home.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: url.path) { roots.append(url) }
        }
        for path in config.roots { roots.append(URL(fileURLWithPath: path, isDirectory: true)) }
        var seen = Set<String>()
        roots = roots.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }

        let scanner = ProjectScanner(home: home, roots: roots, guardian: guardian,
                                     activeDirectories: Shell.activeDirectories())
        return scanner.scan()
    }

    // MARK: Helpers

    /// Parses "1.2GB (100%)" or "512kB" from Docker output. Docker uses decimal units.
    static func parseDockerSize(_ text: String) -> Int64? {
        let head = text.split(separator: " ").first.map(String.init) ?? text
        guard let range = head.range(of: "^[0-9.]+", options: .regularExpression),
              let value = Double(head[range]) else { return nil }
        let unit = head[range.upperBound...].lowercased()
        let scale: Double
        switch unit {
        case "b", "": scale = 1
        case "kb": scale = 1_000
        case "mb": scale = 1_000_000
        case "gb": scale = 1_000_000_000
        case "tb": scale = 1_000_000_000_000
        default: return nil
        }
        return Int64(value * scale)
    }
}
