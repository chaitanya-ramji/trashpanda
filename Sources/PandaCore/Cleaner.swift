import Foundation

/// Deletes items. Every path passes the guard first. By default a delete is for good. In trash mode (`DeleteMode`),
/// a file or a folder moves to the Trash instead, and a tool item (Docker, Homebrew, and so on) still runs its tool.
/// The app shows a preview before it calls this.
/// The report counts the space that really left the disk. It does not repeat the scan estimate.
/// Bytes that moved to the Trash are counted apart (`movedToTrash`), because that space is not free yet.
public final class Cleaner {
    public let guardian: PathGuard
    /// Measures what is left of an item after the clean. Without it, owner commands report the estimate.
    private let remaining: ((Finding) -> Int64)?
    /// Finds the Docker engine at clean time. The engine can change after the scan.
    private let dockerEngine: () -> Result<DockerEngine, DockerRefusal>

    /// Tells which apps run now. The cleaner asks again before each item.
    private let runningApps: RunningApps
    /// Finds `simctl` at clean time. Tests give a fake one.
    private let simctl: () -> Simctl?
    /// The programs that run now, with their full paths. A test browser that runs is not removed.
    private let programPaths: () -> [String]
    /// Empties the Trash. The app asks Finder. Tests give a fake one.
    private let emptyTrash: () -> Result<Void, TrashRefusal>
    /// The disk images that are mounted now. An image that is mounted stays.
    private let mountedImages: () -> [String]
    /// Finds `brew` at clean time. Tests give a fake one.
    private let brew: () -> Brew?
    /// The program files that `claude` processes execute now. nil means that we cannot tell, and then no version is removed.
    private let openClaudeBinaries: ([String]) -> [String]?
    /// Finds `ollama` at clean time. Tests give a fake one.
    private let ollama: () -> Ollama?
    /// Finds the `hf` tool at clean time. Tests give a fake one. nil means that the folder is removed directly.
    private let hfTool: () -> String?
    /// Finds `git` at clean time. Tests give a fake one. nil means that no worktree is removed.
    private let gitTool: () -> Git?
    /// Finds a JavaScript package manager at clean time. Tests give fake ones.
    private let packageTool: (PackageManager) -> String?
    /// The version requests of the projects, read now. nil means that we cannot tell, and then no runtime is removed.
    private let runtimeRequests: (() -> [RuntimeVersions.Request])?
    /// Reads the free space of the volume. Tests give a fake one.
    private let freeSpace: (URL) -> Int64
    /// Measures an item right before it is deleted. A test can replace it.
    var sizeOf: (URL) -> Int64 = { Sizer.size(of: $0) }
    /// The one call that removes a folder or a file. A test can replace it.
    var deleteItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    /// What happens to a file or folder that passed every check. The default is to delete it for good.
    public let deleteMode: DeleteMode
    /// The one call that moves an item to the Trash (trash mode). A test replaces it, so that no test touches the real Trash.
    var trashItem: (URL) throws -> Void = TrashMover.move
    /// Asked once before each item, never during one. When it says true, the clean ends and the items that are left
    /// are reported as skipped with the reason `stoppedReason`. The item that runs always finishes.
    public var shouldStop: @Sendable () -> Bool = { false }
    /// The reason that the report gives for an item that the user stopped.
    public static let stoppedReason = "Stopped by you"
    /// The working folders of the running programs. A test can replace it.
    var activeDirectories: () -> [String] = { Shell.activeDirectories() }
    /// The clock, and the stale limit of the settings. A worktree that changed inside the limit is not removed. Tests replace the clock.
    var now: () -> Date = Date.init
    public var staleDays = Config.defaultStaleDays
    /// The newest list of working folders, and when we read it (`systemUptime`). A build folder is checked again after the measuring.
    /// We read the list again if the last read is not newer than the start of that measuring, so the list is never older than the measuring.
    private var activeSnapshot: (list: [String], at: TimeInterval) = ([], -.infinity)

    public init(guardian: PathGuard, remaining: ((Finding) -> Int64)? = nil,
                dockerEngine: (() -> Result<DockerEngine, DockerRefusal>)? = nil,
                runningApps: RunningApps = .system, simctl: (() -> Simctl?)? = nil,
                programPaths: @escaping () -> [String] = TestBrowsers.runningProgramPaths,
                emptyTrash: @escaping () -> Result<Void, TrashRefusal> = TrashBin.emptyWithFinder,
                mountedImages: @escaping () -> [String] = Installers.mountedImagePaths,
                brew: (() -> Brew?)? = nil,
                openClaudeBinaries: @escaping ([String]) -> [String]? = ClaudeVersions.openBinaryPaths(among:),
                ollama: (() -> Ollama?)? = nil, hfTool: (() -> String?)? = nil,
                packageTool: ((PackageManager) -> String?)? = nil,
                runtimeRequests: (() -> [RuntimeVersions.Request])? = nil,
                freeSpace: @escaping (URL) -> Int64 = DiskUsage.rawFree(at:),
                deleteMode: DeleteMode = .permanent, git: (() -> Git?)? = nil) {
        self.gitTool = git ?? { Git.find() }
        self.deleteMode = deleteMode
        self.runtimeRequests = runtimeRequests
        self.freeSpace = freeSpace
        self.packageTool = packageTool ?? { Shell.resolve($0.tool) }
        self.hfTool = hfTool ?? { Shell.resolve("hf") }
        self.ollama = ollama ?? { Shell.resolve("ollama").map { Ollama(path: $0) } }
        self.openClaudeBinaries = openClaudeBinaries
        self.brew = brew ?? { Shell.resolve("brew").map { Brew(path: $0) } }
        self.mountedImages = mountedImages
        self.emptyTrash = emptyTrash
        self.guardian = guardian
        self.runningApps = runningApps
        self.programPaths = programPaths
        self.simctl = simctl ?? { Shell.resolve("xcrun").map { Simctl(xcrun: $0) } }
        self.remaining = remaining
        self.dockerEngine = dockerEngine ?? {
            DockerEngine.detect(dockerPath: Shell.resolve("docker"), home: URL(fileURLWithPath: guardian.home))
        }
    }

    public func clean(_ findings: [Finding], progress: ((String) -> Void)? = nil) -> CleanReport {
        var report = CleanReport()
        report.deleteMode = deleteMode
        inventoryLoaded = false
        inventory = nil
        let started = Date()
        let before = freeSpace(URL(fileURLWithPath: guardian.home))
        Log.info("clean start: \(findings.count) items, estimate \(findings.reduce(0) { $0 + $1.bytes }) bytes")
        // Read the running processes again. The state can change after the scan.
        let active = activeDirectories()
        activeSnapshot = (active, -.infinity)

        for (index, finding) in findings.enumerated() {
            // The only place where a stop is checked: between two items. No item is cut in the middle.
            if shouldStop() {
                for left in findings[index...] { skip(left, Cleaner.stoppedReason, &report) }
                break
            }
            progress?(finding.title)
            // What this item freed. The Docker items are counted apart (#40). `defer` runs at the end of each turn, also after `continue`.
            let freedAtStart = report.freed
            defer { if finding.ecosystem == .docker { report.dockerFreed += report.freed - freedAtStart } }

            // Nothing is cleaned while the app that uses it runs. We look again for each item,
            // because the user can start the app while the clean runs.
            if let owner = finding.owner {
                let running = runningApps.take().running(owner)
                if !running.isEmpty {
                    let names = running.joined(separator: " and ")
                    Log.warn("skip \(finding.id): \(names) is running")
                    report.skipped.append("\(finding.location): \(names) is running. Quit it and try again.")
                    for name in running where !report.blockedApps.contains(name) { report.blockedApps.append(name) }
                    continue
                }
            }

            switch finding.action {
            case .removeContents(let dir):
                removeContents(of: dir, finding: finding, into: &report)

            case .removeArtifact(let url):
                guard Catalog.isArtifactFolder(url) else {
                    skip(finding, "not a known build folder", &report); continue
                }
                if let reason = guardian.check(url) {
                    skip(finding, "\(reason)", &report); continue
                }
                let project = url.deletingLastPathComponent().resolvingSymlinksInPath().path
                if active.contains(where: { $0 == project || $0.hasPrefix(project + "/") }) {
                    skip(finding, "project is in use", &report); continue
                }
                removeArtifact(url, finding: finding, into: &report)

            case .owner(let command):
                runOwner(command, finding: finding, into: &report)

            case .docker(let action):
                runDocker(action, finding: finding, into: &report)

            case .simulator(let action):
                runSimulator(action, finding: finding, into: &report)

            case .removeArchive(let url):
                removeArchive(url, finding: finding, into: &report)

            case .removeDeviceSupport(let url):
                removeDeviceSupport(url, finding: finding, into: &report)

            case .removeBrowserCaches(let id):
                removeBrowserCaches(id, finding: finding, into: &report)

            case .removeServiceWorkerSite(let id, let profile, let folder):
                removeServiceWorkerSite(id, profile, folder, finding: finding, into: &report)

            case .removeServiceWorkerStorage(let id):
                removeServiceWorkerStorage(id, finding: finding, into: &report)

            case .removeOldTestBrowsers(let id):
                removeOldTestBrowsers(id, finding: finding, into: &report)

            case .removeUpdateDownloads(let url):
                removeUpdateDownloads(url, finding: finding, into: &report)

            case .removeCacheFolderContents(let name):
                removeCacheFolderContents(name, finding: finding, into: &report)

            case .removeRuntime(let storeID, let tool, let name):
                removeRuntime(storeID, tool, name, finding: finding, into: &report)

            case .globalPackage(let manager, let name):
                runGlobalPackage(manager, name, finding: finding, into: &report)

            case .agent(let action):
                runAgent(action, finding: finding, into: &report)

            case .brew(let action):
                runBrew(action, finding: finding, into: &report)

            case .removeOldLogs(let kind):
                removeOldLogs(kind, finding: finding, into: &report)

            case .removeInstaller(let url):
                removeInstaller(url, finding: finding, into: &report)

            case .emptyTrash:
                runEmptyTrash(finding: finding, into: &report)

            case .worktree(let action):
                runWorktree(action, finding: finding, into: &report)

            case .inform:
                skip(finding, "this item is information only", &report)
            }
        }

        let after = freeSpace(URL(fileURLWithPath: guardian.home))
        report.volumeChange = after - before
        if report.dockerFreed > 0 {
            let engine: String?
            if case .success(let e) = dockerEngine() { engine = e.kind } else { engine = nil }
            report.dockerNote = DockerSpaceNote.message(engine: engine, dockerFreed: report.dockerFreed,
                                                        otherFreed: report.freed - report.dockerFreed, volumeChange: report.volumeChange)
            // Two numbers that are kept apart, so that they can be compared later.
            Log.info("docker: freed inside \(report.dockerFreed) bytes, other items \(report.freed - report.dockerFreed) bytes, "
                     + "Mac free space changed by \(report.volumeChange) bytes, engine \(engine ?? "unknown"), note \(report.dockerNote == nil ? "no" : "yes")")
        }
        Log.info(String(format: "clean done in %.1fs: removed %d, freed %lld bytes, skipped %d, failed %d, volume free changed by %lld bytes",
                        Date().timeIntervalSince(started), report.removed, report.freed,
                        report.skipped.count, report.failed.count, after - before))
        return report
    }

    // MARK: Actions

    /// What the Docker engine holds right now. We read it once for each clean, at the first Docker item.
    private var inventory: DockerInventory?
    private var inventoryLoaded = false

    private func runDocker(_ action: DockerAction, finding: Finding, into report: inout CleanReport) {
        guard let arguments = action.arguments else {
            skip(finding, "the Docker identifier is not valid", &report); return
        }
        guard case .success(let engine) = dockerEngine() else {
            skip(finding, "Docker: the engine is not a checked local engine", &report); return
        }
        if !inventoryLoaded {
            inventory = engine.inventory()
            inventoryLoaded = true
        }
        guard let current = inventory else {
            skip(finding, "Docker: could not read the engine", &report); return
        }

        // Check the object again. It can change after the scan.
        switch action {
        case .removeContainer(let id):
            guard let container = current.containers.first(where: { $0.id == id }) else {
                skip(finding, "the container is already gone", &report); return
            }
            guard container.isStopped else {
                skip(finding, "the container is not stopped (\(container.state))", &report); return
            }
        case .removeImage(let refs):
            let entries = current.images.filter { refs.contains("\($0.repository):\($0.tag)") }
            guard !entries.isEmpty else { skip(finding, "the image is already gone", &report); return }
            // A container may use the image now, or Docker may not say (-1). Then we leave it.
            guard entries.allSatisfy({ $0.containers == 0 }) else {
                skip(finding, "a container uses this image", &report); return
            }
        case .removeVolume(let name):
            guard let volume = current.volumes.first(where: { $0.name == name }) else {
                skip(finding, "the volume is already gone", &report); return
            }
            // A container may use the volume now, or Docker may not say. Docker also refuses by itself.
            guard volume.isRemovable else {
                skip(finding, "the volume is in use, or it is not a local volume", &report); return
            }
        case .stopAndRemoveContainerWithVolumes(let id, let volumes):
            guard let container = current.containers.first(where: { $0.id == id }) else {
                skip(finding, "the container is already gone", &report); return
            }
            guard let mounts = engine.volumes(ofContainers: current.containers.map(\.id)) else {
                skip(finding, "Docker did not say which container uses which volume", &report); return
            }
            for name in volumes {
                guard let v = current.volumes.first(where: { $0.name == name }), v.driver == "local", v.links == 1 else {
                    skip(finding, "volume \(name) is gone, is not local, or is used by another container", &report); return
                }
                guard mounts.filter({ $0.value.contains(name) }).map(\.key) == [id] else {
                    skip(finding, "volume \(name) is used by another container now", &report); return
                }
            }
            // `docker stop` asks the program to end, and waits (10 s by default) before Docker ends it. It is not a force kill.
            if !container.isStopped {
                let stop = engine.run(arguments, timeout: 120)
                guard stop.status == 0, !stop.timedOut else { report.failed.append("\(finding.title): Docker did not stop the container"); return }
                guard let after = engine.inventory(), let now = after.containers.first(where: { $0.id == id }), now.isStopped else {
                    report.failed.append("\(finding.title): the container is still running, so nothing was removed"); return
                }
            }
            var failures: [String] = []
            for (index, extra) in action.followUpArguments.enumerated() {
                let r = engine.run(extra, timeout: 120)
                if r.status != 0 || r.timedOut {
                    if index == 0 { report.failed.append("\(finding.title): the container is stopped, but Docker did not remove it"); return }
                    failures.append(extra.last ?? "")
                }
            }
            let left = remaining?(finding) ?? 0
            let freed = max(0, finding.bytes - left)
            report.freed += freed
            report.removed += 1
            if !failures.isEmpty { report.failed.append("\(finding.title): the container is gone, but Docker kept the volume\(failures.count == 1 ? "" : "s") \(failures.joined(separator: ", "))") }
            Log.info("clean \(finding.id): stopped and removed container and \(volumes.count - failures.count) volumes, estimate \(finding.bytes), left \(left), freed \(freed)")
            return
        case .removeStoppedContainerWithVolumes(let id, let volumes):
            guard let container = current.containers.first(where: { $0.id == id }) else {
                skip(finding, "the container is already gone", &report); return
            }
            guard container.isStopped else { skip(finding, "the container is not stopped (\(container.state))", &report); return }
            // Every volume must still be local, and used by this container only. We ask Docker again who mounts what.
            guard let mounts = engine.volumes(ofContainers: current.containers.map(\.id)) else {
                skip(finding, "Docker did not say which container uses which volume", &report); return
            }
            for name in volumes {
                guard let v = current.volumes.first(where: { $0.name == name }), v.driver == "local", v.links == 1 else {
                    skip(finding, "volume \(name) is gone, is not local, or is used by another container", &report); return
                }
                let users = mounts.filter { $0.value.contains(name) }.map(\.key)
                guard users == [id] else { skip(finding, "volume \(name) is used by another container now", &report); return }
            }
            // The container goes first. Then each volume. Nothing is forced.
            let first = engine.run(arguments, timeout: action.timeout)
            guard first.status == 0, !first.timedOut else { report.failed.append("\(finding.title): Docker did not remove the container"); return }
            var failures: [String] = []
            for extra in action.followUpArguments {
                let r = engine.run(extra, timeout: action.timeout)
                if r.status != 0 || r.timedOut { failures.append(extra.last ?? "") }
            }
            let left = remaining?(finding) ?? 0
            let freed = max(0, finding.bytes - left)
            report.freed += freed
            report.removed += 1
            if !failures.isEmpty { report.failed.append("\(finding.title): the container is gone, but Docker kept the volume\(failures.count == 1 ? "" : "s") \(failures.joined(separator: ", "))") }
            Log.info("clean \(finding.id): removed container and \(volumes.count - failures.count) volumes, estimate \(finding.bytes), left \(left), freed \(freed)")
            return
        }

        let result = engine.run(arguments, timeout: action.timeout)
        guard result.status == 0, !result.timedOut else {
            report.failed.append("\(finding.title): Docker did not remove it")
            return
        }
        let left = remaining?(finding) ?? 0
        let freed = max(0, finding.bytes - left)
        report.freed += freed
        report.removed += 1
        Log.info("clean \(finding.id): removed through docker, estimate \(finding.bytes), left \(left), freed \(freed)")
    }

    // MARK: Xcode

    private func runSimulator(_ action: SimulatorAction, finding: Finding, into report: inout CleanReport) {
        guard let arguments = action.arguments else {
            skip(finding, "the simulator identifier is not valid", &report); return
        }
        guard let simctl = simctl() else { skip(finding, "Xcode tools were not found", &report); return }

        // Read the state again. It can change after the scan.
        guard let devices = simctl.devices() else { skip(finding, "could not read the simulators", &report); return }
        switch action {
        case .deleteRuntime(let id):
            guard let runtimes = simctl.runtimes(), let runtime = runtimes.first(where: { $0.id == id }) else {
                skip(finding, "the runtime is already gone", &report); return
            }
            guard runtime.deletable, runtime.kind != "Bundled with Xcode" else {
                skip(finding, "Xcode cannot remove this runtime", &report); return
            }
            // Xcode shuts down a running simulator when its runtime is deleted. We do not allow that.
            if devices.contains(where: { $0.runtimeIdentifier == runtime.runtimeIdentifier && $0.isActive }) {
                skip(finding, "a simulator that uses this runtime is running", &report); return
            }
        case .deleteDevice(let udid):
            guard let device = devices.first(where: { $0.udid == udid }) else {
                skip(finding, "the simulator is already gone", &report); return
            }
            guard device.isAvailable == true, !device.isActive else {
                skip(finding, "the simulator is running or not usable", &report); return
            }
        }

        let result = simctl.run(arguments, timeout: action.timeout)
        guard result.status == 0, !result.timedOut else {
            report.failed.append("\(finding.title): simctl did not remove it")
            return
        }
        let left = remaining?(finding) ?? 0
        let freed = max(0, finding.bytes - left)
        report.freed += freed
        report.removed += 1
        Log.info("clean \(finding.id): removed through simctl, estimate \(finding.bytes), left \(left), freed \(freed)")
    }

    /// An archive is `Archives/<date>/<name>.xcarchive` in the home folder. Nothing else is accepted.
    private func removeArchive(_ url: URL, finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        let before = report.freed
        let done = removeEach([url], of: finding, into: &report, notTarget: "not an Xcode archive in the archives folder") {
            XcodeArchives.isArchive($0, home: home) && UpdateDownloads.isPlainPath($0)
        }
        if done.removed > 0 {
            report.removed += 1
            Log.info("clean \(finding.id): removed archive \(report.freed - before) bytes — \(url.path)")
        }
    }

    /// The contents of one folder in `~/Library/Caches` (the cache explorer). We check the name, the labels, the type, and every child.
    /// The folder stays, because apps expect it. If the folder is owned by an app that runs, the owner check at the top of `clean` has skipped it.
    private func removeCacheFolderContents(_ name: String, finding: Finding, into report: inout CleanReport) {
        guard CacheExplorer.isFolderName(name) else { skip(finding, "not the name of one cache folder", &report); return }
        guard !CacheExplorer.catalogNames().contains(name) else { skip(finding, "\(name) has its own item in the group of its tool", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        let folder = home.appendingPathComponent("Library/Caches", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        guard (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType == .typeDirectory,
              UpdateDownloads.isPlainPath(folder), UpdateDownloads.isPlainPath(folder.deletingLastPathComponent()) else {
            skip(finding, "not a plain folder", &report); return
        }
        // A folder of iCloud or macOS is emptied only because the owner chose it, with the strongest dialog. The guard still refuses
        // `Library/Caches` itself and everything else.
        let system: String? = CacheExplorer.keepReason(name) != nil ? name : nil
        if let reason = guardian.check(folder, allowingSystemCache: system) { skip(finding, "\(reason)", &report); return }
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            report.failed.append("\(folder.path): cannot read folder"); return
        }
        let before = Sizer.size(of: folder)
        var failures = 0
        for child in children {
            let url = folder.appendingPathComponent(child)
            // The folder may have been swapped for a link after the check above. Every child must still be inside it, and nothing is a link.
            guard UpdateDownloads.isPlainPath(folder), UpdateDownloads.isPlainPath(url),
                  url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
                report.skipped.append("\(url.path): not a plain path inside the folder"); continue
            }
            if let reason = guardian.check(url, allowingSystemCache: system) { report.skipped.append("\(url.path): \(reason)"); continue }
            do { try dispose(url) } catch {
                failures += 1
                Log.error("remove failed \(url.path): \(error.localizedDescription)")
            }
        }
        let left = Sizer.size(of: folder)
        count(max(0, before - left), &report)
        report.removed += 1
        Log.info("clean \(finding.id): emptied \(name), freed \(max(0, before - left)) bytes, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.location): \(failures) items stayed") }
    }

    /// One runtime version. We decide again now: the default may have changed, a program may run from it, a project may ask for it.
    /// If we cannot read the projects, we remove nothing. The path and the guard are checked last.
    private func removeRuntime(_ storeID: String, _ tool: String, _ name: String, finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        guard let store = RuntimeVersions.store(id: storeID), RuntimeVersions.isPart(name), RuntimeVersions.isPart(tool) else {
            skip(finding, "not a runtime version", &report); return
        }
        guard let requests = runtimeRequests else { skip(finding, "could not read the projects, so nothing is removed", &report); return }
        let decision = RuntimeVersions.decide(home: home, requests: requests(), running: programPaths(), measure: false)
        guard let version = decision.removable.first(where: { $0.store == store && $0.tool == tool && $0.name == name }) else {
            let why = decision.kept["\(storeID)/\(tool)/\(name)"] ?? "it is not installed any more"
            skip(finding, "\(name) stays: \(why)", &report); return
        }
        let size = Sizer.size(of: version.url)          // measure first, check last (see removeFolders)
        let rootPrefix = home.appendingPathComponent(store.root, isDirectory: true).standardizedFileURL.path + "/"
        guard version.url.standardizedFileURL.path.hasPrefix(rootPrefix), UpdateDownloads.isPlainPath(version.url) else {
            skip(finding, "not a version folder of the manager", &report); return
        }
        if let reason = guardian.check(version.url) { skip(finding, "\(reason)", &report); return }
        do {
            try dispose(version.url)
            count(size, &report)
            report.removed += 1
            Log.info("clean \(finding.id): removed \(size) bytes — \(version.url.path)")
        } catch {
            Log.error("remove failed \(version.url.path): \(error.localizedDescription)")
            report.failed.append("\(version.url.path): \(error.localizedDescription)")
        }
    }

    /// One global package. The manager removes it. We check the name, list the packages again, and verify the result.
    private func runGlobalPackage(_ manager: PackageManager, _ name: String, finding: Finding, into report: inout CleanReport) {
        guard let args = manager.removeArguments(name), !GlobalPackages.protectedNames.contains(name) else {
            skip(finding, "the package name is not valid, or it is a package manager", &report); return
        }
        guard let tool = packageTool(manager) else { skip(finding, "\(manager.tool) not found", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        guard let before = GlobalPackages.list(manager, tool: tool, home: home, now: Date())?.first(where: { $0.name == name }) else {
            skip(finding, "\(name) is not a global \(manager.label) package any more, or \(manager.tool) did not answer", &report); return
        }
        let result = Shell.run(tool, args, timeout: 300)         // run once: never run a remove twice
        guard result.status == 0, !result.timedOut else {
            let why = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "\(manager.tool) failed"
            report.failed.append("\(finding.title): \(why)"); return
        }
        let still = GlobalPackages.list(manager, tool: tool, home: home, now: Date())?.first { $0.name == name }
        guard still == nil else { report.failed.append("\(finding.title): \(manager.tool) exited 0, but the package is still installed"); return }
        report.freed += before.bytes
        report.removed += 1
        Log.info("clean \(finding.id): \(manager.tool) removed \(name), freed \(before.bytes)")
    }

    // MARK: Worktrees

    private var worktreeGit: Git? { gitTool() }

    private func runWorktree(_ action: WorktreeAction, finding: Finding, into report: inout CleanReport) {
        guard let git = worktreeGit else { skip(finding, "git not found", &report); return }
        switch action {
        case .remove(let repo, let path): removeWorktree(repo: repo, path: path, git: git, finding: finding, into: &report)
        case .prune(let repo, let paths): pruneWorktrees(repo: repo, paths: paths, git: git, finding: finding, into: &report)
        }
    }

    /// One worktree. The state is read at the start of the item (the dialog was open, and the finding can be old) and again right before
    /// the delete, after the measuring. The removal is `git worktree remove <path>`. It is never forced, and a failed command is a failure:
    /// we never delete the files in another way.
    private func removeWorktree(repo: URL, path: URL, git: Git, finding: Finding, into report: inout CleanReport) {
        let first = Worktrees.check(path: path, repo: repo, git: git, guardian: guardian, active: activeDirectories(),
                                    now: now(), staleDays: staleDays)
        if !first.isRemovable { skip(finding, first.reasons.joined(separator: ". "), &report); return }
        var main = first.main ?? repo.path
        let done = removeEach([path], of: finding, into: &report, notTarget: "not a worktree folder", isTarget: {
            Worktrees.isFolderShape($0)
        }, linkText: "a folder in the path is a link", keepReason: { url, measureStart in
            if self.activeSnapshot.at <= measureStart {
                self.activeSnapshot = (self.activeDirectories(), ProcessInfo.processInfo.systemUptime)
            }
            let now = Worktrees.check(path: url, repo: repo, git: git, guardian: self.guardian, active: self.activeSnapshot.list,
                                       now: self.now(), staleDays: self.staleDays)
            main = now.main ?? main
            return now.isRemovable ? nil : now.reasons.joined(separator: ". ")
        }, perform: { url in
            try Worktrees.remove(path: url, mainCheckout: main, git: git)
        })
        if done.removed > 0 {
            report.removed += 1
            Log.info("clean \(finding.id): removed one worktree through git")
        }
    }

    /// The stale records of one repository. Git prunes all of them, so we run it only when they are the ones of the preview.
    private func pruneWorktrees(repo: URL, paths: [String], git: Git, finding: Finding, into report: inout CleanReport) {
        guard let entries = Worktrees.list(git, in: repo) else { skip(finding, "git could not list the worktrees", &report); return }
        if let why = Worktrees.pruneBlocker(entries: entries, previewed: paths, guardian: guardian) { skip(finding, why, &report); return }
        let main = URL(fileURLWithPath: entries[0].path, isDirectory: true)
        let r = git.run(["worktree", "prune"], in: main, timeout: 120)
        guard r.status == 0, !r.timedOut else { report.failed.append("\(finding.title): git worktree prune failed"); return }
        guard let after = Worktrees.list(git, in: main), Worktrees.staleRecords(after).isEmpty else {
            report.failed.append("\(finding.title): git exited 0, but a stale record is still there"); return
        }
        report.removed += 1
        Log.info("clean \(finding.id): pruned \(paths.count) stale records")
    }

    // MARK: AI agents


    private func runAgent(_ action: AgentAction, finding: Finding, into report: inout CleanReport) {
        switch action {
        case .removeCodexRuntime(let url): removeCodexRuntime(url, finding: finding, into: &report)
        case .removeOldClaudeVersions(let names): removeOldClaudeVersions(names, finding: finding, into: &report)
        case .removeOldClaudeDesktopRuntimes(let names):
            removeFolders(ClaudeDesktop.oldRuntimes(home: URL(fileURLWithPath: guardian.home)).filter { names.contains(ClaudeDesktop.runtimeName($0)) },
                          finding: finding, into: &report)
        case .removeAgentCaches(let id): removeAgentCaches(id, finding: finding, into: &report)
        case .removeEditorCaches(let id): removeEditorCaches(id, finding: finding, into: &report)
        case .removeOllamaModel(let name): removeOllamaModel(name, finding: finding, into: &report)
        case .removeHuggingFaceRepo(let id): removeHuggingFaceRepo(id, finding: finding, into: &report)
        case .removeLocalModel(let storeID, let name): removeLocalModel(storeID, name, finding: finding, into: &report)
        case .removeFixedFolders(let id): removeFixedFolders(id, finding: finding, into: &report)
        case .removeOldSessions(let kind, let cutoff, let minimumAgeDays):
            removeOldSessions(kind, cutoff, minimumAgeDays: minimumAgeDays, finding: finding, into: &report)
        case .removeObsoleteExtensions(let id): removeObsoleteExtensions(id, finding: finding, into: &report)
        case .removeClaudeVMBundle:
            removeFolders(ClaudeDesktop.vmBundles(home: URL(fileURLWithPath: guardian.home)), finding: finding, into: &report)
        }
    }

    /// The last step of every file delete. In permanent mode it deletes for good. In trash mode it moves the item to the Trash.
    /// It never falls back to a delete for good: when the move fails, the error goes to the report and the item stays.
    private func dispose(_ url: URL) throws {
        switch deleteMode {
        case .permanent:
            try deleteItem(url)
        case .trash:
            if DeleteMode.isInTrash(url, home: guardian.home) { throw TrashProblem.alreadyInTrash }
            do { try trashItem(url) } catch { throw TrashMover.classify(error) }
        }
    }

    /// Counts bytes of a file delete after it worked: freed in permanent mode, moved to the Trash in trash mode.
    private func count(_ bytes: Int64, _ report: inout CleanReport) {
        if deleteMode == .trash { report.movedToTrash += bytes } else { report.freed += bytes }
    }

    /// What `removeEach` did, so that the caller can write its log line and count the item.
    struct Removal: Equatable {
        var removed = 0
        var failures = 0
    }

    /// A path for a message: the home folder is written as `~`.
    private func shown(_ url: URL) -> String {
        let path = url.path
        if path == guardian.home { return "~" }
        return path.hasPrefix(guardian.home + "/") ? "~" + path.dropFirst(guardian.home.count) : path
    }

    /// The one place that deletes a folder or a file. The order is fixed: measure first, check last, then delete.
    /// - `isTarget` is the shape check of the caller. It runs before the measuring and again after it.
    /// - `keepReason` is a second check of the caller (for example "a program runs from it"). It runs after the measuring, before the guard.
    ///   It gets the time when the measuring of this target began (`systemUptime`), so that it can read the state again
    ///   if its last read is not newer than that time.
    /// - `linkText` is the skip text when the shape check fails because a folder in the path is a link. Without it, `notTarget` is used.
    /// - The guard runs last, right before the delete. The bytes count only after a delete that had no error.
    @discardableResult
    func removeEach(_ targets: [URL], of finding: Finding, into report: inout CleanReport, notTarget: String,
                    isTarget: (URL) -> Bool, linkText: String? = nil,
                    keepReason: ((URL, TimeInterval) -> String?)? = nil,
                    allowingSystemCache: String? = nil,
                    perform: ((URL) throws -> Void)? = nil) -> Removal {
        var result = Removal()
        func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }
        func refuse(_ url: URL, _ reason: String) {
            Log.warn("skip \(url.path): \(reason)")
            report.skipped.append("\(shown(url)): \(reason)")
        }
        func shapeText(_ url: URL) -> String {
            if let linkText, !UpdateDownloads.isPlainPath(url) { return linkText }
            return notTarget
        }
        for url in targets {
            guard exists(url) else { refuse(url, "It is not there now"); continue }
            guard isTarget(url) else { refuse(url, shapeText(url)); continue }
            let measureStart = ProcessInfo.processInfo.systemUptime
            let bytes = sizeOf(url)                       // measure first, check last
            guard exists(url) else { refuse(url, "It is not there now"); continue }
            guard isTarget(url) else { refuse(url, shapeText(url)); continue }
            if let reason = keepReason?(url, measureStart) { refuse(url, reason); continue }
            if let reason = guardian.check(url, allowingSystemCache: allowingSystemCache) { refuse(url, "\(reason)"); continue }
            do {
                if let perform {
                    // A tool removes it (for example git for a worktree). It is not a file delete, so the Trash is not used in either mode.
                    try perform(url)
                    report.freed += bytes
                } else {
                    try dispose(url)
                    count(bytes, &report)
                }
                result.removed += 1
            } catch {
                result.failures += 1
                Log.error("remove failed \(url.path): \(error.localizedDescription)")
                report.failed.append("\(shown(url)): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Removes folders that the caller found again just now. Each one must have an allowed shape, and passes the guard.
    /// We measure first, and check last: the check runs right before the delete, so a link that replaced a folder
    /// during the measuring is caught.
    private func removeFolders(_ entries: [ClaudeDesktop.Entry], finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        let homePrefix = home.standardizedFileURL.path + "/"
        let done = removeEach(entries.map(\.url), of: finding, into: &report, notTarget: "not a folder that we clean") { url in
            let path = url.standardizedFileURL.path
            return path.hasPrefix(homePrefix)
                && AgentCaches.isCleanableShape(relative: String(path.dropFirst(homePrefix.count)))
                && UpdateDownloads.isPlainPath(url)
        }
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) folders, failures \(done.failures)")
    }

    /// The transcripts of one agent that are older than the date of the preview. We list them again, read the age again,
    /// and check the shape, the path, and the guard of each file last.
    private func removeOldSessions(_ kind: AgentSessions.Kind, _ cutoff: Date, minimumAgeDays: Int, finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        // The date of the preview is a ceiling, not a promise. If the clock was wrong at the preview (days ahead), a date in the future
        // would make new sessions look old. So we also never go below the limit now.
        let effective = min(cutoff, Date().addingTimeInterval(-Double(max(minimumAgeDays, 1)) * 86_400))
        let targets = AgentSessions.entries(kind, home: home, olderThan: effective).map(\.url)
        let done = removeEach(targets, of: finding, into: &report, notTarget: "not a transcript") { url in
            AgentSessions.isTranscriptPath(url, kind: kind, home: home) && UpdateDownloads.isPlainPath(url)
        }
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) transcripts, failures \(done.failures)")
    }

    /// The fixed folders of one app. We find them again now, from the table, and check each one last.
    private func removeFixedFolders(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let app = FixedFolders.app(id: id) else { skip(finding, "unknown app", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        let done = removeEach(FixedFolders.targets(of: app, home: home), of: finding, into: &report, notTarget: "not a folder of the app") { url in
            FixedFolders.isTarget(url, of: app, home: home) && UpdateDownloads.isPlainPath(url)
        }
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) folders, failures \(done.failures)")
    }

    /// One model of a desktop app. We find it again now at the exact depth of the store, and check the path and the guard last.
    private func removeLocalModel(_ storeID: String, _ name: String, finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        guard let model = LocalModels.model(storeID: storeID, name: name, home: home) else {
            skip(finding, "\(name) is not a model of the app any more, or the name is not valid", &report); return
        }
        let size = Sizer.size(of: model.url)          // measure first, check last (see removeFolders)
        let rootPrefix = home.appendingPathComponent(model.store.root, isDirectory: true).standardizedFileURL.path + "/"
        guard model.url.standardizedFileURL.path.hasPrefix(rootPrefix), UpdateDownloads.isPlainPath(model.url),
              LocalModels.isModelName(name, in: model.store) else { skip(finding, "not a model of the store", &report); return }
        if let reason = guardian.check(model.url) { skip(finding, "\(reason)", &report); return }
        do {
            try dispose(model.url)
            count(size, &report)
            report.removed += 1
            Log.info("clean \(finding.id): removed \(size) bytes — \(model.url.path)")
        } catch {
            Log.error("remove failed \(model.url.path): \(error.localizedDescription)")
            report.failed.append("\(model.url.path): \(error.localizedDescription)")
        }
    }

    /// One Hugging Face repository. We find its folder again now. With `hf`, the tool removes it. Without, we delete the folder.
    private func removeHuggingFaceRepo(_ id: String, finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        guard HuggingFace.isRepoID(id) else { skip(finding, "the repository id is not valid", &report); return }
        guard let repo = HuggingFace.repo(id: id, home: home, now: Date()) else {
            skip(finding, "\(id) is not in the cache, or a download is running", &report); return
        }
        let size = Sizer.size(of: repo.folder)          // measure first, check last (see removeFolders)
        let hubPrefix = HuggingFace.hubURL(home: home).standardizedFileURL.path + "/"
        guard repo.folder.standardizedFileURL.path.hasPrefix(hubPrefix), UpdateDownloads.isPlainPath(repo.folder) else {
            skip(finding, "not a repository folder of the cache", &report); return
        }
        if let reason = guardian.check(repo.folder) { skip(finding, "\(reason)", &report); return }
        var usedTool = false
        if let tool = hfTool(), let args = HuggingFace.removeArguments(id) {
            usedTool = true
            // The tool picks its cache from these variables. We checked the default folder, so the tool must use that one.
            let result = Shell.run(tool, args, timeout: 300, unsetEnv: ["HF_HOME", "HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE", "XDG_CACHE_HOME"])
            guard result.status == 0, !result.timedOut else { report.failed.append("\(finding.title): " + (result.refused ? "The tool is not safe to run" : "hf cache rm failed")); return }
            // An exit status of 0 is not proof. If the folder that we checked is still there, the tool worked on another cache.
            if FileManager.default.fileExists(atPath: repo.folder.path) {
                Log.warn("hf cache rm exited 0, but \(repo.folder.path) is still there")
                report.failed.append("\(finding.title): hf did not remove the folder that was checked"); return
            }
        } else {
            do { try dispose(repo.folder) } catch {
                Log.error("remove failed \(repo.folder.path): \(error.localizedDescription)")
                report.failed.append("\(repo.folder.path): \(error.localizedDescription)"); return
            }
        }
        let left = FileManager.default.fileExists(atPath: repo.folder.path) ? Sizer.size(of: repo.folder) : 0
        // The `hf` tool removes for good, also in trash mode (it is a tool, not a file delete). Only our own folder delete goes to the Trash.
        if usedTool { report.freed += max(0, size - left) } else { count(max(0, size - left), &report) }
        report.removed += 1
        Log.info("clean \(finding.id): removed \(id), freed \(max(0, size - left))")
    }

    /// One Ollama model, removed by Ollama. We check the name, that the model is still there, and that it is not loaded.
    private func removeOllamaModel(_ name: String, finding: Finding, into report: inout CleanReport) {
        guard Ollama.removeArguments(name) != nil else { skip(finding, "the model name is not valid", &report); return }
        guard let tool = ollama() else { skip(finding, "ollama not found", &report); return }
        guard let models = tool.models(), let model = models.first(where: { $0.name == name }) else {
            skip(finding, "\(name) is not in the list of Ollama, or Ollama did not answer", &report); return
        }
        guard let loaded = tool.loaded() else { skip(finding, "could not tell if \(name) is loaded", &report); return }
        if loaded.contains(name) {
            report.skipped.append("\(finding.location): the model is loaded now. Stop it with ollama stop and try again."); return
        }
        let folder = Ollama.modelsFolder(home: URL(fileURLWithPath: guardian.home))
        let measured = FileManager.default.fileExists(atPath: folder.path)
        let before = measured ? Sizer.size(of: folder) : 0
        let result = tool.remove(name)            // run once: never run a remove twice
        guard let result, result.status == 0, !result.timedOut else {
            report.failed.append("\(finding.title): ollama rm failed"); return
        }
        // A layer that another model uses stays, so the freed size can be smaller than the model. We measure the folder when we can.
        let gone = tool.models()?.contains { $0.name == name } == false
        guard gone else {
            report.failed.append("\(finding.title): ollama rm exited 0, but the model is still listed"); return
        }
        let freed = measured ? max(0, before - Sizer.size(of: folder)) : (gone ? model.bytes : 0)
        report.freed += freed
        report.removed += 1
        Log.info("clean \(finding.id): ollama rm \(name), freed \(freed)")
    }

    /// The cache folders and old logs of one editor. We find them again now, with the age of each log.
    private func removeEditorCaches(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let app = EditorCaches.app(id: id) else { skip(finding, "unknown editor", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        let done = removeEach(EditorCaches.targets(of: app, home: home, now: Date()), of: finding, into: &report,
                              notTarget: "not a cache folder of the editor") { url in
            EditorCaches.isTarget(url, of: app, home: home) && UpdateDownloads.isPlainPath(url)
        }
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) folders, failures \(done.failures)")
    }

    /// The extension folders that the editor marks as obsolete. A folder that the editor lists as installed stays.
    private func removeObsoleteExtensions(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let app = EditorCaches.app(id: id) else { skip(finding, "unknown editor", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        let done = removeEach(EditorCaches.obsoleteExtensions(of: app, home: home), of: finding, into: &report,
                              notTarget: "not an extension folder of the editor") { url in
            EditorCaches.isExtensionTarget(url, of: app, home: home) && UpdateDownloads.isPlainPath(url)
        }
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) obsolete extensions, failures \(done.failures)")
    }

    /// The cache folders of one Electron app. We find them again now, from the table, and check each one.
    private func removeAgentCaches(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let app = AgentCaches.electronApp(id: id) else { skip(finding, "unknown app", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        let done = removeEach(AgentCaches.targets(of: app, home: home), of: finding, into: &report,
                              notTarget: "not a cache folder of the app") { url in
            AgentCaches.isTarget(url, of: app, home: home) && UpdateDownloads.isPlainPath(url)
        }
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) cache folders, failures \(done.failures)")
    }

    /// The old versions of the Claude Code tool. We list them again now and ask which ones run. If we cannot ask, nothing is removed.
    private func removeOldClaudeVersions(_ names: [String], finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        let files = ClaudeVersions.entries(home: home).map { $0.url.path }
        guard let running = openClaudeBinaries(files) else {
            skip(finding, "could not tell which versions run", &report); return
        }
        let old = ClaudeVersions.old(home: home, running: running).old.filter { names.contains($0.name) }
        let done = removeEach(old.map(\.url), of: finding, into: &report, notTarget: "not a version file") { url in
            ClaudeVersions.isVersionName(url.lastPathComponent) && UpdateDownloads.isPlainPath(url)
        }
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) old versions, failures \(done.failures)")
    }

    /// One folder of the Codex runtime cache. We read the kind and the age again now. A running program keeps it.
    private func removeCodexRuntime(_ url: URL, finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        let before = Sizer.size(of: url)             // measure first, check last (see removeFolders)
        guard let kind = CodexRuntimes.kind(of: url, home: home) else {
            skip(finding, "not a folder of the Codex runtime cache", &report); return
        }
        if kind == .staging, (CodexRuntimes.ageDays(of: url, now: Date()) ?? 0) < CodexRuntimes.minimumAgeDays {
            skip(finding, "the install is less than a day old and may still run", &report); return
        }
        if let reason = guardian.check(url) { skip(finding, "\(reason)", &report); return }
        if CodexRuntimes.isInUse(url, programs: programPaths()) {
            report.skipped.append("\(finding.location): a program runs from it. Quit Codex and try again."); return
        }
        do {
            try dispose(url)
            count(before, &report)
            report.removed += 1
            Log.info("clean \(finding.id): removed \(kind) \(before) bytes — \(url.path)")
        } catch {
            Log.error("remove failed \(url.path): \(error.localizedDescription)")
            report.failed.append("\(url.path): \(error.localizedDescription)")
        }
    }

    /// Removes one Homebrew formula through brew. We read the list of leaves again now, and we skip a formula that runs.
    private func runBrew(_ action: BrewAction, finding: Finding, into report: inout CleanReport) {
        guard let args = action.arguments else { skip(finding, "the formula name is not valid", &report); return }
        guard let brew = brew() else { skip(finding, "brew not found", &report); return }
        let name = action.name
        guard let leaves = brew.leaves(), leaves.contains(name) else {
            skip(finding, "\(name) is not a leaf any more, or brew did not answer", &report); return
        }
        let folder = brew.folder(of: name).path
        if programPaths().contains(where: { $0.hasPrefix(folder + "/") }) {
            Log.warn("skip \(name): a program runs from it")
            report.skipped.append("\(finding.location): a program runs from it. Quit it and try again."); return
        }
        let before = brew.bytes(of: name)
        let result = Shell.run(brew.path, args, timeout: action.timeout)
        guard result.status == 0, !result.timedOut else {
            let why = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "brew failed"
            report.failed.append("\(finding.title): \(why)")
            return
        }
        let freed = max(0, before - brew.bytes(of: name))
        report.freed += freed
        report.removed += 1
        Log.info("clean \(finding.id): brew uninstall \(name), freed \(freed)")
    }

    /// The old files of one group in Logs. We find them again now. Each file passes the guard, and nothing else is touched.
    private func removeOldLogs(_ kind: OldLogs.Kind, finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        let targets = OldLogs.entries(kind, home: home, now: Date()).map(\.url)
        let done = removeEach(targets, of: finding, into: &report, notTarget: "not an old log file") { url in
            OldLogs.kind(of: url, home: home) == kind && UpdateDownloads.isPlainPath(url)
        }
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) old files, failures \(done.failures)")
    }

    /// One old installer. We check the path, the file type, the age, and the mounts again now.
    private func removeInstaller(_ url: URL, finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        guard Installers.isInstallerPath(url, home: home) else {
            skip(finding, "not an installer directly in Downloads", &report); return
        }
        guard let installer = Installers.read(url, home: home, now: Date()) else {
            skip(finding, "not a plain file that is old enough", &report); return
        }
        if let reason = guardian.check(url) {
            skip(finding, "\(reason)", &report); return
        }
        let real = url.resolvingSymlinksInPath().path
        if mountedImages().contains(where: { $0 == url.path || $0 == real }) {
            Log.warn("skip \(url.path): the disk image is mounted")
            report.skipped.append("\(url.path): the disk image is open. Eject it and try again."); return
        }
        do {
            try dispose(url)
            count(installer.bytes, &report)
            report.removed += 1
            Log.info("clean \(finding.id): removed installer \(installer.bytes) bytes — \(url.path)")
        } catch {
            Log.error("remove failed \(url.path): \(error.localizedDescription)")
            report.failed.append("\(url.path): \(error.localizedDescription)")
        }
    }

    /// Asks Finder to empty the Trash. We measure the Trash before and after, so the report shows what really left.
    private func runEmptyTrash(finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        let before = TrashBin.bytes(home: home)
        switch emptyTrash() {
        case .failure(let refusal):
            Log.error("empty trash failed: \(refusal.text)")
            report.failed.append("Trash: \(refusal.text)")
        case .success:
            let after = TrashBin.bytes(home: home)
            let freed = max(0, before - after)
            report.freed += freed
            if after > 0 { report.skipped.append("Trash: \(ByteText.string(after)) is still in the Trash. Finder left it.") }
            report.removed += 1
            Log.info("clean \(finding.id): Finder emptied the Trash, \(freed) bytes left (was \(before), now \(after))")
        }
    }

    /// The old versions of the test browsers of one tool. We find them again now. A version that a program runs from stays.
    private func removeOldTestBrowsers(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let tool = TestBrowsers.tool(id: id) else { skip(finding, "unknown tool", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        var programs: [String] = []
        var readAt: TimeInterval = -.infinity
        let done = removeEach(TestBrowsers.oldVersions(of: tool, home: home), of: finding, into: &report,
                              notTarget: "not a version folder of the tool", isTarget: { url in
            TestBrowsers.isVersionFolder(url, of: tool, home: home) && UpdateDownloads.isPlainPath(url)
        }, keepReason: { url, measureStart in
            // Ask again after the measuring: a program may have started from this version in the meantime.
            // Read again if the last read is not newer than the start of this measuring.
            if readAt <= measureStart { programs = self.programPaths(); readAt = ProcessInfo.processInfo.systemUptime }
            return TestBrowsers.isInUse(url, programs: programs) ? "a program runs from it" : nil
        })
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) old versions, failures \(done.failures)")
    }

    /// The `Service Worker/CacheStorage` folders of one browser. Nothing else of the profile is touched.
    private func removeServiceWorkerStorage(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let browser = BrowserCaches.browser(id: id) else { skip(finding, "unknown browser", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        let done = removeEach(BrowserCaches.serviceWorkerTargets(of: browser, home: home), of: finding, into: &report,
                              notTarget: "not Service Worker storage of the browser") { url in
            BrowserCaches.isServiceWorkerTarget(url, of: browser, home: home) && UpdateDownloads.isPlainPath(url)
        }
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) Service Worker folders, failures \(done.failures)")
    }

    /// One website of the Service Worker storage. We find its folder again now, and remove that folder only.
    private func removeServiceWorkerSite(_ id: String, _ profile: String, _ folder: String, finding: Finding, into report: inout CleanReport) {
        guard let browser = BrowserCaches.browser(id: id) else { skip(finding, "unknown browser", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        guard let site = ServiceWorkerSites.site(browser: browser, profile: profile, folder: folder, home: home) else {
            skip(finding, "that website has no saved files any more, or the name is not valid", &report); return
        }
        let size = Sizer.size(of: site.url)          // measure first, check last (see removeFolders)
        let prefix = home.standardizedFileURL.path + "/"
        guard site.url.standardizedFileURL.path.hasPrefix(prefix),
              ServiceWorkerSites.isSiteShape(relative: String(site.url.standardizedFileURL.path.dropFirst(prefix.count))),
              UpdateDownloads.isPlainPath(site.url) else { skip(finding, "not a website folder of the browser", &report); return }
        if let reason = guardian.check(site.url) { skip(finding, "\(reason)", &report); return }
        do {
            try dispose(site.url)
            count(size, &report)
            report.removed += 1
            Log.info("clean \(finding.id): removed \(size) bytes — \(site.url.path)")
        } catch {
            Log.error("remove failed \(site.url.path): \(error.localizedDescription)")
            report.failed.append("\(site.url.path): \(error.localizedDescription)")
        }
    }

    /// The caches of one browser. We find the folders again now, from a fixed list of names. Nothing else is touched.
    private func removeBrowserCaches(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let browser = BrowserCaches.browser(id: id) else { skip(finding, "unknown browser", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        let done = removeEach(BrowserCaches.targets(of: browser, home: home), of: finding, into: &report,
                              notTarget: "not a cache folder of the browser") { url in
            BrowserCaches.isTarget(url, of: browser, home: home) && UpdateDownloads.isPlainPath(url)
        }
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) cache folders, failures \(done.failures)")
    }

    /// The old update files of one app. We look at the age again now, so that an update that started after the scan stays.
    /// Only the children of two folders can go. Nothing else in the cache of the app is touched.
    private func removeUpdateDownloads(_ sparkle: URL, finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        guard UpdateDownloads.isSparkleFolder(sparkle, home: home), UpdateDownloads.isPlainPath(sparkle) else {
            skip(finding, "not the update folder of an app", &report); return
        }
        let sparklePrefix = sparkle.standardizedFileURL.path + "/"
        let done = removeEach(UpdateDownloads.staleItems(in: sparkle, now: Date()), of: finding, into: &report,
                              notTarget: "not an old update item of the app") { url in
            // One of the cleaned folders, then one child of it. Nothing deeper, and no link on the way.
            let path = url.standardizedFileURL.path
            let parts = path.hasPrefix(sparklePrefix) ? path.dropFirst(sparklePrefix.count).split(separator: "/").map(String.init) : []
            return UpdateDownloads.isSparkleFolder(sparkle, home: home) && parts.count == 2
                && UpdateDownloads.cleanedFolders.contains(parts[0]) && UpdateDownloads.isPlainPath(url)
        }
        if done.removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(done.removed) old update items, failures \(done.failures)")
    }

    /// One folder of device support files, `<platform> DeviceSupport/<name>` in the Xcode folder. Nothing else is accepted.
    private func removeDeviceSupport(_ url: URL, finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        let before = report.freed
        let done = removeEach([url], of: finding, into: &report, notTarget: "not a device support folder of Xcode") {
            DeviceSupport.isDeviceSupport($0, home: home) && UpdateDownloads.isPlainPath($0)
        }
        if done.removed > 0 {
            report.removed += 1
            Log.info("clean \(finding.id): removed \(report.freed - before) bytes — \(url.path)")
        }
    }

    private func skip(_ finding: Finding, _ reason: String, _ report: inout CleanReport) {
        Log.warn("skip \(finding.id): \(reason) — \(finding.location)")
        report.skipped.append("\(finding.location): \(reason)")
    }

    private func removeContents(of dir: URL, finding: Finding, into report: inout CleanReport) {
        if let reason = guardian.check(dir) { skip(finding, "\(reason)", &report); return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            Log.error("cannot read \(dir.path)")
            report.failed.append("\(finding.location): cannot read folder"); return
        }
        var failures = 0
        for name in names {
            let child = dir.appendingPathComponent(name)
            if let reason = guardian.check(child) {
                Log.warn("skip child \(child.path): \(reason)")
                report.skipped.append("\(child.path): \(reason)"); continue
            }
            do { try dispose(child) } catch {
                failures += 1
                Log.error("remove failed \(child.path): \(error.localizedDescription)")
            }
        }
        report.removed += 1
        let left = Sizer.size(of: dir)
        let freed = max(0, finding.bytes - left)
        count(freed, &report)
        Log.info("clean \(finding.id): estimate \(finding.bytes), left \(left), freed \(freed), failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.location): \(failures) items stayed") }
    }

    /// One build folder. `clean` has checked the name, the guard, and the active projects. The helper checks the name, the path,
    /// the active projects, and the guard again, after it has measured the folder.
    private func removeArtifact(_ url: URL, finding: Finding, into report: inout CleanReport) {
        let before = report.freed
        let done = removeEach([url], of: finding, into: &report, notTarget: "not a known build folder", isTarget: {
            UpdateDownloads.isPlainPath($0) && Catalog.isArtifactFolder($0)
        }, linkText: "a folder in the path is a link", keepReason: { url, measureStart in
            if self.activeSnapshot.at <= measureStart {
                self.activeSnapshot = (self.activeDirectories(), ProcessInfo.processInfo.systemUptime)
            }
            let project = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            return self.activeSnapshot.list.contains(where: { $0 == project || $0.hasPrefix(project + "/") }) ? "project is in use" : nil
        })
        if done.removed > 0 {
            report.removed += 1
            Log.info("clean \(finding.id): removed \(report.freed - before) bytes — \(url.path)")
        }
    }

    private func runOwner(_ command: OwnerCommand, finding: Finding, into report: inout CleanReport) {
        let result: ShellResult
        if command.toolName == "docker" {
            // Docker runs only on a local engine that we check again right now.
            switch dockerEngine() {
            case .failure(let why):
                skip(finding, "Docker: \(why)", &report); return
            case .success(let engine):
                result = engine.run(command.arguments, timeout: command.timeout)
            }
        } else if command.toolName == "xcrun" {
            guard let simctl = simctl() else { skip(finding, "xcrun not found", &report); return }
            result = Shell.run(simctl.xcrun, command.arguments, timeout: command.timeout)
        } else {
            guard let tool = Shell.resolve(command.toolName) else {
                skip(finding, "\(command.toolName) not found", &report); return
            }
            result = Shell.run(tool, command.arguments, timeout: command.timeout)
        }
        guard result.status == 0, !result.timedOut else {
            report.failed.append("\(finding.title): " + (result.refused ? "The tool is not safe to run" : "\(command.toolName) failed"))
            return
        }
        // Ask again. The tool may keep files that it never removes.
        let left = remaining?(finding) ?? 0
        let freed = max(0, finding.bytes - left)
        report.freed += freed
        report.removed += 1
        Log.info("clean \(finding.id): estimate \(finding.bytes), left \(left), freed \(freed)")
    }
}
