import Foundation

/// Deletes items permanently. Every path passes the guard first.
/// The app shows a preview before it calls this.
/// The report counts the space that really left the disk. It does not repeat the scan estimate.
public final class Cleaner {
    public let guardian: PathGuard
    /// Measures what is left of an item after the clean. Without it, owner commands report the estimate.
    private let remaining: ((Finding) -> Int64)?

    public init(guardian: PathGuard, remaining: ((Finding) -> Int64)? = nil) {
        self.guardian = guardian
        self.remaining = remaining
    }

    public func clean(_ findings: [Finding], progress: ((String) -> Void)? = nil) -> CleanReport {
        var report = CleanReport()
        let started = Date()
        let before = DiskUsage.rawFree(at: URL(fileURLWithPath: guardian.home))
        Log.info("clean start: \(findings.count) items, estimate \(findings.reduce(0) { $0 + $1.bytes }) bytes")
        // Read the running processes again. The state can change after the scan.
        let active = Shell.activeDirectories()

        for finding in findings {
            progress?(finding.title)
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
            }
        }

        let after = DiskUsage.rawFree(at: URL(fileURLWithPath: guardian.home))
        Log.info(String(format: "clean done in %.1fs: removed %d, freed %lld bytes, skipped %d, failed %d, volume free changed by %lld bytes",
                        Date().timeIntervalSince(started), report.removed, report.freed,
                        report.skipped.count, report.failed.count, after - before))
        return report
    }

    // MARK: Actions

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
        guard let tool = Shell.resolve(command.toolName) else {
            skip(finding, "\(command.toolName) not found", &report); return
        }
        let result = Shell.run(tool, command.arguments, timeout: command.timeout)
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
