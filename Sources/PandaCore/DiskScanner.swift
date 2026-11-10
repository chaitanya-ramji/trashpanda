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
    private let brewOverride: String?
    private let ollamaOverride: String?
    /// The programs that run now, with their full paths. A runtime that a program starts from stays.
    private let programPaths: () -> [String]
    private let tmutilOverride: String?
    /// The program files that `claude` processes execute now. Tests give a list. nil means that we cannot tell.
    private let openClaudeBinaries: ([String]) -> [String]?
    /// The current time. Tests set a fixed time, so that ages do not change from day to day.
    private let now: () -> Date
    /// The name of an installed app. Tests give their own.
    private let appName: (String) -> String?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, config: Config = .load(),
                useOwnerTools: Bool = true, dockerPath: String? = nil,
                isSocket: @escaping (String) -> Bool = DockerEngine.isUnixSocket,
                now: @escaping () -> Date = Date.init, xcrunPath: String? = nil, brewPath: String? = nil, ollamaPath: String? = nil, programPaths: @escaping () -> [String] = TestBrowsers.runningProgramPaths, tmutilPath: String? = nil, openClaudeBinaries: @escaping ([String]) -> [String]? = ClaudeVersions.openBinaryPaths(among:),
                appName: @escaping (String) -> String? = UpdateDownloads.systemAppName(for:)) {
        self.now = now
        self.appName = appName
        self.xcrunOverride = xcrunPath
        self.brewOverride = brewPath
        self.ollamaOverride = ollamaPath
        self.programPaths = programPaths
        self.tmutilOverride = tmutilPath
        self.openClaudeBinaries = openClaudeBinaries
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
            { add(self.scanUpdateDownloads()) },
            { add(self.scanBrowserCaches()) },
            { add(self.scanServiceWorkerStorage()) },
            { add(self.scanTestBrowsers()) },
            { add(self.scanTrash()) },
            { add(self.scanInstallers()) },
            { add(self.scanLogs()) },
            { add(self.scanAgents()) },
            { add(self.scanRuntimes()) },
        ]
        if useOwnerTools {
            jobs += [
                { add(self.scanSimulators()) },
                { add(self.scanHomebrew()) },
                { add(self.scanBrewLeaves()) },
                { add(self.scanOllama()) },
                { add(self.scanGlobalPackages()) },
                { add(self.scanSnapshots()) },
                { add(self.scanCacheExplorer()) },
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
        case .removeServiceWorkerSite(let id, let profile, let folder):
            return BrowserCaches.browser(id: id).flatMap { ServiceWorkerSites.site(browser: $0, profile: profile, folder: folder, home: home) }?.bytes ?? 0
        case .removeBrowserCaches(let id):
            return BrowserCaches.browser(id: id).map { BrowserCaches.bytes(of: $0, home: home) } ?? finding.bytes
        case .removeServiceWorkerStorage(let id):
            return BrowserCaches.browser(id: id).map { BrowserCaches.serviceWorkerBytes(of: $0, home: home) } ?? finding.bytes
        case .emptyTrash:
            return TrashBin.bytes(home: home)
        case .removeRuntime(let storeID, let tool, let name):
            return RuntimeVersions.store(id: storeID).flatMap { RuntimeVersions.versions(in: $0, home: home).first { $0.tool == tool && $0.name == name } }?.bytes ?? 0
        case .globalPackage(let manager, let name):
            guard let tool = Shell.resolve(manager.tool) else { return finding.bytes }
            return GlobalPackages.list(manager, tool: tool, home: home, now: now())?.first { $0.name == name }?.bytes ?? 0
        case .agent(.removeOldSessions(let kind, let cutoff, _)):
            return AgentSessions.entries(kind, home: home, olderThan: cutoff).reduce(Int64(0)) { $0 + $1.bytes }
        case .agent(.removeFixedFolders(let id)):
            guard let app = FixedFolders.app(id: id) else { return finding.bytes }
            return FixedFolders.targets(of: app, home: home).reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
        case .agent(.removeLocalModel(let storeID, let name)):
            return LocalModels.model(storeID: storeID, name: name, home: home)?.bytes ?? 0
        case .agent(.removeHuggingFaceRepo(let id)):
            return HuggingFace.repo(id: id, home: home, now: now()).map(\.bytes) ?? 0
        case .agent(.removeOllamaModel(let name)):
            return ollamaTool()?.models()?.first { $0.name == name }?.bytes ?? 0
        case .agent(.removeEditorCaches(let id)):
            guard let app = EditorCaches.app(id: id) else { return finding.bytes }
            return EditorCaches.targets(of: app, home: home, now: now()).reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
        case .agent(.removeObsoleteExtensions(let id)):
            guard let app = EditorCaches.app(id: id) else { return finding.bytes }
            return EditorCaches.obsoleteExtensions(of: app, home: home).reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
        case .agent(.removeAgentCaches(let id)):
            guard let app = AgentCaches.electronApp(id: id) else { return finding.bytes }
            return AgentCaches.targets(of: app, home: home).reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
        case .agent(.removeOldClaudeDesktopRuntimes(let names)):
            return ClaudeDesktop.oldRuntimes(home: home).filter { names.contains(ClaudeDesktop.runtimeName($0)) }.reduce(Int64(0)) { $0 + $1.bytes }
        case .agent(.removeClaudeVMBundle):
            return ClaudeDesktop.vmBundles(home: home).reduce(Int64(0)) { $0 + $1.bytes }
        case .agent(.removeOldClaudeVersions(let names)):
            guard let running = openClaudeBinaries(ClaudeVersions.entries(home: home).map { $0.url.path }) else { return finding.bytes }
            return ClaudeVersions.old(home: home, running: running).old.filter { names.contains($0.name) }.reduce(Int64(0)) { $0 + $1.bytes }
        case .agent(.removeCodexRuntime(let url)):
            return FileManager.default.fileExists(atPath: url.path) ? Sizer.size(of: url) : 0
        case .brew(let action):
            return brew()?.bytes(of: action.name) ?? finding.bytes
        case .removeOldLogs(let kind):
            return OldLogs.bytes(kind, home: home, now: now())
        case .removeInstaller(let url):
            return FileManager.default.fileExists(atPath: url.path) ? finding.bytes : 0
        case .removeOldTestBrowsers(let id):
            return TestBrowsers.tool(id: id).map { TestBrowsers.bytes(of: $0, home: home) } ?? finding.bytes
        case .removeUpdateDownloads(let url):
            return UpdateDownloads.staleBytes(in: url, now: now())
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
            case .uvCacheClean, .uvCachePrune:
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
                                   action: .removeContents(url), note: spec.note, owner: spec.owner))
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

    /// A path with `~` for the home folder of this scanner. It does not use the home folder of the user who runs the test.
    private func tilde(_ path: String) -> String {
        path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }

    /// The caches of Chromium browsers. One safe item for each browser. The browser must be closed.
    func scanBrowserCaches() -> [Finding] {
        BrowserCaches.browsers.compactMap { b in
            let targets = BrowserCaches.targets(of: b, home: home).filter { guardian.check($0) == nil }
            let bytes = targets.reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
            guard bytes > 0 else { return nil }
            return Finding(id: "browser.cache:\(b.id)", ecosystem: .browsers, title: "Browser caches · \(b.name)",
                           location: "\(b.roots.map { "~/" + $0 }.joined(separator: " and ")) · pages load again the first time",
                           bytes: bytes, tier: .safe, rebuild: .download,
                           action: .removeBrowserCaches(browserID: b.id), owner: b.owner)
        }
    }

    /// Old files in `~/Library/Logs`: one item for the logs and one for the crash reports. Both are review items.
    func scanLogs() -> [Finding] {
        OldLogs.Kind.allCases.compactMap { kind in
            let files = OldLogs.entries(kind, home: home, now: now()).filter { guardian.check($0.url) == nil }
            let bytes = files.reduce(Int64(0)) { $0 + $1.bytes }
            guard bytes > 0 else { return nil }
            return Finding(id: kind.findingID, ecosystem: .logs, title: kind.title,
                           location: "~/Library/Logs · \(files.count) file\(files.count == 1 ? "" : "s") older than \(OldLogs.minimumAgeDays) days",
                           bytes: bytes, tier: .review, rebuild: .never, action: .removeOldLogs(kind))
        }
    }

    /// Old `.dmg` and `.pkg` files in `~/Downloads`. One review item for each file, so the user chooses each one.
    func scanInstallers() -> [Finding] {
        Installers.list(home: home, now: now()).compactMap { i in
            guard i.bytes > 0, guardian.check(i.url) == nil else { return nil }
            let name = i.url.lastPathComponent
            return Finding(id: "installer:\(name)", ecosystem: .installers, title: "Installer · \(name)",
                           location: "~/Downloads/\(name) · \(i.ageDays) days old",
                           bytes: i.bytes, tier: .review, rebuild: .download, action: .removeInstaller(i.url))
        }
    }

    /// The Trash of the user. It is a review item: the user chose to keep these files until now, and emptying is final.
    func scanTrash() -> [Finding] {
        let folder = TrashBin.url(home: home)
        guard TrashBin.readable(folder) else {
            if FileManager.default.fileExists(atPath: folder.path) { Log.warn("the Trash cannot be read. Full Disk Access may be needed") }
            return []
        }
        let bytes = Sizer.size(of: folder)
        guard bytes > 0 else { return [] }
        return [Finding(id: "trash", ecosystem: .trash, title: "Trash", location: "~/.Trash · Finder empties it",
                        bytes: bytes, tier: .review, rebuild: .never, action: .emptyTrash)]
    }

    /// Old versions of the browsers that Playwright, Cypress, and Puppeteer downloaded. The newest of each kind stays.
    func scanTestBrowsers() -> [Finding] {
        TestBrowsers.tools.compactMap { tool in
            let old = TestBrowsers.oldVersions(of: tool, home: home).filter { guardian.check($0) == nil }
            let bytes = old.reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
            guard bytes > 0 else { return nil }
            return Finding(id: "testbrowsers:\(tool.id)", ecosystem: .javascript, title: "Old test browsers · \(tool.name)",
                           location: "~/\(tool.root) · \(old.count) older version\(old.count == 1 ? "" : "s") · the newest of each kind stays",
                           bytes: bytes, tier: .safe, rebuild: .download, action: .removeOldTestBrowsers(toolID: tool.id))
        }
    }

    /// Service Worker storage of Chromium browsers. Offline web apps keep their files there, so this is a review item.
    /// One review item for each website. The user can keep the one web app that works offline and clear the rest (#44).
    /// The host name is shown only when it is proven by the name of the folder. Otherwise the item is "Unknown site".
    func scanServiceWorkerStorage() -> [Finding] {
        BrowserCaches.browsers.filter { $0.kind == .chromium }.flatMap { b -> [Finding] in
            let profiles = Set(ServiceWorkerSites.sites(of: b, home: home).map(\.profile)).count
            return ServiceWorkerSites.sites(of: b, home: home).compactMap { s in
                guard s.bytes > 0, guardian.check(s.url) == nil else { return nil }
                let where_ = profiles > 1 ? " · profile \(s.profile)" : ""
                return Finding(id: "browser.sw:\(b.id):\(s.profile):\(s.folder)", ecosystem: .browsers,
                               title: "Offline website · \(s.title) (\(b.name))",
                               location: "Saved files of one website that works offline\(where_)",
                               bytes: s.bytes, tier: .review, rebuild: .download,
                               action: .removeServiceWorkerSite(browserID: b.id, profile: s.profile, folder: s.folder), owner: b.owner)
            }
        }
    }

    /// Old update files that apps leave behind. One item for each app. The app that owns them must be closed.
    func scanUpdateDownloads() -> [Finding] {
        UpdateDownloads.list(home: home, now: now()).compactMap { app in
            guard guardian.check(app.url) == nil else { return nil }
            let name = appName(app.bundleID) ?? app.bundleID
            let shown = tilde(app.url.deletingLastPathComponent().path)
            return Finding(id: "app.updates:\(app.bundleID)", ecosystem: .apps, title: "Old update downloads · \(name)",
                           location: "\(shown) · older than \(UpdateDownloads.minimumAgeDays) days",
                           bytes: app.staleBytes, tier: .safe, rebuild: .download,
                           action: .removeUpdateDownloads(app.url),
                           owner: AppOwner(name: name, bundleIDs: [app.bundleID]))
        }
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
                           location: "\(tilde(a.url.deletingLastPathComponent().path)) · \(age)",
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

    func brew() -> Brew? {
        (brewOverride ?? Shell.resolve("brew")).map { Brew(path: $0) }
    }

    /// The AI agents group. Each product has its own function, and its items start with the product name.
    func scanAgents() -> [Finding] {
        scanCodexRuntimes() + scanClaudeVersions() + scanClaudeDesktop() + scanElectronCaches() + scanEditorCaches() + scanHuggingFace() + scanLocalModels() + scanFixedFolders() + scanAgentSessions()
    }

    /// Old transcripts of Codex and Claude Code (review), and a note about the chats of Gemini CLI.
    func scanAgentSessions() -> [Finding] {
        var out: [Finding] = AgentSessions.Kind.allCases.compactMap { kind in
            // Claude Code has its own retention setting. If the user keeps sessions longer than our limit, we keep them that long too.
            let days = max(config.staleDays, kind == .claude ? (AgentSessions.claudeRetentionDays(home: home) ?? 0) : 0)
            let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
            let files = AgentSessions.entries(kind, home: home, olderThan: cutoff).filter { guardian.check($0.url) == nil }
            let bytes = files.reduce(Int64(0)) { $0 + $1.bytes }
            guard bytes > 0, let oldest = files.first else { return nil }
            let oldestDays = max(0, Int(now().timeIntervalSince(oldest.modified) / 86_400))
            let setting = kind == .claude ? " · Claude Code also deletes them by itself (cleanupPeriodDays)" : ""
            return Finding(id: kind.findingID, ecosystem: .aiAgents, title: kind.title,
                           location: "\(files.count) session\(files.count == 1 ? "" : "s") older than \(days) days · the oldest is \(oldestDays) days old\(setting)",
                           bytes: bytes, tier: .review, rebuild: .never,
                           action: .agent(.removeOldSessions(kind: kind, olderThan: cutoff, minimumAgeDays: days)))
        }
        let gemini = AgentSessions.geminiChatBytes(home: home)
        if gemini >= 50_000_000 {
            out.append(Finding(id: "agent.sessions.gemini", ecosystem: .aiAgents, title: "Gemini · saved chats",
                               location: "~/.gemini/tmp · gemini --delete-session removes one, or set general.sessionRetention",
                               bytes: gemini, tier: .review, rebuild: .never, action: .inform))
        }
        return out
    }

    /// Apps with a few fixed rebuildable folders (Zed). One safe item for each app, and the app must be closed.
    func scanFixedFolders() -> [Finding] {
        FixedFolders.apps.compactMap { app in
            let targets = FixedFolders.targets(of: app, home: home).filter { guardian.check($0) == nil }
            let bytes = targets.reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
            guard bytes > 0 else { return nil }
            return Finding(id: "agent.folders:\(app.id)", ecosystem: .aiAgents, title: app.title,
                           location: targets.map { "~/" + $0.path.dropFirst(home.standardizedFileURL.path.count + 1) }.joined(separator: ", "),
                           bytes: bytes, tier: .safe, rebuild: .download, action: .agent(.removeFixedFolders(appID: app.id)),
                           note: "Your settings, extensions, and chats stay.", owner: app.owner)
        }
    }

    /// The models of LM Studio, Jan, and GPT4All. One review item for each model, and the app must be closed.
    func scanLocalModels() -> [Finding] {
        LocalModels.stores.flatMap { store in
            LocalModels.models(in: store, home: home).compactMap { m -> Finding? in
                guard guardian.check(m.url) == nil else { return nil }
                return Finding(id: "agent.model:\(store.id):\(m.name)", ecosystem: .aiAgents, title: "\(store.product) · model \(m.name)",
                               location: "~/\(store.root)", bytes: m.bytes, tier: .review, rebuild: .download,
                               action: .agent(.removeLocalModel(storeID: store.id, name: m.name)),
                               note: "Downloaded again when you need it. Your chats and settings stay.", owner: store.owner)
            }
        }
    }

    /// The repositories of the Hugging Face hub cache. One review item for each. Datasets are costly to get again.
    func scanHuggingFace() -> [Finding] {
        HuggingFace.repos(home: home, now: now()).compactMap { r in
            guard r.bytes > 0, guardian.check(r.folder) == nil else { return nil }
            let age = r.ageDays.map { "downloaded \($0) days ago" } ?? "download date unknown"
            return Finding(id: "agent.hf:\(r.id)", ecosystem: .aiAgents, title: "Hugging Face · \(r.kind.rawValue) \(r.name)",
                           location: "~/\(HuggingFace.hubFolder) · \(age)", bytes: r.bytes, tier: .review, rebuild: .download,
                           action: .agent(.removeHuggingFaceRepo(id: r.id)),
                           note: r.kind == .dataset ? "A dataset can be very large to download again." : "Downloaded again when you need it.")
        }
    }

    /// The VS Code style editors: rebuildable folders, old logs, and extensions that the editor marks obsolete. All safe, editor closed.
    func scanEditorCaches() -> [Finding] {
        var out: [Finding] = []
        for app in EditorCaches.apps {
            let targets = EditorCaches.targets(of: app, home: home, now: now()).filter { guardian.check($0) == nil }
            let bytes = targets.reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
            if bytes > 0 {
                let logs = targets.filter { $0.deletingLastPathComponent().lastPathComponent == "logs" }.count
                out.append(Finding(id: "agent.editor:\(app.id)", ecosystem: .aiAgents, title: app.title,
                                   location: "~/\(app.supportRoot) · \(targets.count - logs) cache folder\(targets.count - logs == 1 ? "" : "s"), \(logs) old log\(logs == 1 ? "" : "s") · settings and chats stay",
                                   bytes: bytes, tier: .safe, rebuild: .download, action: .agent(.removeEditorCaches(appID: app.id)),
                                   owner: app.owner))
            }
            let ext = EditorCaches.obsoleteExtensions(of: app, home: home).filter { guardian.check($0) == nil }
            let extBytes = ext.reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
            if extBytes > 0, let rel = app.extensionsRoot {
                out.append(Finding(id: "agent.extensions:\(app.id)", ecosystem: .aiAgents, title: app.extensionsTitle,
                                   location: "~/\(rel) · \(ext.count) old version\(ext.count == 1 ? "" : "s") that \(app.product) marked obsolete",
                                   bytes: extBytes, tier: .safe, rebuild: .download, action: .agent(.removeObsoleteExtensions(appID: app.id)),
                                   owner: app.owner))
            }
        }
        return out
    }

    /// Global packages of npm, pnpm, Yarn, and Bun. One review item for each package. The manager removes it.
    func scanGlobalPackages() -> [Finding] {
        PackageManager.allCases.flatMap { manager -> [Finding] in
            guard let tool = Shell.resolve(manager.tool),
                  let packages = GlobalPackages.list(manager, tool: tool, home: home, now: now()) else { return [] }
            return packages.compactMap { p in
                guard p.bytes > 0 else { return nil }
                let age = p.ageDays.map { " · installed or updated \($0) days ago" } ?? ""
                return Finding(id: "pkg.\(manager.rawValue):\(p.name)", ecosystem: .javascript,
                               title: "Global package · \(p.name) (\(manager.label))",
                               location: "\(p.name)@\(p.version)\(age)", bytes: p.bytes, tier: .review, rebuild: .download,
                               action: .globalPackage(manager: manager, name: p.name),
                               note: "A program that calls it, such as an MCP server in an AI app, stops working.")
            }
        }
    }

    func ollamaTool() -> Ollama? { (ollamaOverride ?? Shell.resolve("ollama")).map { Ollama(path: $0) } }

    /// The models of Ollama that nobody changed for the stale limit and that are not loaded. One review item for each model.
    /// If Ollama does not answer (its server may be off), there is no item.
    func scanOllama() -> [Finding] {
        guard let tool = ollamaTool(), let models = tool.models(), let loaded = tool.loaded() else { return [] }
        return models.compactMap { m in
            guard let age = m.ageDays, age >= config.staleDays, !loaded.contains(m.name), m.bytes > 0 else { return nil }
            return Finding(id: "agent.ollama:\(m.name)", ecosystem: .aiAgents, title: "Ollama · model \(m.name)",
                           location: "Ollama · pulled \(age) days ago · layers that other models share stay", bytes: m.bytes,
                           tier: .review, rebuild: .download, action: .agent(.removeOllamaModel(name: m.name)),
                           note: "Downloaded again when you need it.")
        }
    }

    /// The Chromium cache folders of the Electron apps in the table. One safe item for each app.
    func scanElectronCaches() -> [Finding] {
        AgentCaches.electronApps.compactMap { app in
            let targets = AgentCaches.targets(of: app, home: home).filter { guardian.check($0) == nil }
            let bytes = targets.reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
            guard bytes > 0 else { return nil }
            return Finding(id: "agent.electron:\(app.id)", ecosystem: .aiAgents, title: app.title,
                           location: "~/\(app.supportRoot) · \(targets.count) cache folder\(targets.count == 1 ? "" : "s") · logins and chats stay",
                           bytes: bytes, tier: .safe, rebuild: .download, action: .agent(.removeAgentCaches(appID: app.id)),
                           owner: app.owner)
        }
    }

    /// Old runtimes and the Cowork VM of Claude Desktop. Both are review items, and Claude Desktop must be closed.
    func scanClaudeDesktop() -> [Finding] {
        var out: [Finding] = []
        let place = "~/" + AgentCaches.claudeRoot
        let old = ClaudeDesktop.oldRuntimes(home: home).filter { guardian.check($0.url) == nil }
        let oldBytes = old.reduce(Int64(0)) { $0 + $1.bytes }
        if oldBytes > 0 {
            let names = old.map { "\($0.family) \($0.url.lastPathComponent)" }.joined(separator: ", ")
            out.append(Finding(id: "agent.claude.runtimes", ecosystem: .aiAgents, title: "Claude · old Desktop runtimes",
                               location: "\(place) · \(names) · the newest of each stays", bytes: oldBytes, tier: .review, rebuild: .download,
                               action: .agent(.removeOldClaudeDesktopRuntimes(names: old.map { ClaudeDesktop.runtimeName($0) })), owner: AgentOwners.claudeDesktop))
        }
        let vm = ClaudeDesktop.vmBundles(home: home).filter { guardian.check($0.url) == nil }
        let vmBytes = vm.reduce(Int64(0)) { $0 + $1.bytes }
        if vmBytes > 0 {
            out.append(Finding(id: "agent.claude.vm", ecosystem: .aiAgents, title: "Claude · Cowork VM",
                               location: "\(place)/\(AgentCaches.claudeVMRoot)", bytes: vmBytes, tier: .review, rebuild: .download,
                               action: .agent(.removeClaudeVMBundle),
                               note: "Claude downloads about 10 GB again when it needs it. Settings, Storage in Claude removes old tasks first.",
                               helpURL: ClaudeDesktop.changelogURL, owner: AgentOwners.claudeDesktop))
        }
        return out
    }

    /// Old versions of the Claude Code tool. One item. If we cannot tell which versions run, there is no item.
    func scanClaudeVersions() -> [Finding] {
        guard let running = openClaudeBinaries(ClaudeVersions.entries(home: home).map { $0.url.path }) else { return [] }
        let (old, kept) = ClaudeVersions.old(home: home, running: running)
        let list = old.filter { guardian.check($0.url) == nil }
        let bytes = list.reduce(Int64(0)) { $0 + $1.bytes }
        guard bytes > 0 else { return [] }
        return [Finding(id: "agent.claude.versions", ecosystem: .aiAgents, title: "Claude · old Code versions",
                        location: "~/\(ClaudeVersions.directory) · \(list.count) older version\(list.count == 1 ? "" : "s") · \(kept.joined(separator: ", ")) stay\(kept.count == 1 ? "s" : "")",
                        bytes: bytes, tier: .safe, rebuild: .download, action: .agent(.removeOldClaudeVersions(names: list.map(\.name))))]
    }

    /// Leftover installs and the downloaded runtime of the Codex app.
    func scanCodexRuntimes() -> [Finding] {
        let place = "~/" + CodexRuntimes.root
        return CodexRuntimes.list(home: home, now: now()).compactMap { entry in
            guard guardian.check(entry.url) == nil else { return nil }
            let bytes = Sizer.size(of: entry.url)
            guard bytes > 0 else { return nil }
            let name = entry.url.lastPathComponent
            switch entry.kind {
            case .staging:
                return Finding(id: "agent.codex.staging:\(name)", ecosystem: .aiAgents, title: "Codex · leftover runtime install",
                               location: "\(place)/\(name) · \(entry.ageDays) days old",
                               bytes: bytes, tier: .safe, rebuild: .download,
                               action: .agent(.removeCodexRuntime(entry.url)), owner: AgentOwners.codex)
            case .primary:
                return Finding(id: "agent.codex.runtime", ecosystem: .aiAgents, title: "Codex · downloaded runtime",
                               location: "\(place)/\(name)", bytes: bytes, tier: .review, rebuild: .download,
                               action: .agent(.removeCodexRuntime(entry.url)),
                               note: "The app downloads it again (about 1.7 GB). Document and spreadsheet tools stop until then.",
                               owner: AgentOwners.codex)
            }
        }
    }

    /// Formulae that no other formula needs. One review item for each, so the user chooses each one.
    /// Brew does not say when a tool was last used, so we show the install date and never say "unused".
    func scanBrewLeaves() -> [Finding] {
        guard let brew = brew(), let leaves = brew.leaves() else { return [] }
        let current = now()
        return leaves.compactMap { name in
            guard let p = brew.package(name, now: current), p.bytes > 0 else { return nil }
            var place = "Nothing else needs it"
            if let d = p.installedDaysAgo { place += " · installed \(d) days ago" }
            if !p.onRequest { place += " · added only as a dependency" }
            return Finding(id: "brew.leaf:\(name)", ecosystem: .homebrew, title: "Package · \(name)", location: place,
                           bytes: p.bytes, tier: .review, rebuild: .download, action: .brew(.uninstall(name: name)))
        }
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
        // Agents such as Claude Code and Codex start `uv` (uvx, uv run), so this cache grows on a Mac that uses them.
        // `uv cache clean` removes everything, so it is a deliberate choice (review). `uv cache prune` removes only unused entries
        // and the uv documentation says to run it often. Its size cannot be previewed (a dry run is not documented), so the item shows
        // the size of the cache as an upper bound, and the report shows what was really freed.
        var out = [Finding(id: "uv.cache", ecosystem: .python, title: "uv cache (everything)", location: dir.path,
                           bytes: bytes, tier: .review, rebuild: .download,
                           action: uv != nil ? .owner(.uvCacheClean) : .removeContents(dir),
                           note: "Removes the whole cache. Agents such as Claude Code and Codex start uv.")]
        if uv != nil {
            out.append(Finding(id: "uv.prune", ecosystem: .aiAgents, title: "uv · unused cache entries", location: dir.path,
                               bytes: bytes, tier: .safe, rebuild: .download, action: .owner(.uvCachePrune),
                               note: "Up to this size. uv removes only what nothing uses. Agents such as Claude Code and Codex start uv."))
        }
        return out
    }

    // MARK: Cache explorer

    /// The largest folders in `Library/Caches`, as information lines. Read only: there is no action, so nothing can be removed from here.
    func scanCacheExplorer() -> [Finding] {
        // Folders that have an item of their own: the catalog, the browsers, the test browsers, and the tools that clean themselves.
        let cleanable = CacheExplorer.cleanableNames(paths: Catalog.caches.flatMap(\.paths) + BrowserCaches.browsers.flatMap(\.roots)
                                                      + TestBrowsers.tools.map(\.root) + CacheExplorer.selfCleaningTools)
        return CacheExplorer.entries(home: home, cleanable: cleanable, appName: appName).map { e in
            Finding(id: "cache.explorer:\(e.folder)", ecosystem: .cacheExplorer, title: e.displayName == e.folder ? "\(e.displayName) · \(e.label.rawValue)" : "\(e.displayName) (\(e.folder)) · \(e.label.rawValue)",
                    location: "~/Library/Caches/\(e.folder)", bytes: e.bytes, tier: .review, rebuild: .never, action: .inform, note: e.reason)
        }
    }

    // MARK: Time Machine

    /// A note, only when Time Machine keeps local snapshots. Information only: the app deletes nothing here.
    func scanSnapshots() -> [Finding] {
        guard let info = LocalSnapshots.read(tool: tmutilOverride ?? LocalSnapshots.tmutilPath, now: now()) else { return [] }
        let age = info.oldestDays.map { " · the oldest is \($0) days old" } ?? ""
        let word = info.count == 1 ? "1 local snapshot" : "\(info.count) local snapshots"
        return [Finding(id: "snapshots.local", ecosystem: .snapshots, title: "Time Machine · \(word)",
                        location: "Read with tmutil, read only\(age)", bytes: 0, tier: .review, rebuild: .never, action: .inform,
                        note: "They can hold space that deleting files does not free at once. macOS removes them by itself when the disk needs the space. Trash Panda does not delete them.",
                        helpURL: LocalSnapshots.helpURL)]
    }

    // MARK: Projects

    /// The folders in which we look for projects: the usual developer folders, and the roots of the settings.
    func projectRoots() -> [URL] {
        var roots: [URL] = []
        let fm = FileManager.default
        for name in Self.defaultRootNames {
            let url = home.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: url.path) { roots.append(url) }
        }
        for path in config.roots { roots.append(URL(fileURLWithPath: path, isDirectory: true)) }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// What the projects ask for (`.nvmrc`, `.python-version`, `rust-toolchain`, `.tool-versions`, ...). The cleaner reads it again.
    public func runtimeRequests() -> [RuntimeVersions.Request] { RuntimeVersions.projectRequests(roots: projectRoots()) }

    /// Runtime versions that nothing keeps: not the default, not asked for by a scanned project, not the newest, not running.
    /// One review item for each version. The text says "no scanned project asks for it", never "unused".
    func scanRuntimes() -> [Finding] {
        let decision = RuntimeVersions.decide(home: home, requests: runtimeRequests(), running: programPaths())
        return decision.removable.compactMap { v in
            guard v.bytes > 0, guardian.check(v.url) == nil else { return nil }
            let kept = decision.kept.filter { $0.key.hasPrefix("\(v.store.id)/\(v.tool)/") }.count
            return Finding(id: "runtime:\(v.store.id):\(v.key)", ecosystem: .runtimes, title: "\(v.tool.capitalized) \(v.name) (\(v.store.manager))",
                           location: "~/\(v.store.root)\(v.store.depth == 2 ? "/" + v.tool : "")/\(v.name) · not the default · no scanned project asks for it · \(kept) other \(kept == 1 ? "version stays" : "versions stay")",
                           bytes: v.bytes, tier: .review, rebuild: .download, action: .removeRuntime(storeID: v.store.id, tool: v.tool, name: v.name),
                           note: "Scripts, editors, and projects outside the scanned folders can still use it.")
        }
    }

    func scanProjects() -> [Finding] {
        var roots: [URL] = projectRoots()
        let fm = FileManager.default

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
