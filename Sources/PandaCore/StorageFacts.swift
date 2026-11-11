import Foundation

/// One fact for the "Good to know" section. It is text only. It has no action, so nothing can be cleaned from it,
/// and no total, bar or "Free up" set counts it.
public struct InfoRow: Equatable, Sendable {
    public let title: String
    /// The second line. It says that the row cannot be cleaned here.
    public let detail: String
    public let tooltip: String?

    public init(title: String, detail: String, tooltip: String? = nil) {
        self.title = title
        self.detail = detail
        self.tooltip = tooltip
    }
}

/// Builds the rows of "Good to know" from numbers the app already has. It reads nothing and scans nothing.
public enum StorageFacts {
    /// The section has at most this many rows.
    public static let maxRows = 3
    /// The Docker row shows only when the disk file is this much larger than the data in it.
    static let dockerGap: Int64 = 5_000_000_000
    /// The purgeable row shows only above this size.
    static let purgeableMinimum: Int64 = 1_000_000_000

    /// "Docker disk file: 34 GB on disk, 12 GB in use". nil when the file is less than 5 GB larger than its data.
    public static func dockerDisk(onDisk: Int64, inside: Int64, note: String?) -> InfoRow? {
        guard onDisk - inside >= dockerGap else { return nil }
        return InfoRow(title: "Docker disk file: \(ByteText.string(onDisk)) on disk, \(ByteText.string(inside)) in use",
                       detail: "Cannot be cleaned here. The file stays large after a clean.", tooltip: note)
    }

    /// "macOS can free by itself: about 18 GB". nil at 1 GB or less. The number is free space with purgeable space,
    /// minus free space without it. It is an estimate, so the row says so.
    public static func purgeable(_ bytes: Int64) -> InfoRow? {
        guard bytes > purgeableMinimum else { return nil }
        return InfoRow(title: "macOS can free by itself: about \(ByteText.string(bytes))",
                       detail: "An estimate. It may include snapshots and system files. Cannot be cleaned here.",
                       tooltip: "macOS keeps this space as free space. It takes it back when an app needs it.")
    }

    /// "Time Machine · 3 local snapshots". The text comes from the scan, which read the snapshots with a read-only command.
    public static func snapshots(_ f: Finding) -> InfoRow {
        InfoRow(title: f.title, detail: "Cannot be cleaned here. macOS removes them when the disk needs space.", tooltip: f.note)
    }

    /// The rows for a scan, at most `maxRows`. The order is fixed: Docker, snapshots, space that macOS frees.
    public static func rows(from findings: [Finding], disk: DiskUsage = DiskUsage(total: 0, free: 0)) -> [InfoRow] {
        var rows: [InfoRow] = []
        if let f = findings.first(where: { $0.id == "docker.vmdisk" && !$0.isActionable }), let inside = f.insideBytes,
           let row = dockerDisk(onDisk: f.bytes, inside: inside, note: f.note) {
            rows.append(row)
        }
        if let f = findings.first(where: { $0.id == "snapshots.local" && !$0.isActionable }) { rows.append(snapshots(f)) }
        if let row = purgeable(disk.purgeable) { rows.append(row) }
        return Array(rows.prefix(maxRows))
    }
}
