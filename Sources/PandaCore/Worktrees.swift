import Foundation

/// What the cleaner may do with a git worktree. Each case has one fixed shape.
/// Git does the removal. We never delete the files of a worktree ourselves, and we never delete a branch.
public enum WorktreeAction: Sendable, Equatable {
    /// One linked worktree. The cleaner runs `git worktree remove <path>` and nothing else. `repo` is the main checkout of the preview.
    /// The cleaner reads the worktree list again, so it never trusts the two paths alone.
    case remove(repo: URL, path: URL)
    /// The records of worktrees whose folder is gone (`git worktree prune`). `paths` are the stale records that the preview showed.
    /// Git prunes all stale records of the repository, so the cleaner runs it only when no other record is stale.
    case prune(repo: URL, paths: [String])
}

/// The `git` tool. It has one fixed path (see `Shell.systemTools`), and the commands that we start are read only,
/// except `worktree remove` and `worktree prune` (see `Worktrees`). A command never goes through a shell.
public struct Git: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    /// The one path of the system git. We never search for it, so a file with the same name in a folder that the user can write to is never used.
    /// (`Shell.resolve("git")` still searches, for the tools that use it that way. Worktrees do not.)
    public static let systemPath = "/usr/bin/git"

    /// The system git, or nil when it is not installed.
    /// Without the developer tools, `/usr/bin/git` is a stub that opens an "install developer tools" prompt. We start it only when
    /// `xcode-select -p` succeeds and prints a folder that exists. Tests replace the probe.
    nonisolated(unsafe) static var developerToolsProbe: () -> Bool = {
        let r = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10, quiet: true)
        let folder = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !folder.isEmpty && FileManager.default.fileExists(atPath: folder)
    }
    private static let logOnce = LogOnce()
    private final class LogOnce: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; let was = done; done = true; return !was }
    }

    public static func find() -> Git? {
        guard FileManager.default.isExecutableFile(atPath: systemPath) else { return nil }
        guard developerToolsProbe() else {
            if logOnce.first() { Log.info("git worktrees skipped: the developer tools are not installed") }
            return nil
        }
        return Git(path: systemPath)
    }

    /// Variables that can point the tool at another repository or toolchain. We remove every variable that starts with `GIT_`
    /// (read from the environment now) and `DEVELOPER_DIR`, so that `-C` decides.
    static var unsetVariables: [String] {
        let fixed = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
                     "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX", "DEVELOPER_DIR"]
        let present = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("GIT_") }
        return Array(Set(fixed + present))
    }

    /// Runs `git -C <dir> <args>`. `--no-optional-locks` keeps a read from writing the index. `core.fsmonitor=false` keeps a
    /// repository setting from starting a program.
    func run(_ args: [String], in dir: URL, timeout: TimeInterval = 60) -> ShellResult {
        Shell.run(path, ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", dir.path] + args,
                  timeout: timeout, unsetEnv: Self.unsetVariables, quiet: true)
    }
}

/// One line of `git worktree list --porcelain -z`.
public struct WorktreeEntry: Equatable, Sendable {
    public var path: String
    public var head: String?
    /// The short branch name. nil when the HEAD is detached.
    public var branch: String?
    public var bare = false
    /// nil: not locked. The text is the reason, and it can be empty.
    public var locked: String?
    /// nil: git does not call the record stale. The text is the reason of git.
    public var prunable: String?
}

/// What we read about one worktree. Nothing here changes the repository.
public struct WorktreeCheck: Equatable, Sendable {
    /// Why the worktree cannot be removed now. Empty means that it can.
    public var reasons: [String] = []
    /// True for the main checkout (the first line of the list). It is never removable.
    public var isMain = false
    public var entry: WorktreeEntry?
    /// The main checkout of the repository, as git reports it.
    public var main: String?
    public var lastCommit: Date?
    /// Other local branches that contain the commit of the worktree.
    public var mergedInto: [String] = []
    public var onRemote = false
    public var uniqueCommits: Int?

    public var isRemovable: Bool { reasons.isEmpty }
}

public enum Worktrees {
    // MARK: Read

    /// The worktrees of the repository that holds `dir`. nil when git fails (not a repository, no git, or a git that is too old for -z).
    public static func list(_ git: Git, in dir: URL) -> [WorktreeEntry]? {
        let r = git.run(["worktree", "list", "--porcelain", "-z"], in: dir)
        guard r.status == 0, !r.timedOut else { return nil }
        return parse(r.stdout)
    }

    /// The NUL separated form: a record is a run of fields that ends with an empty field.
    static func parse(_ text: String) -> [WorktreeEntry] {
        var out: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for field in text.components(separatedBy: "\0") {
            if field.isEmpty {
                if let c = current { out.append(c); current = nil }
                continue
            }
            if field.hasPrefix("worktree ") {
                if let c = current { out.append(c) }
                current = WorktreeEntry(path: String(field.dropFirst("worktree ".count)))
                continue
            }
            guard current != nil else { continue }
            if field.hasPrefix("HEAD ") { current?.head = String(field.dropFirst(5)) }
            else if field.hasPrefix("branch ") {
                let ref = String(field.dropFirst(7))
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            }
            else if field == "bare" { current?.bare = true }
            else if field == "locked" { current?.locked = "" }
            else if field.hasPrefix("locked ") { current?.locked = String(field.dropFirst(7)) }
            else if field == "prunable" { current?.prunable = "" }
            else if field.hasPrefix("prunable ") { current?.prunable = String(field.dropFirst(9)) }
        }
        if let c = current { out.append(c) }
        return out
    }

    /// The path with its links resolved. A folder that is gone is resolved through its nearest folder that exists, so that the spelling
    /// (`/private/var` or `/var`) is the same as for a folder that is there.
    private static func real(_ path: String) -> String {
        var url = URL(fileURLWithPath: path)
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            tail.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        var base = url.resolvingSymlinksInPath()
        for part in tail { base.appendPathComponent(part) }
        return base.path
    }

    private static func type(of path: String) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
    }

    /// A commit id: 40 or 64 hex digits. Nothing else goes into a command as a revision.
    static func isCommitID(_ text: String?) -> Bool {
        guard let text, text.count == 40 || text.count == 64 else { return false }
        return text.allSatisfy { $0.isHexDigit } && text.contains { $0 != "0" }
    }

    /// The shape of a worktree folder: a real folder, no link in its path, and a `.git` file inside (a linked worktree has a file, the main
    /// checkout has a folder). The cleaner checks this before and after the measuring.
    static func isFolderShape(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard type(of: path) == .typeDirectory, UpdateDownloads.isPlainPath(url) else { return false }
        return type(of: path + "/.git") == .typeRegular
    }

    /// Everything that decides if one worktree may be removed now. It is read again at each call: the scan, the start of the item,
    /// and right before the delete. The reasons are plain sentences for the user.
    /// - `active` are the working folders of the running programs.
    public static func check(path: URL, repo: URL, git: Git, guardian: PathGuard, active: [String],
                             now: Date = Date(), staleDays: Int = Config.defaultStaleDays) -> WorktreeCheck {
        var result = WorktreeCheck()
        let target = path.standardizedFileURL.path

        guard let entries = list(git, in: repo), let first = entries.first else {
            result.reasons = ["Git could not list the worktrees of this repository"]; return result
        }
        result.main = first.path
        guard !first.bare else { result.reasons = ["The repository is a bare repository"]; return result }
        let mainReal = real(first.path)
        guard let entry = entries.first(where: { real($0.path) == real(target) }) else {
            result.reasons = ["It is not a worktree of this repository any more"]; return result
        }
        result.entry = entry
        if real(entry.path) == mainReal {
            result.isMain = true
            result.reasons = ["This is the main checkout of the repository. It is never removed"]; return result
        }
        guard type(of: target) != nil else { result.reasons = ["The folder is not there now"]; return result }
        guard UpdateDownloads.isPlainPath(path), type(of: target) == .typeDirectory else {
            result.reasons = ["It is a link, or a folder in its path is a link"]; return result
        }
        guard type(of: target + "/.git") == .typeRegular else {
            result.reasons = ["It has no .git file, so it is not a linked worktree"]; return result
        }
        // The other worktrees and the main checkout must stay: nothing may sit inside the one that we remove,
        // and it must not sit inside the `.git` folder or inside another linked worktree.
        for other in entries where real(other.path) != real(target) {
            let o = real(other.path)
            if o.hasPrefix(real(target) + "/") { result.reasons = ["Another worktree is inside this folder"]; return result }
            if other.path != first.path, real(target).hasPrefix(o + "/") { result.reasons = ["It is inside another worktree"]; return result }
        }
        if real(target).hasPrefix(mainReal + "/.git/") { result.reasons = ["It is inside the .git folder"]; return result }
        if let reason = guardian.check(path) { result.reasons = ["Trash Panda does not touch this place: \(reason)"]; return result }
        // The worktree must belong to this repository: its own common directory is the .git folder of the main checkout.
        let common = git.run(["rev-parse", "--git-common-dir"], in: path)
        let commonPath = common.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonReal = real(URL(fileURLWithPath: commonPath, relativeTo: path).path)
        guard common.status == 0, !commonPath.isEmpty, commonReal == mainReal + "/.git" else {
            result.reasons = ["It does not belong to this repository"]; return result
        }

        // From here, each reason is added, so that the user sees all of them.
        if let why = entry.locked { result.reasons.append(why.isEmpty ? "It is locked" : "It is locked (\(why))") }
        if entry.prunable != nil { result.reasons.append("Git says that its record is not valid") }
        if active.contains(where: { $0 == real(target) || $0.hasPrefix(real(target) + "/") || $0 == target || $0.hasPrefix(target + "/") }) {
            result.reasons.append("A running program uses this folder")
        }

        // A setting of the repository can hide untracked files (status.showUntrackedFiles=no), so we ask for all of them.
        let status = git.run(["-c", "status.showUntrackedFiles=all", "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"], in: path)
        if status.status != 0 || status.timedOut {
            result.reasons.append("Git could not read its changes")
        } else if !status.stdout.isEmpty {
            result.reasons.append("It has changes that are not committed")
        }

        // Edits that git does not watch are lost too: `update-index --assume-unchanged` and `--skip-worktree` hide them from status.
        let listed = git.run(["ls-files", "-v", "-z"], in: path, timeout: 120)
        if listed.status != 0 || listed.timedOut {
            result.reasons.append("Git could not list its files")
        } else if hasUnwatchedFiles(listed.stdout, root: path) {
            result.reasons.append("Has files that git does not watch (assume-unchanged or skip-worktree). Check them first")
        }

        // Files that git ignores (.env, a local database) are deleted with the folder. Plain build and dependency folders are expected.
        let ignored = git.run(["status", "--porcelain", "-z", "--ignored", "--untracked-files=normal"], in: path)
        if ignored.status != 0 || ignored.timedOut {
            result.reasons.append("Git could not read its ignored files")
        } else if ignoredFilesOutsideCatalog(ignored.stdout, root: path) {
            result.reasons.append("Contains files that git ignores (for example .env). Move them first")
        }

        // The git folder of this worktree: a rebase, merge, bisect, or cherry-pick in progress, and recent activity.
        let gd = git.run(["rev-parse", "--absolute-git-dir"], in: path)
        let gitDir = gd.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if gd.status == 0, gitDir.hasPrefix("/") {
            for marker in inProgressMarkers where type(of: gitDir + "/" + marker) != nil {
                result.reasons.append("A rebase, merge, bisect, or cherry-pick is in progress"); break
            }
            let days = recentDays(path: target, gitDir: gitDir, now: now, staleDays: staleDays)
            if let days { result.reasons.append(days == 0 ? "Changed in the last \(staleDays) days (today)" : "Changed in the last \(staleDays) days (\(days) days ago)") }
        } else {
            result.reasons.append("Git could not tell where its state is")
        }

        guard isCommitID(entry.head) else {
            result.reasons.append("It has no commit yet"); return result
        }
        let sha = entry.head ?? ""
        var rev = ["rev-list", "--count", sha, "--not"]
        if let branch = entry.branch { rev.append("--exclude=\(branch)") }
        rev += ["--branches", "--remotes", "--tags"]
        let count = git.run(rev, in: repo)
        if count.status == 0, !count.timedOut, let n = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            result.uniqueCommits = n
            if n > 0 { result.reasons.append(n == 1 ? "It has 1 commit that exists nowhere else" : "It has \(n) commits that exist nowhere else") }
        } else {
            result.reasons.append("Git could not tell if its commits exist elsewhere")
        }

        let refs = git.run(["for-each-ref", "--contains", sha, "--format=%(refname)", "refs/heads", "refs/remotes"], in: repo)
        for line in refs.stdout.split(separator: "\n").map(String.init) {
            if line.hasPrefix("refs/remotes/") { result.onRemote = true }
            else if line.hasPrefix("refs/heads/"), line != "refs/heads/" + (entry.branch ?? "") { result.mergedInto.append(String(line.dropFirst(11))) }
        }
        let when = git.run(["log", "-1", "--format=%ct", sha], in: repo)
        if let seconds = TimeInterval(when.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) { result.lastCommit = Date(timeIntervalSince1970: seconds) }
        return result
    }

    static let inProgressMarkers = ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"]

    /// True when the `status --ignored -z` output has an ignored entry that is not a plain build or dependency folder of the catalog.
    /// With `--untracked-files=normal`, an ignored folder is one entry that ends with a slash.
    /// An ignored folder is allowed only when a catalog rule matches it WITH its marker file next to it (`node_modules` next to
    /// `package.json`). A loose name (`build`, `dist`, `.cache`) is not enough. Inside an allowed folder, one level is read for
    /// names that look like secrets or data (`.env*`, `*.sqlite`, `*.db`, `*.pem`, `*.key`), and they block too.
    static func ignoredFilesOutsideCatalog(_ output: String, root: URL) -> Bool {
        let fm = FileManager.default
        for field in output.components(separatedBy: "\0") where field.hasPrefix("!! ") {
            let path = String(field.dropFirst(3))
            guard path.hasSuffix("/") else { return true }
            let dir = root.appendingPathComponent(String(path.dropLast()), isDirectory: true)
            let name = dir.lastPathComponent
            let siblings = Set((try? fm.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)) ?? [])
            guard name != ".git", Catalog.matchingRule(name: name, url: dir, siblings: siblings) != nil else { return true }
            for child in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let n = child.lowercased()
                if n.hasPrefix(".env") || [".sqlite", ".db", ".pem", ".key"].contains(where: n.hasSuffix) { return true }
            }
        }
        return false
    }

    /// True when a tracked file that exists on disk is hidden from `git status`: assume-unchanged (a lower case tag) or skip-worktree
    /// (`S` or `s`). An edit of such a file is deleted by the removal without a word. A sparse-checkout file that is not on disk is fine.
    static func hasUnwatchedFiles(_ output: String, root: URL) -> Bool {
        for entry in output.components(separatedBy: "\0") where entry.count > 2 {
            guard let tag = entry.first, tag.isLowercase || tag == "S" else { continue }
            let file = String(entry.dropFirst(2))
            if (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file).path)) != nil { return true }
        }
        return false
    }

    /// Days since the newest change of the index, HEAD, the log of HEAD, or the folder itself, when that is inside the stale window.
    static func recentDays(path: String, gitDir: String, now: Date, staleDays: Int) -> Int? {
        var newest: Date?
        for file in [path, gitDir + "/index", gitDir + "/HEAD", gitDir + "/logs/HEAD"] {
            if let d = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date, newest == nil || d > newest! { newest = d }
        }
        guard let newest else { return nil }
        let days = max(0, Int(now.timeIntervalSince(newest) / 86_400))
        return now.timeIntervalSince(newest) < Double(staleDays) * 86_400 ? days : nil
    }

    // MARK: Remove

    public struct Problem: Error, LocalizedError, Equatable {
        public let text: String
        public var errorDescription: String? { text }
    }

    /// Runs `git worktree remove <path>` from the main checkout. Never forced: git refuses a worktree that has changes or a lock.
    /// A failed command is a failure. The files are never deleted in another way.
    static func remove(path: URL, mainCheckout: String, git: Git) throws {
        let r = git.run(["-c", "status.showUntrackedFiles=normal", "worktree", "remove", path.standardizedFileURL.path], in: URL(fileURLWithPath: mainCheckout), timeout: 900)
        guard r.status == 0, !r.timedOut else {
            let why = r.refused ? "The tool is not safe to run"
                : (r.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "git worktree remove failed")
            throw Problem(text: String(why.prefix(300)))
        }
        // An exit status of 0 is not proof. The folder must be gone.
        if type(of: path.standardizedFileURL.path) != nil { throw Problem(text: "git exited 0, but the folder is still there") }
    }

    // MARK: Stale records

    /// The records that git calls stale and whose folder is really missing. A record that is locked is not stale (git keeps it).
    public static func staleRecords(_ entries: [WorktreeEntry]) -> [WorktreeEntry] {
        entries.dropFirst().filter { $0.prunable != nil && $0.locked == nil && type(of: $0.path) == nil }
    }

    /// Why the prune must not run now, or nil. It runs only for the records of the preview, and only for folders in the home folder.
    /// A folder on a disk that is not connected looks missing, so a record outside the home folder stops the prune.
    public static func pruneBlocker(entries: [WorktreeEntry], previewed: [String], guardian: PathGuard) -> String? {
        guard let main = entries.first, !main.bare else { return "The repository is not a normal repository" }
        if let reason = guardian.check(URL(fileURLWithPath: main.path)) { return "Trash Panda does not touch this place: \(reason)" }
        let stale = staleRecords(entries)
        if stale.isEmpty { return "No record is stale now" }
        let home = guardian.home + "/"
        for e in stale {
            if !real(e.path).hasPrefix(home) { return "A missing worktree is outside the home folder. Its disk may not be connected" }
            if !previewed.contains(e.path) { return "A new stale record appeared after the preview" }
        }
        return nil
    }

    // MARK: Words

    /// Who made the worktree, from its folder. This is a guess from the place, and the tooltip says so.
    public static func creator(path: String, main: String, home: String) -> String {
        let p = real(path)
        if p.hasPrefix(real(main) + "/.claude/worktrees/") { return "Claude Code" }
        if p.hasPrefix(real(home) + "/.codex/worktrees/") { return "Codex" }
        return "you"
    }

    /// The state of a removable worktree, in one line.
    public static func stateText(_ c: WorktreeCheck) -> String {
        var parts = ["No changes that are not committed"]
        if let first = c.mergedInto.first { parts.append("branch is merged into \(first)") }
        else if c.onRemote { parts.append("branch is pushed") }
        else if c.uniqueCommits == 0 { parts.append("its commits are kept by a tag") }
        return parts.joined(separator: " · ")
    }
}

/// Finds the worktrees in the scanned folders and in the folders of the tools.
struct WorktreeScanner {
    let home: URL
    let roots: [URL]
    let guardian: PathGuard
    let git: Git
    let now: Date
    var staleDays = Config.defaultStaleDays
    let activeDirectories: () -> [String]
    var maxDepth = 6

    func scan() -> [Finding] {
        let seeds = repositories()
        var results = [[Finding]](repeating: [], count: seeds.count)
        var mains = Set<String>()
        let lock = NSLock()
        let active = LazyActive(activeDirectories)
        DispatchQueue.concurrentPerform(iterations: seeds.count) { i in
            guard let entries = Worktrees.list(git, in: seeds[i]), entries.count > 1, let main = entries.first, !main.bare else { return }
            let key = URL(fileURLWithPath: main.path).resolvingSymlinksInPath().path
            lock.lock(); let fresh = mains.insert(key).inserted; lock.unlock()
            guard fresh else { return }
            let found = findings(of: entries, active: active)
            lock.lock(); results[i] = found; lock.unlock()
        }
        return results.flatMap { $0 }
    }

    /// The main checkouts in the scanned folders (a `.git` folder), and the Codex worktree folders (`~/.codex/worktrees/<id>/<name>`).
    /// Codex keeps its worktrees outside the repository, so we ask git from inside them.
    func repositories() -> [URL] {
        var out: [URL] = []
        for root in roots { walk(root, depth: 0, into: &out) }
        let codex = home.appendingPathComponent(".codex/worktrees", isDirectory: true)
        for id in (try? FileManager.default.contentsOfDirectory(atPath: codex.path))?.sorted() ?? [] {
            let idURL = codex.appendingPathComponent(id, isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: idURL.path))?.sorted() ?? [] {
                let url = idURL.appendingPathComponent(name, isDirectory: true)
                if Worktrees.isFolderShape(url) { out.append(url) }
            }
        }
        return out
    }

    private func isRepository(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(".git").path))?[.type] as? FileAttributeType == .typeDirectory
    }

    private func walk(_ dir: URL, depth: Int, into out: inout [URL]) {
        if isRepository(dir) { out.append(dir); return }
        guard depth < maxDepth, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names.sorted() {
            if name.hasPrefix(".") || Catalog.skipDescend.contains(name) || Catalog.isSpecificArtifactName(name) { continue }
            let url = dir.appendingPathComponent(name, isDirectory: true)
            guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory else { continue }
            walk(url, depth: depth + 1, into: &out)
        }
    }

    /// The running programs are read once, and only when a repository has a linked worktree.
    final class LazyActive: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String]?
        private let read: () -> [String]
        init(_ read: @escaping () -> [String]) { self.read = read }
        var value: [String] { lock.lock(); defer { lock.unlock() }; if let list { return list }; let v = read(); list = v; return v }
    }

    private func tilde(_ path: String) -> String {
        let h = home.standardizedFileURL.path
        return path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
    }

    private func findings(of entries: [WorktreeEntry], active: LazyActive) -> [Finding] {
        guard let main = entries.first else { return [] }
        let mainURL = URL(fileURLWithPath: main.path, isDirectory: true)
        let repoName = mainURL.lastPathComponent
        var out: [Finding] = []

        let stale = Worktrees.staleRecords(entries)
        if !stale.isEmpty, Worktrees.pruneBlocker(entries: entries, previewed: stale.map(\.path), guardian: guardian) == nil {
            out.append(Finding(
                id: "worktree.prune:\(main.path)", ecosystem: .worktrees,
                title: "\(repoName) · \(stale.count) \(stale.count == 1 ? "record" : "records") of missing worktrees",
                location: stale.map { tilde($0.path) }.joined(separator: ", "),
                bytes: 0, tier: .review, rebuild: .seconds,
                action: .worktree(.prune(repo: mainURL, paths: stale.map(\.path))),
                note: "Git keeps a record for each worktree. The folder of these is gone. Git deletes only its own records. No file of a project is touched. If you moved a worktree to another place, git cannot repair it after this."))
        }

        for entry in entries.dropFirst() where Worktrees.staleRecords([main, entry]).isEmpty {
            let url = URL(fileURLWithPath: entry.path, isDirectory: true)
            guard Worktrees.isFolderShape(url) else { continue }          // a link or a strange folder is never listed
            let c = Worktrees.check(path: url, repo: mainURL, git: git, guardian: guardian, active: active.value, now: now, staleDays: staleDays)
            guard !c.isMain else { continue }
            let bytes = Sizer.size(of: url)
            guard bytes > 0 else { continue }
            let label = entry.branch ?? "detached " + String((entry.head ?? "").prefix(7))
            let creator = Worktrees.creator(path: entry.path, main: main.path, home: home.path)
            var place = [tilde(url.standardizedFileURL.path), entry.branch.map { "branch \($0)" } ?? "no branch (detached HEAD)"]
            if let date = c.lastCommit { let days = max(0, Int(now.timeIntervalSince(date) / 86_400)); place.append("last commit \(days == 0 ? "today" : "\(days) days ago")") }
            place.append("made by \(creator)")
            let reason = c.isRemovable ? nil : c.reasons.joined(separator: ". ")
            out.append(Finding(
                id: "worktree:\(url.standardizedFileURL.path)", ecosystem: .worktrees,
                title: "\(label) · worktree of \(repoName)", location: place.joined(separator: " · "),
                bytes: bytes, tier: .review, rebuild: .recreate,
                action: .worktree(.remove(repo: mainURL, path: url)), lastActivity: c.lastCommit,
                note: reason ?? Worktrees.stateText(c), blockedReason: reason))
        }
        return out
    }
}
