import Foundation

/// Finds build output folders inside projects.
/// A folder counts only when a marker file sits next to it (for example package.json for node_modules).
public struct ProjectScanner {
    public let home: URL
    public let roots: [URL]
    public let guardian: PathGuard
    public let now: Date
    public let staleAfter: TimeInterval
    public let maxDepth: Int
    /// Working directories of running processes. A project in use is never listed.
    public let activeDirectories: [String]

    public static let defaultStaleDays = 30

    public init(home: URL, roots: [URL], guardian: PathGuard, activeDirectories: [String],
                now: Date = Date(), staleDays: Int = ProjectScanner.defaultStaleDays, maxDepth: Int = 6) {
        self.home = home
        self.roots = roots
        self.guardian = guardian
        self.activeDirectories = activeDirectories
        self.now = now
        self.staleAfter = TimeInterval(staleDays) * 86_400
        self.maxDepth = maxDepth
    }

    struct Candidate {
        let url: URL
        let project: URL
        let rule: ArtifactRule
        let activity: Date?
    }

    public func scan() -> [Finding] {
        var candidates: [Candidate] = []
        for root in roots {
            walk(root, depth: 0, into: &candidates)
        }

        var results = [Finding?](repeating: nil, count: candidates.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let c = candidates[i]
            let bytes = Sizer.size(of: c.url, exclusiveOnly: true)
            guard bytes > 0 else { return }
            let finding = makeFinding(c, bytes: bytes)
            lock.lock(); results[i] = finding; lock.unlock()
        }
        return results.compactMap { $0 }
    }

    private func makeFinding(_ c: Candidate, bytes: Int64) -> Finding {
        let stale = c.activity.map { now.timeIntervalSince($0) >= staleAfter } ?? false
        let tier: Tier = (c.rule.tier == .safe && stale) ? .safe : .review
        let projectName = c.project.lastPathComponent
        return Finding(
            id: c.url.path,
            ecosystem: c.rule.ecosystem,
            title: "\(c.rule.label) · \(projectName)",
            location: c.url.path,
            bytes: bytes,
            tier: tier,
            rebuild: c.rule.rebuild,
            action: .removeArtifact(c.url),
            lastActivity: c.activity
        )
    }

    // MARK: Walk

    private func walk(_ dir: URL, depth: Int, into out: inout [Candidate]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let nameSet = Set(names)

        for name in names.sorted() {
            let url = dir.appendingPathComponent(name, isDirectory: true)
            guard isRealDirectory(url) else { continue }

            if let rule = matchingRule(name: name, url: url, siblings: nameSet) {
                if guardian.check(url) == nil, !isInUse(project: dir) {
                    out.append(Candidate(url: url, project: dir, rule: rule,
                                         activity: lastActivity(of: dir, names: names)))
                }
                continue
            }
            if depth + 1 >= maxDepth { continue }
            if name.hasPrefix(".") || Catalog.skipDescend.contains(name) || Catalog.isArtifactName(name) { continue }
            walk(url, depth: depth + 1, into: &out)
        }
    }

    private func matchingRule(name: String, url: URL, siblings: Set<String>) -> ArtifactRule? {
        for rule in Catalog.artifacts where rule.matches(name: name) {
            guard markerPresent(rule.markers, in: siblings) else { continue }
            if !rule.innerMarkers.isEmpty {
                let inner = Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
                guard rule.innerMarkers.contains(where: inner.contains) else { continue }
            }
            return rule
        }
        return nil
    }

    private func markerPresent(_ markers: [String], in names: Set<String>) -> Bool {
        markers.contains { marker in
            if marker.hasPrefix("*") {
                let suffix = String(marker.dropFirst())
                return names.contains { $0.hasSuffix(suffix) }
            }
            return names.contains(marker)
        }
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }

    private func isInUse(project: URL) -> Bool {
        let path = project.resolvingSymlinksInPath().path
        return activeDirectories.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    /// Newest change time of the project folder, its top-level entries, and git state files.
    /// This is a cheap stand-in for "when did someone last work here".
    func lastActivity(of project: URL, names: [String]) -> Date? {
        let fm = FileManager.default
        var newest: Date? = (try? fm.attributesOfItem(atPath: project.path))?[.modificationDate] as? Date

        func consider(_ path: String) {
            if let d = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                if newest == nil || d > newest! { newest = d }
            }
        }
        for name in names where !Catalog.isArtifactName(name) && name != ".git" {
            consider(project.appendingPathComponent(name).path)
        }
        for git in ["HEAD", "index", "FETCH_HEAD", "ORIG_HEAD"] {
            consider(project.appendingPathComponent(".git/\(git)").path)
        }
        return newest
    }
}
