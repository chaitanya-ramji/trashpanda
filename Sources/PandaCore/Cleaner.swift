import Foundation

/// Deletes items permanently. Every path passes the guard first.
/// The app shows a preview before it calls this.
public final class Cleaner {
    public let guardian: PathGuard

    public init(guardian: PathGuard) {
        self.guardian = guardian
    }

    public func clean(_ findings: [Finding], progress: ((String) -> Void)? = nil) -> CleanReport {
        var report = CleanReport()
        // Read the running processes again. The state can change after the scan.
        let active = Shell.activeDirectories()

        for finding in findings {
            progress?(finding.title)
            switch finding.action {
            case .removeContents(let dir):
                removeContents(of: dir, finding: finding, into: &report)

            case .removeArtifact(let url):
                guard Catalog.isArtifactName(url.lastPathComponent) else {
                    report.skipped.append("\(finding.location): not a known build folder"); continue
                }
                if let reason = guardian.check(url) {
                    report.skipped.append("\(finding.location): \(reason)"); continue
                }
                let project = url.deletingLastPathComponent().resolvingSymlinksInPath().path
                if active.contains(where: { $0 == project || $0.hasPrefix(project + "/") }) {
                    report.skipped.append("\(finding.location): project is in use"); continue
                }
                remove(url, bytes: finding.bytes, into: &report)

            case .owner(let command):
                guard let tool = Shell.resolve(command.toolName) else {
                    report.skipped.append("\(finding.title): \(command.toolName) not found"); continue
                }
                let r = Shell.run(tool, command.arguments, timeout: command.timeout)
                if r.status == 0, !r.timedOut {
                    report.freed += finding.bytes
                    report.removed += 1
                } else {
                    report.failed.append("\(finding.title): \(command.toolName) failed")
                }
            }
        }
        return report
    }

    private func removeContents(of dir: URL, finding: Finding, into report: inout CleanReport) {
        if let reason = guardian.check(dir) {
            report.skipped.append("\(finding.location): \(reason)"); return
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            report.failed.append("\(finding.location): cannot read folder"); return
        }
        var failures = 0
        for name in names {
            let child = dir.appendingPathComponent(name)
            if let reason = guardian.check(child) {
                report.skipped.append("\(child.path): \(reason)"); continue
            }
            do { try FileManager.default.removeItem(at: child) } catch { failures += 1 }
        }
        report.removed += 1
        // Count only what really left the disk.
        let left = Sizer.size(of: dir)
        report.freed += max(0, finding.bytes - left)
        if failures > 0 { report.failed.append("\(finding.location): \(failures) items stayed") }
    }

    private func remove(_ url: URL, bytes: Int64, into report: inout CleanReport) {
        do {
            try FileManager.default.removeItem(at: url)
            report.freed += bytes
            report.removed += 1
        } catch {
            report.failed.append("\(url.path): \(error.localizedDescription)")
        }
    }
}
