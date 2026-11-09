import AppKit
import PandaCore

enum Format {
    /// Decimal units, like Finder.
    static func bytes(_ value: Int64) -> String {
        let v = Double(max(0, value))
        switch v {
        case 1e12...: return String(format: "%.1f TB", v / 1e12)
        case 1e10...: return String(format: "%.0f GB", v / 1e9)
        case 1e9...: return String(format: "%.1f GB", v / 1e9)
        case 1e6...: return String(format: "%.0f MB", v / 1e6)
        case 1e3...: return String(format: "%.0f KB", v / 1e3)
        default: return "0 KB"
        }
    }
}

/// The top of the menu: free space, the reclaimable amount, and one bar.
final class StorageHeaderView: NSView {
    private var disk = DiskUsage(total: 0, free: 0)
    private var reclaimable: Int64 = 0
    private var reviewable: Int64 = 0
    private var scanning = true

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 74))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(disk: DiskUsage, reclaimable: Int64, reviewable: Int64, scanning: Bool) {
        self.disk = disk
        self.reclaimable = reclaimable
        self.reviewable = reviewable
        self.scanning = scanning
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 16
        let title = "\(Format.bytes(disk.free)) free of \(Format.bytes(disk.total))"
        title.draw(at: NSPoint(x: inset, y: bounds.height - 28), withAttributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])

        let detail: String
        if scanning && reclaimable == 0 && reviewable == 0 {
            detail = "Looking for developer files…"
        } else if reclaimable == 0 && reviewable == 0 {
            detail = "Nothing to reclaim"
        } else {
            detail = "Reclaim \(Format.bytes(reclaimable)) now · \(Format.bytes(reviewable)) to review"
        }
        detail.draw(at: NSPoint(x: inset, y: bounds.height - 46), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])

        guard disk.total > 0 else { return }
        let bar = NSRect(x: inset, y: 12, width: bounds.width - inset * 2, height: 8)
        let total = Double(disk.total)
        let other = max(0, disk.used - reclaimable - reviewable)
        let parts: [(Int64, NSColor)] = [
            (other, NSColor.systemGray.withAlphaComponent(0.55)),
            (reviewable, NSColor.systemYellow),
            (reclaimable, NSColor.systemOrange),
            (disk.free, NSColor.separatorColor),
        ]

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).addClip()
        var x = bar.minX
        for (bytes, color) in parts where bytes > 0 {
            let w = bar.width * CGFloat(Double(bytes) / total)
            color.setFill()
            NSRect(x: x, y: bar.minY, width: w, height: bar.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
