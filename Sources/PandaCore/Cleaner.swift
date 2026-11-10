import Foundation

/// Deletes items permanently. Every path passes the guard first.
/// The app shows a preview before it calls this.
/// The report counts the space that really left the disk. It does not repeat the scan estimate.
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

    public init(guardian: PathGuard, remaining: ((Finding) -> Int64)? = nil,
                dockerEngine: (() -> Result<DockerEngine, DockerRefusal>)? = nil,
                runningApps: RunningApps = .system, simctl: (() -> Simctl?)? = nil,
                programPaths: @escaping () -> [String] = TestBrowsers.runningProgramPaths,
                emptyTrash: @escaping () -> Result<Void, TrashRefusal> = TrashBin.emptyWithFinder,
                mountedImages: @escaping () -> [String] = Installers.mountedImagePaths,
                brew: (() -> Brew?)? = nil,
                openClaudeBinaries: @escaping ([String]) -> [String]? = ClaudeVersions.openBinaryPaths(among:),
                ollama: (() -> Ollama?)? = nil, hfTool: (() -> String?)? = nil) {
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
        inventoryLoaded = false
        inventory = nil
        let started = Date()
        let before = DiskUsage.rawFree(at: URL(fileURLWithPath: guardian.home))
        Log.info("clean start: \(findings.count) items, estimate \(findings.reduce(0) { $0 + $1.bytes }) bytes")
        // Read the running processes again. The state can change after the scan.
        let active = Shell.activeDirectories()

        for finding in findings {
            progress?(finding.title)

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
                guard Catalog.isArtifactName(url.lastPathComponent) else {
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

            case .removeServiceWorkerStorage(let id):
                removeServiceWorkerStorage(id, finding: finding, into: &report)

            case .removeOldTestBrowsers(let id):
                removeOldTestBrowsers(id, finding: finding, into: &report)

            case .removeUpdateDownloads(let url):
                removeUpdateDownloads(url, finding: finding, into: &report)

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

            case .inform:
                skip(finding, "this item is information only", &report)
            }
        }

        let after = DiskUsage.rawFree(at: URL(fileURLWithPath: guardian.home))
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
        guard XcodeArchives.isArchive(url, home: URL(fileURLWithPath: guardian.home)) else {
            skip(finding, "not an Xcode archive in the archives folder", &report); return
        }
        if let reason = guardian.check(url) { skip(finding, "\(reason)", &report); return }
        do {
            try FileManager.default.removeItem(at: url)
            report.freed += finding.bytes
            report.removed += 1
            Log.info("clean \(finding.id): removed archive \(finding.bytes) bytes — \(url.path)")
        } catch {
            Log.error("remove failed \(url.path): \(error.localizedDescription)")
            report.failed.append("\(url.path): \(error.localizedDescription)")
        }
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
        case .removeOldSessions(let kind, let cutoff): removeOldSessions(kind, cutoff, finding: finding, into: &report)
        case .removeObsoleteExtensions(let id): removeObsoleteExtensions(id, finding: finding, into: &report)
        case .removeClaudeVMBundle:
            removeFolders(ClaudeDesktop.vmBundles(home: URL(fileURLWithPath: guardian.home)), finding: finding, into: &report)
        }
    }

    /// Removes folders that the caller found again just now. Each one must have an allowed shape, and passes the guard.
    /// We measure first, and check last: the check runs right before the delete, so a link that replaced a folder
    /// during the measuring is caught.
    private func removeFolders(_ entries: [ClaudeDesktop.Entry], finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        let homePrefix = home.standardizedFileURL.path + "/"
        var removed = 0, failures = 0
        for entry in entries {
            let path = entry.url.standardizedFileURL.path
            let size = Sizer.size(of: entry.url)
            guard path.hasPrefix(homePrefix),
                  AgentCaches.isCleanableShape(relative: String(path.dropFirst(homePrefix.count))),
                  UpdateDownloads.isPlainPath(entry.url) else {
                report.skipped.append("\(entry.url.path): not a folder that we clean"); continue
            }
            if let reason = guardian.check(entry.url) {
                report.skipped.append("\(entry.url.path): \(reason)"); continue
            }
            do {
                try FileManager.default.removeItem(at: entry.url)
                report.freed += size
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(entry.url.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) folders, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.title): \(failures) folders stayed") }
    }

    /// The transcripts of one agent that are older than the date of the preview. We list them again, read the age again,
    /// and check the shape, the path, and the guard of each file last.
    private func removeOldSessions(_ kind: AgentSessions.Kind, _ cutoff: Date, finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        var removed = 0, failures = 0
        for entry in AgentSessions.entries(kind, home: home, olderThan: cutoff) {
            guard AgentSessions.isTranscriptPath(entry.url, kind: kind, home: home), UpdateDownloads.isPlainPath(entry.url) else {
                report.skipped.append("\(entry.url.path): not a transcript"); continue
            }
            if let reason = guardian.check(entry.url) { report.skipped.append("\(entry.url.path): \(reason)"); continue }
            do {
                try FileManager.default.removeItem(at: entry.url)
                report.freed += entry.bytes
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(entry.url.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) transcripts, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.title): \(failures) files stayed") }
    }

    /// The fixed folders of one app. We find them again now, from the table, and check each one last.
    private func removeFixedFolders(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let app = FixedFolders.app(id: id) else { skip(finding, "unknown app", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        var removed = 0, failures = 0
        for url in FixedFolders.targets(of: app, home: home) {
            let size = Sizer.size(of: url)           // measure first, check last (see removeFolders)
            guard FixedFolders.isTarget(url, of: app, home: home), UpdateDownloads.isPlainPath(url) else {
                report.skipped.append("\(url.path): not a folder of the app"); continue
            }
            if let reason = guardian.check(url) { report.skipped.append("\(url.path): \(reason)"); continue }
            do {
                try FileManager.default.removeItem(at: url)
                report.freed += size
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(url.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) folders, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.title): \(failures) folders stayed") }
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
            try FileManager.default.removeItem(at: model.url)
            report.freed += size
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
        if let tool = hfTool(), let args = HuggingFace.removeArguments(id) {
            let result = Shell.run(tool, args, timeout: 300)
            guard result.status == 0, !result.timedOut else { report.failed.append("\(finding.title): hf cache rm failed"); return }
        } else {
            do { try FileManager.default.removeItem(at: repo.folder) } catch {
                Log.error("remove failed \(repo.folder.path): \(error.localizedDescription)")
                report.failed.append("\(repo.folder.path): \(error.localizedDescription)"); return
            }
        }
        let left = FileManager.default.fileExists(atPath: repo.folder.path) ? Sizer.size(of: repo.folder) : 0
        report.freed += max(0, size - left)
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
        let freed = measured ? max(0, before - Sizer.size(of: folder)) : (gone ? model.bytes : 0)
        report.freed += freed
        report.removed += 1
        Log.info("clean \(finding.id): ollama rm \(name), freed \(freed)")
    }

    /// The cache folders and old logs of one editor. We find them again now, with the age of each log.
    private func removeEditorCaches(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let app = EditorCaches.app(id: id) else { skip(finding, "unknown editor", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        var removed = 0, failures = 0
        for url in EditorCaches.targets(of: app, home: home, now: Date()) {
            let size = Sizer.size(of: url)           // measure first, check last (see removeFolders)
            guard EditorCaches.isTarget(url, of: app, home: home), UpdateDownloads.isPlainPath(url) else {
                report.skipped.append("\(url.path): not a cache folder of the editor"); continue
            }
            if let reason = guardian.check(url) {
                report.skipped.append("\(url.path): \(reason)"); continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                report.freed += size
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(url.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) folders, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.title): \(failures) folders stayed") }
    }

    /// The extension folders that the editor marks as obsolete. A folder that the editor lists as installed stays.
    private func removeObsoleteExtensions(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let app = EditorCaches.app(id: id) else { skip(finding, "unknown editor", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        var removed = 0, failures = 0
        for url in EditorCaches.obsoleteExtensions(of: app, home: home) {
            let size = Sizer.size(of: url)           // measure first, check last (see removeFolders)
            guard EditorCaches.isExtensionTarget(url, of: app, home: home), UpdateDownloads.isPlainPath(url) else {
                report.skipped.append("\(url.path): not an extension folder of the editor"); continue
            }
            if let reason = guardian.check(url) {
                report.skipped.append("\(url.path): \(reason)"); continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                report.freed += size
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(url.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) obsolete extensions, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.title): \(failures) folders stayed") }
    }

    /// The cache folders of one Electron app. We find them again now, from the table, and check each one.
    private func removeAgentCaches(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let app = AgentCaches.electronApp(id: id) else { skip(finding, "unknown app", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        var removed = 0, failures = 0
        for url in AgentCaches.targets(of: app, home: home) {
            let size = Sizer.size(of: url)           // measure first, check last (see removeFolders)
            guard AgentCaches.isTarget(url, of: app, home: home), UpdateDownloads.isPlainPath(url) else {
                report.skipped.append("\(url.path): not a cache folder of the app"); continue
            }
            if let reason = guardian.check(url) {
                report.skipped.append("\(url.path): \(reason)"); continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                report.freed += size
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(url.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) cache folders, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.title): \(failures) folders stayed") }
    }

    /// The old versions of the Claude Code tool. We list them again now and ask which ones run. If we cannot ask, nothing is removed.
    private func removeOldClaudeVersions(_ names: [String], finding: Finding, into report: inout CleanReport) {
        let home = URL(fileURLWithPath: guardian.home)
        let files = ClaudeVersions.entries(home: home).map { $0.url.path }
        guard let running = openClaudeBinaries(files) else {
            skip(finding, "could not tell which versions run", &report); return
        }
        var removed = 0, failures = 0
        for entry in ClaudeVersions.old(home: home, running: running).old where names.contains(entry.name) {
            guard ClaudeVersions.isVersionName(entry.name), UpdateDownloads.isPlainPath(entry.url) else {
                report.skipped.append("\(entry.url.path): not a version file"); continue
            }
            if let reason = guardian.check(entry.url) {
                report.skipped.append("\(entry.url.path): \(reason)"); continue
            }
            do {
                try FileManager.default.removeItem(at: entry.url)
                report.freed += entry.bytes
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(entry.url.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) old versions, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.title): \(failures) files stayed") }
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
            try FileManager.default.removeItem(at: url)
            report.freed += before
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
        var removed = 0, failures = 0
        for entry in OldLogs.entries(kind, home: home, now: Date()) {
            if let reason = guardian.check(entry.url) {
                report.skipped.append("\(entry.url.path): \(reason)"); continue
            }
            do {
                try FileManager.default.removeItem(at: entry.url)
                report.freed += entry.bytes
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(entry.url.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) old files, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.location): \(failures) files stayed") }
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
            try FileManager.default.removeItem(at: url)
            report.freed += installer.bytes
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
        let programs = programPaths()
        var removed = 0, failures = 0
        for url in TestBrowsers.oldVersions(of: tool, home: home) {
            guard TestBrowsers.isVersionFolder(url, of: tool, home: home), UpdateDownloads.isPlainPath(url) else {
                report.skipped.append("\(url.path): not a version folder of the tool"); continue
            }
            if TestBrowsers.isInUse(url, programs: programs) {
                Log.warn("skip \(url.path): a program runs from it")
                report.skipped.append("\(url.path): a program runs from it"); continue
            }
            if let reason = guardian.check(url) {
                Log.warn("skip \(url.path): \(reason)")
                report.skipped.append("\(url.path): \(reason)"); continue
            }
            let size = Sizer.size(of: url)
            do {
                try FileManager.default.removeItem(at: url)
                report.freed += size
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(url.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) old versions, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.title): \(failures) folders stayed") }
    }

    /// The `Service Worker/CacheStorage` folders of one browser. Nothing else of the profile is touched.
    private func removeServiceWorkerStorage(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let browser = BrowserCaches.browser(id: id) else { skip(finding, "unknown browser", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        var removed = 0, failures = 0
        for url in BrowserCaches.serviceWorkerTargets(of: browser, home: home) {
            guard BrowserCaches.isServiceWorkerTarget(url, of: browser, home: home), UpdateDownloads.isPlainPath(url) else {
                report.skipped.append("\(url.path): not Service Worker storage of the browser"); continue
            }
            if let reason = guardian.check(url) {
                Log.warn("skip \(url.path): \(reason)")
                report.skipped.append("\(url.path): \(reason)"); continue
            }
            let size = Sizer.size(of: url)
            do {
                try FileManager.default.removeItem(at: url)
                report.freed += size
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(url.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) Service Worker folders, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.title): \(failures) folders stayed") }
    }

    /// The caches of one browser. We find the folders again now, from a fixed list of names. Nothing else is touched.
    private func removeBrowserCaches(_ id: String, finding: Finding, into report: inout CleanReport) {
        guard let browser = BrowserCaches.browser(id: id) else { skip(finding, "unknown browser", &report); return }
        let home = URL(fileURLWithPath: guardian.home)
        var removed = 0, failures = 0
        for url in BrowserCaches.targets(of: browser, home: home) {
            guard BrowserCaches.isTarget(url, of: browser, home: home), UpdateDownloads.isPlainPath(url) else {
                report.skipped.append("\(url.path): not a cache folder of the browser"); continue
            }
            if let reason = guardian.check(url) {
                Log.warn("skip \(url.path): \(reason)")
                report.skipped.append("\(url.path): \(reason)"); continue
            }
            let size = Sizer.size(of: url)
            do {
                try FileManager.default.removeItem(at: url)
                report.freed += size
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(url.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) cache folders, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.title): \(failures) folders stayed") }
    }

    /// The old update files of one app. We look at the age again now, so that an update that started after the scan stays.
    /// Only the children of two folders can go. Nothing else in the cache of the app is touched.
    private func removeUpdateDownloads(_ sparkle: URL, finding: Finding, into report: inout CleanReport) {
        guard UpdateDownloads.isSparkleFolder(sparkle, home: URL(fileURLWithPath: guardian.home)),
              UpdateDownloads.isPlainPath(sparkle) else {
            skip(finding, "not the update folder of an app", &report); return
        }
        var removed = 0, failures = 0
        for item in UpdateDownloads.staleItems(in: sparkle, now: Date()) {
            if let reason = guardian.check(item) {
                Log.warn("skip child \(item.path): \(reason)")
                report.skipped.append("\(item.path): \(reason)"); continue
            }
            let size = Sizer.size(of: item)
            do {
                try FileManager.default.removeItem(at: item)
                report.freed += size
                removed += 1
            } catch {
                failures += 1
                Log.error("remove failed \(item.path): \(error.localizedDescription)")
            }
        }
        if removed > 0 { report.removed += 1 }
        Log.info("clean \(finding.id): removed \(removed) old update items, failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.location): \(failures) items stayed") }
    }

    /// One folder of device support files, `<platform> DeviceSupport/<name>` in the Xcode folder. Nothing else is accepted.
    private func removeDeviceSupport(_ url: URL, finding: Finding, into report: inout CleanReport) {
        guard DeviceSupport.isDeviceSupport(url, home: URL(fileURLWithPath: guardian.home)) else {
            skip(finding, "not a device support folder of Xcode", &report); return
        }
        if let reason = guardian.check(url) { skip(finding, "\(reason)", &report); return }
        do {
            try FileManager.default.removeItem(at: url)
            report.freed += finding.bytes
            report.removed += 1
            Log.info("clean \(finding.id): removed \(finding.bytes) bytes — \(url.path)")
        } catch {
            Log.error("remove failed \(url.path): \(error.localizedDescription)")
            report.failed.append("\(url.path): \(error.localizedDescription)")
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
            do { try FileManager.default.removeItem(at: child) } catch {
                failures += 1
                Log.error("remove failed \(child.path): \(error.localizedDescription)")
            }
        }
        report.removed += 1
        let left = Sizer.size(of: dir)
        let freed = max(0, finding.bytes - left)
        report.freed += freed
        Log.info("clean \(finding.id): estimate \(finding.bytes), left \(left), freed \(freed), failures \(failures)")
        if failures > 0 { report.failed.append("\(finding.location): \(failures) items stayed") }
    }

    private func removeArtifact(_ url: URL, finding: Finding, into report: inout CleanReport) {
        do {
            try FileManager.default.removeItem(at: url)
            report.freed += finding.bytes
            report.removed += 1
            Log.info("clean \(finding.id): removed \(finding.bytes) bytes — \(url.path)")
        } catch {
            Log.error("remove failed \(url.path): \(error.localizedDescription)")
            report.failed.append("\(url.path): \(error.localizedDescription)")
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
            report.failed.append("\(finding.title): \(command.toolName) failed")
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
