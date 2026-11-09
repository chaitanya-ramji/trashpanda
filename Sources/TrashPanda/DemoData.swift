import Foundation
import PandaCore

/// Made-up scan results for screenshots (`trashpanda --demo light` or `--demo dark`).
/// They contain no real project names. Demo mode never scans and never deletes.
enum DemoData {
    static func result() -> ScanResult {
        let ago = { (days: Double) in Date().addingTimeInterval(-days * 86_400) }
        func item(_ id: String, _ eco: Ecosystem, _ title: String, _ bytes: Int64, _ tier: Tier,
                  _ rebuild: Rebuild, place: String = "~/Projects", last: Date? = nil) -> Finding {
            Finding(id: id, ecosystem: eco, title: title, location: place, bytes: bytes, tier: tier,
                    rebuild: rebuild, action: .owner(.brewCleanup), lastActivity: last)
        }
        let findings: [Finding] = [
            item("1", .swift, "Xcode build data", 4_200_000_000, .safe, .minutes),
            item("2", .swift, "Unavailable simulators", 2_100_000_000, .safe, .seconds),
            item("3", .swift, "iOS device support files", 3_800_000_000, .review, .minutes),
            item("4", .rust, "Build output · cli-tool", 2_400_000_000, .safe, .minutes, last: ago(90)),
            item("5", .javascript, "node_modules · storefront", 1_300_000_000, .safe, .minutes, last: ago(75)),
            item("6", .javascript, "node_modules · admin-panel", 640_000_000, .safe, .minutes, last: ago(48)),
            item("7", .javascript, "npm cache", 229_000_000, .safe, .download),
            item("8", .javascript, "Build cache · web", 1_500_000_000, .review, .seconds, last: ago(3)),
            item("9", .python, "uv cache", 880_000_000, .safe, .download),
            item("10", .python, "Virtual environment · pipeline", 716_000_000, .review, .minutes, last: ago(9)),
            item("11", .go, "Go build cache", 650_000_000, .safe, .minutes),
            item("12", .docker, "Build cache", 568_000_000, .safe, .minutes, place: "Docker engine: OrbStack"),
            item("13", .homebrew, "Old downloads and versions", 412_000_000, .safe, .download),
        ]
        return ScanResult(findings: findings.sorted { $0.bytes > $1.bytes },
                          disk: DiskUsage(total: 245_000_000_000, free: 61_000_000_000))
    }
}
