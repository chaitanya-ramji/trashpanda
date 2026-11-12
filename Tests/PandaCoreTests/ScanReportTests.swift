import XCTest
@testable import PandaCore

final class ScanReportTests: XCTestCase {
    /// A scan with fixed values. It never reads the real disk.
    static func fixture(home: String = "/Users/example") -> ScanResult {
        let folder = URL(fileURLWithPath: home + "/Library/Caches/Example")
        let findings = [
            Finding(id: "example.cache", ecosystem: .swift, title: "Example build cache", location: "~/Library/Caches/Example",
                    bytes: 5_300_000_000, tier: .safe, rebuild: .minutes, action: .removeContents(folder)),
            Finding(id: "example.models", ecosystem: .aiAgents, title: "Example models \"big\"", location: "~/.example/models",
                    bytes: 12_000_000_000, tier: .review, rebuild: .download, action: .removeContents(folder)),
            Finding(id: "worktree:\(home)/code/demo", ecosystem: .worktrees, title: "Worktree · demo", location: "~/code/demo",
                    bytes: 40_000_000, tier: .review, rebuild: .recreate, action: .removeContents(folder)),
            Finding(id: "example.upper", ecosystem: .docker, title: "Example upper limit", location: "Docker",
                    bytes: 700_000_000, tier: .safe, rebuild: .seconds, action: .removeContents(folder), sizeIsUpperLimit: true),
            Finding(id: "example.info", ecosystem: .homebrew, title: "Example note", location: "~/Library/Example",
                    bytes: 1_500_000, tier: .review, rebuild: .never, action: .inform),
        ]
        return ScanResult(findings: findings, disk: DiskUsage(total: 500_000_000_000, free: 42_000_000_000),
                          date: Date(timeIntervalSince1970: 0))
    }

    private func golden(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/scanreport"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testJSONEqualsGolden() throws {
        let json = ScanReport(Self.fixture(), home: "/Users/example").json()
        XCTAssertEqual(json, try golden("scan.json"))
        XCTAssertTrue(json.hasSuffix("}\n"))
        XCTAssertEqual(json.filter { $0 == "\n" }.count, 1, "compact output: one line")
    }

    func testTextEqualsGolden() throws {
        XCTAssertEqual(ScanReport.text(Self.fixture()), try golden("scan.txt"))
    }

    func testIdIsStableAndDiffers() {
        let a = ScanReport(Self.fixture(), home: "/Users/example")
        let b = ScanReport(Self.fixture(), home: "/Users/example")
        XCTAssertEqual(a.findings.map(\.id), b.findings.map(\.id))
        XCTAssertEqual(Set(a.findings.map(\.id)).count, a.findings.count)
        // The home folder is not part of the id, so another user name gives the same id.
        let other = ScanReport(Self.fixture(home: "/Users/someone"), home: "/Users/someone")
        XCTAssertEqual(a.findings.map(\.id), other.findings.map(\.id))
        XCTAssertEqual(a.findings[2].id, "worktree:~/code/demo")
    }

    func testRoundTrip() throws {
        let report = ScanReport(Self.fixture(), home: "/Users/example")
        let decoded = try JSONDecoder().decode(ScanReport.self, from: Data(report.json().utf8))
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.schema, 1)
        XCTAssertEqual(decoded.findings.map(\.tier), ["safe", "review", "review", "safe", "info"])
        XCTAssertEqual(decoded.findings.map(\.rebuild), ["minutes", "download", "recreate", "seconds", "never"])
        XCTAssertEqual(decoded.findings.map(\.group), ["swift", "aiAgents", "worktrees", "docker", "homebrew"])
        // bytes is an integer in the text, not a float.
        XCTAssertTrue(report.json().contains("\"bytes\":5300000000,"))
    }

    func testScanPathHasNoDelete() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("Sources/TrashPanda/main.swift"), encoding: .utf8)
        let begin = try XCTUnwrap(main.range(of: "// BEGIN scan"))
        let end = try XCTUnwrap(main.range(of: "// END scan"))
        let scan = String(main[begin.upperBound..<end.lowerBound])
        XCTAssertTrue(scan.contains("DiskScanner().scan()"))
        for word in ["Cleaner", "removeItem", "trashItem", "unlink", "Shell.", "Process("] {
            XCTAssertFalse(scan.contains(word), "scan path must not contain \(word)")
        }
        let report = try String(contentsOf: root.appendingPathComponent("Sources/PandaCore/ScanReport.swift"), encoding: .utf8)
        for word in ["Cleaner", "removeItem", "trashItem", "unlink"] {
            XCTAssertFalse(report.contains(word), "ScanReport must not contain \(word)")
        }
    }

    func testJSONWithoutScanIsAnError() {
        XCTAssertNotNil(CommandLineCheck.error(["trashpanda", "--json"]))
        XCTAssertNotNil(CommandLineCheck.error(["trashpanda", "--json", "--demo"]))
        XCTAssertNil(CommandLineCheck.error(["trashpanda", "--scan", "--json"]))
        XCTAssertNil(CommandLineCheck.error(["trashpanda", "--json", "--scan"]))
        XCTAssertNil(CommandLineCheck.error(["trashpanda", "--scan"]))
        XCTAssertNil(CommandLineCheck.error(["trashpanda"]))
        XCTAssertNotNil(CommandLineCheck.error(["trashpanda", "--scan", "--nope"]))
        XCTAssertNil(CommandLineCheck.error(["trashpanda", "-psn_0_1234"]))
        XCTAssertEqual(CommandLineCheck.mode(["trashpanda", "--scan", "--json"]), "scan --json")
        XCTAssertEqual(CommandLineCheck.mode(["trashpanda", "--scan"]), "scan")
    }

    func testSummaryCounts() {
        XCTAssertEqual(ScanReport.summary(Self.fixture()),
                       "findings=5 safe=2 review=2 info=1 reclaimable=5300000000 reviewable=12040000000")
    }

    func testLogFlushWritesBeforeExit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-flush-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Log.fileURL
        defer { Log.fileURL = old }
        Log.fileURL = dir.appendingPathComponent("logs/trashpanda.log")
        Log.info("cli start test-line-1")
        Log.info("cli end test-line-2")
        Log.flush()
        // No wait: after flush the lines must be in the file.
        let text = try String(contentsOf: Log.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("test-line-1"))
        XCTAssertTrue(text.hasSuffix("test-line-2\n"))
    }
}
