import Foundation

/// User settings from ~/.config/trashpanda.
/// `keep` and `roots` hold one path per line. `keep` lists paths that we never touch.
/// `roots` adds project folders to search.
/// `settings` holds lines such as `stale_days = 30`.
public struct Config: Sendable {
    public var keep: [String]
    public var roots: [String]
    /// A project that someone changed within this many days is a review item.
    public var staleDays: Int

    public static let defaultStaleDays = 30
    public static let staleDaysRange = 1...3650

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Config {
        func read(_ name: String) -> String? {
            try? String(contentsOf: home.appendingPathComponent(".config/trashpanda/\(name)"), encoding: .utf8)
        }
        func lines(_ name: String) -> [String] {
            guard let text = read(name) else { return [] }
            return text.split(separator: "\n").compactMap { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
                return line.hasPrefix("~") ? home.path + line.dropFirst() : line
            }
        }
        let parsed = parseSettings(read("settings") ?? "")
        for warning in parsed.warnings { Log.warn("settings: \(warning)") }
        Log.info("stale limit: \(parsed.staleDays) days\(parsed.fromFile ? " (from settings file)" : " (default)")")
        return Config(keep: lines("keep"), roots: lines("roots"), staleDays: parsed.staleDays)
    }

    /// Reads `key = value` lines. A bad value gives a warning and the default.
    static func parseSettings(_ text: String) -> (staleDays: Int, fromFile: Bool, warnings: [String]) {
        var staleDays = defaultStaleDays
        var fromFile = false
        var warnings: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { warnings.append("ignored line \"\(line)\""); continue }
            switch parts[0] {
            case "stale_days":
                if let value = Int(parts[1]), staleDaysRange.contains(value) {
                    staleDays = value
                    fromFile = true
                } else {
                    warnings.append("stale_days \"\(parts[1])\" is not a whole number from \(staleDaysRange.lowerBound) to \(staleDaysRange.upperBound). Using \(defaultStaleDays).")
                }
            default:
                warnings.append("unknown setting \"\(parts[0])\"")
            }
        }
        return (staleDays, fromFile, warnings)
    }

    public init(keep: [String] = [], roots: [String] = [], staleDays: Int = Config.defaultStaleDays) {
        self.keep = keep
        self.roots = roots
        self.staleDays = staleDays
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
    /// Path of `xcrun`. Tests set it to a fake tool. The default finds the real one.
    private let xcrunOverride: String?
    /// The current time. Tests set a fixed time, so that ages do not change from day to day.
    private let now: () -> Date

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, config: Config = .load(),
                useOwnerTools: Bool = true, dockerPath: String? = nil,
                isSocket: @escaping (String) -> Bool = DockerEngine.isUnixSocket,
                now: @escaping () -> Date = Date.init, xcrunPath: String? = nil) {
        self.now = now
        self.xcrunOverride = xcrunPath
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
            { add(self.scanArchives()) },
            { add(self.scanDeviceSupport()) },
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
        // Information lines are not part of any total, so they are always shown.
        let sorted = findings.filter { $0.bytes >= Self.minimumBytes || !$0.isActionable }.sorted { $0.bytes > $1.bytes }
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
        case .docker(let action):
            guard case .success(let engine) = dockerEngine(), let inventory = engine.inventory() else { return finding.bytes }
            switch action {
            case .removeContainer(let id):
                return inventory.containers.contains { $0.id == id } ? finding.bytes : 0
            case .removeImage(let refs):
                let left = inventory.images.contains { refs.contains("\($0.repository):\($0.tag)") }
                return left ? finding.bytes : 0
            case .removeVolume(let name):
                return inventory.volumes.contains { $0.name == name } ? finding.bytes : 0
            }
        case .removeArchive(let url), .removeDeviceSupport(let url):
            return FileManager.default.fileExists(atPath: url.path) ? Sizer.size(of: url) : 0
        case .simulator(let action):
            guard let simctl = simctl() else { return finding.bytes }
            switch action {
            case .deleteRuntime(let id):
                guard let runtimes = simctl.runtimes() else { return finding.bytes }
                return runtimes.contains { $0.id == id } ? finding.bytes : 0
            case .deleteDevice(let udid):
                guard let devices = simctl.devices() else { return finding.bytes }
                return devices.contains { $0.udid == udid } ? finding.bytes : 0
            }
        case .inform:
            return finding.bytes
        case .owner(let command):
            switch command {
            case .brewCleanup: return brewReclaimableBytes()
            case .dockerBuilderPrune: return dockerBuildCacheBytes()
            case .dockerImagePrune: return danglingImageBytes()
            case .simctlDeleteUnavailable: return scanSimulators().first { $0.id == "xcode.sim.unavailable" }?.bytes ?? 0
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
                                   action: .removeContents(url), owner: spec.owner))
            }
        }
        return out
    }

    // MARK: Owner-tool items

    // MARK: Xcode: simulators, runtimes, and archives

    /// `simctl`, or nil when this Mac has no full Xcode. A Mac with only the command line tools has no simulators,
    /// and calling `xcrun` there can open an install window.
    func simctl() -> Simctl? {
        if let xcrunOverride { return Simctl(xcrun: xcrunOverride) }
        let developer = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 5, quiet: true).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard developer.contains(".app/Contents/Developer"), let xcrun = Shell.resolve("xcrun") else { return nil }
        return Simctl(xcrun: xcrun)
    }

    /// Simulator data is in the home folder. We read a size only from there.
    private func isDeviceFolder(_ path: String) -> Bool {
        let root = home.resolvingSymlinksInPath().path + "/Library/Developer/CoreSimulator/Devices/"
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root)
    }

    private func dataBytes(of d: SimDevice) -> Int64 {
        if let bytes = d.dataBytes { return bytes }
        guard let path = d.dataPath, isDeviceFolder(path) else { return 0 }
        return Sizer.size(of: URL(fileURLWithPath: path))
    }

    func scanSimulators() -> [Finding] {
        guard let simctl = simctl() else { return [] }
        let devices = simctl.devices() ?? []
        let runtimes = simctl.runtimes() ?? []
        let place = "Xcode simulators"
        let limit = TimeInterval(config.staleDays) * 86_400
        let current = now()
        var out: [Finding] = []

        func days(since date: Date) -> Int { max(0, Int(current.timeIntervalSince(date) / 86_400)) }
        func used(_ date: Date?) -> String { date.map { "last used \(days(since: $0)) days ago" } ?? "never used" }

        // 1. Simulators whose runtime is gone. Apple's own command removes them. Safe.
        let unavailable = devices.filter { $0.isAvailable == false }
        let unavailableBytes = unavailable.reduce(Int64(0)) { $0 + dataBytes(of: $1) }
        if unavailableBytes > 0 {
            out.append(Finding(id: "xcode.sim.unavailable", ecosystem: .swift, title: "Unavailable simulators",
                               location: place, bytes: unavailableBytes, tier: .safe, rebuild: .seconds,
                               action: .owner(.simctlDeleteUnavailable)))
        }

        // 2. Runtimes. Keep the newest of each platform, and any runtime that is in use.
        var newest: [String: SimRuntime] = [:]
        for r in runtimes where newest[r.platform].map({ r.isNewer(than: $0) }) ?? true { newest[r.platform] = r }

        for r in runtimes where r.isRemovableKind {
            let its = devices.filter { $0.runtimeIdentifier == r.runtimeIdentifier }
            let running = its.contains { $0.isActive }
            let recent = its.contains { $0.lastBootedAt.map { current.timeIntervalSince($0) < limit } ?? false }
                || (r.lastUsedAt.map { current.timeIntervalSince($0) < limit } ?? false)
            let base = "\(place) · build \(r.build) · \(used(r.lastUsedAt))"

            if newest[r.platform]?.id == r.id {
                out.append(Finding(id: "xcode.runtime.info:\(r.id)", ecosystem: .swift,
                                   title: "\(r.displayName) runtime · newest, kept", location: base, bytes: r.sizeBytes,
                                   tier: .review, rebuild: .download, action: .inform))
            } else if running || recent {
                let why = running ? "a simulator is running" : "used in the last \(config.staleDays) days"
                out.append(Finding(id: "xcode.runtime.info:\(r.id)", ecosystem: .swift,
                                   title: "\(r.displayName) runtime · in use", location: "\(base) · \(why)",
                                   bytes: r.sizeBytes, tier: .review, rebuild: .download, action: .inform))
            } else {
                let count = its.count
                out.append(Finding(id: "xcode.runtime:\(r.id)", ecosystem: .swift,
                                   title: "Simulator runtime · \(r.displayName)",
                                   location: "\(base) · \(count == 1 ? "1 simulator runs" : "\(count) simulators run") on it",
                                   bytes: r.sizeBytes, tier: .review, rebuild: .download,
                                   action: .simulator(.deleteRuntime(id: r.id)), lastActivity: r.lastUsedAt,
                                   owner: Catalog.xcodeOrSimulator))
            }
        }

        // 3. Devices that nobody has started for a long time. A running device is never offered.
        for d in devices where d.isAvailable == true && d.state == "Shutdown" {
            if let started = d.lastBootedAt, current.timeIntervalSince(started) < limit { continue }
            let bytes = dataBytes(of: d)
            guard bytes > 0 else { continue }
            let runtimeName = runtimes.first { $0.runtimeIdentifier == d.runtimeIdentifier }?.displayName
                ?? d.runtimeIdentifier.split(separator: ".").last.map { $0.replacingOccurrences(of: "-", with: " ") } ?? ""
            let when = d.lastBootedAt.map { "not started for \(days(since: $0)) days" } ?? "never started"
            out.append(Finding(id: "xcode.device:\(d.udid)", ecosystem: .swift,
                               title: "Simulator · \(d.name) (\(runtimeName))", location: "\(place) · \(when)",
                               bytes: bytes, tier: .review, rebuild: .recreate,
                               action: .simulator(.deleteDevice(udid: d.udid)), lastActivity: d.lastBootedAt,
                               owner: Catalog.xcodeOrSimulator))
        }
        return out
    }

    /// Device support files, one item for each OS version. The newest version of each device model is kept.
    func scanDeviceSupport() -> [Finding] {
        let folders = DeviceSupport.list(home: home).filter { $0.bytes > 0 }
        let keep = DeviceSupport.newest(folders)
        let current = now()
        return folders.compactMap { f in
            guard guardian.check(f.url) == nil else { return nil }
            let rel = "\(f.directory)/\(f.name)"
            let label = "\(f.platform) device support · \(f.name)"
            let age = f.modified.map { "added \(max(0, Int(current.timeIntervalSince($0) / 86_400))) days ago" } ?? "age unknown"
            if keep.contains(f.url) {
                return Finding(id: "xcode.devicesupport.info:\(rel)", ecosystem: .swift, title: "\(label) · newest, kept",
                               location: "\(f.directory) · \(age)", bytes: f.bytes, tier: .review, rebuild: .minutes,
                               action: .inform)
            }
            return Finding(id: "xcode.devicesupport:\(rel)", ecosystem: .swift, title: label,
                           location: "\(f.directory) · \(age) · Xcode copies it again when you connect the device",
                           bytes: f.bytes, tier: .review, rebuild: .minutes, action: .removeDeviceSupport(f.url),
                           lastActivity: f.modified, owner: Catalog.xcode)
        }
    }

    /// The archives of apps that were built for release. They are review items, one by one.
    func scanArchives() -> [Finding] {
        XcodeArchives.list(home: home).compactMap { a in
            guard a.bytes > 0, guardian.check(a.url) == nil else { return nil }
            let rel = a.url.path.replacingOccurrences(of: XcodeArchives.root(home: home).path + "/", with: "")
            let age = a.modified.map { "archived \(max(0, Int(now().timeIntervalSince($0) / 86_400))) days ago" } ?? "age unknown"
            return Finding(id: "xcode.archive:\(rel)", ecosystem: .swift, title: "Archive · \(a.name)",
                           location: "\((a.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) · \(age)",
                           bytes: a.bytes, tier: .review, rebuild: .recreate,
                           action: .removeArchive(a.url), lastActivity: a.modified, owner: Catalog.xcode)
        }
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
        let place = "Docker engine: \(engine.kind)"
        var out: [Finding] = []

        let cache = dockerBuildCacheBytes(engine)
        if cache > 0 {
            out.append(Finding(id: "docker.buildcache", ecosystem: .docker, title: "Build cache",
                               location: place, bytes: cache, tier: .safe, rebuild: .minutes,
                               action: .owner(.dockerBuilderPrune)))
        }

        guard let inventory = engine.inventory() else { return out }

        let dangling = inventory.danglingImages.reduce(Int64(0)) { $0 + $1.uniqueBytes }
        if dangling > 0 {
            out.append(Finding(id: "docker.images.dangling", ecosystem: .docker, title: "Untagged images",
                               location: place, bytes: dangling, tier: .safe, rebuild: .minutes,
                               action: .owner(.dockerImagePrune)))
        }

        // Stopped containers, one by one. A container can hold data that is stored nowhere else,
        // so each one is a review item. A running container never appears.
        for c in inventory.stoppedContainers where DockerAction.isHexID(c.id) {
            let label = c.name.isEmpty ? String(c.id.prefix(12)) : c.name
            out.append(Finding(id: "docker.container:\(c.id.prefix(12))", ecosystem: .docker,
                               title: "Stopped container · \(label)",
                               location: "\(place) · image \(c.image) · \(c.status)",
                               bytes: c.writableBytes, tier: .review, rebuild: .recreate,
                               action: .docker(.removeContainer(id: c.id))))
        }

        // Named images that no container uses and that have been on this Mac for a long time.
        // The age is the time since the image arrived here. The build date can be years older.
        let groups = inventory.unusedNamedImages
        if !groups.isEmpty {
            let arrived = engine.tagTimes(ofImages: groups.map(\.id))
            let limit = TimeInterval(config.staleDays) * 86_400
            for g in groups {
                // An image of unknown age is left out. We never guess. The build date is no help,
                // because an image that was built years ago can have arrived here last week.
                guard let since = arrived[g.id] else { continue }
                let age = now().timeIntervalSince(since)
                guard age >= limit else { continue }
                let days = Int(age / 86_400)
                let extra = g.refs.count > 1 ? " (+\(g.refs.count - 1) more names)" : ""
                out.append(Finding(id: "docker.image:\(g.id.dropFirst(7).prefix(12))", ecosystem: .docker,
                                   title: "Image · \(g.refs[0])\(extra)",
                                   location: "\(place) · on this Mac for \(days) days",
                                   bytes: g.uniqueBytes, tier: .review, rebuild: .download,
                                   action: .docker(.removeImage(refs: g.refs)), lastActivity: since))
            }
        }

        // Docker Desktop keeps all its data in one disk image. Show its real size next to the data inside.
        // This is information only. The app never changes the file.
        if engine.kind == "Docker Desktop", let disk = DockerDesktopDisk.find(home: home), disk.allocatedBytes > 0 {
            let inside = engine.summary().filter { ["Images", "Containers", "Local Volumes", "Build Cache"].contains($0.key) }
                .values.reduce(Int64(0)) { $0 + $1.size }
            // Finder shows the full size of a sparse file. We say so in the tooltip, to avoid confusion.
            let finder = disk.logicalBytes > disk.allocatedBytes * 2
                ? " · Finder may show \(Self.megabytesText(disk.logicalBytes))" : ""
            out.append(Finding(
                id: "docker.vmdisk", ecosystem: .docker, title: "Docker Desktop disk image",
                location: "\(place) · \(disk.url.path)\(finder)", bytes: disk.allocatedBytes, tier: .review,
                rebuild: .never, action: .inform,
                note: "Holds \(Self.megabytesText(inside)) of data. The file can stay large after a clean.",
                helpURL: DockerDesktopDisk.helpURL))
        }

        // Volumes. They can hold databases, so a removable one is offered one by one, with a strong warning.
        // A volume that a container uses is shown for information only. It has no action.
        for v in inventory.volumes where DockerAction.isVolumeName(v.name) {
            let label = v.isAnonymous ? "Anonymous volume · \(v.name.prefix(12))…" : "Volume · \(v.name)"
            if v.isRemovable {
                out.append(Finding(id: "docker.volume:\(v.name)", ecosystem: .docker, title: "Unused \(label.prefix(1).lowercased() + label.dropFirst())",
                                   location: "\(place) · no container uses it", bytes: v.bytes, tier: .review,
                                   rebuild: .never, action: .docker(.removeVolume(name: v.name))))
            } else {
                let why = v.links > 0 ? "used by \(v.links) container\(v.links == 1 ? "" : "s")"
                    : (v.driver != "local" ? "driver \(v.driver), may not be on this Mac" : "Docker did not say if it is used")
                out.append(Finding(id: "docker.volume.info:\(v.name)", ecosystem: .docker, title: label,
                                   location: "\(place) · \(why)", bytes: v.bytes, tier: .review,
                                   rebuild: .never, action: .inform))
            }
        }
        return out
    }

    func danglingImageBytes() -> Int64 {
        guard case .success(let engine) = dockerEngine() else { return 0 }
        return danglingImageBytes(engine)
    }

    /// Untagged images that no container uses. We add each image's unique size, so that
    /// layers that images share are not counted twice.
    private func danglingImageBytes(_ engine: DockerEngine) -> Int64 {
        engine.inventory()?.danglingImages.reduce(0) { $0 + $1.uniqueBytes } ?? 0
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
                                     activeDirectories: Shell.activeDirectories(),
                                     now: now(), staleDays: config.staleDays)
        return scanner.scan()
    }

    // MARK: Helpers

    /// "4.1 GB". The same words as the menu uses.
    static func megabytesText(_ bytes: Int64) -> String {
        let v = Double(max(0, bytes))
        if v >= 1e10 { return String(format: "%.0f GB", v / 1e9) }
        if v >= 1e9 { return String(format: "%.1f GB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.0f MB", v / 1e6) }
        return String(format: "%.0f KB", v / 1e3)
    }

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
