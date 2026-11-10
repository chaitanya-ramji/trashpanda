import XCTest
@testable import PandaCore

/// #21: Time Machine local snapshots. We only tell. We never delete or thin a snapshot.
final class LocalSnapshotsTests: XCTestCase {
    private let real = """
    Snapshots for disk /:
    com.apple.TimeMachine.2026-11-08-101500.local
    com.apple.TimeMachine.2026-11-09-211012.local
    com.apple.TimeMachine.2026-11-10-081000.local
    """

    /// A fake `tmutil`. It answers only `listlocalsnapshots /`, records every call, and fails on anything else.
    private func fakeTmutil(_ box: Sandbox, output: String, status: Int = 0) throws -> (path: String, calls: () -> [String]) {
        let dir = box.home.appendingPathComponent("faketm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let out = dir.appendingPathComponent("out.txt")
        try output.write(to: out, atomically: true, encoding: .utf8)
        let script = """
        #!/bin/bash
        echo "$@" >> "\(log.path)"
        if [ "$1 $2" = "listlocalsnapshots /" ] && [ "$#" = "2" ]; then /bin/cat "\(out.path)"; exit \(status); fi
        echo "UNEXPECTED $@" >> "\(log.path)"; exit 2
        """
        let path = dir.appendingPathComponent("tmutil").path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) })
    }
    private func scanner(_ box: Sandbox, tool: String, now: Date = Date()) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false, now: { now }, tmutilPath: tool)
    }

    // MARK: Reading

    func testTheRealOutputIsRead() {
        let now = DateFormatter.snapshotNoon("2026-11-10-120000")
        let info = LocalSnapshots.parse(real, now: now)
        XCTAssertEqual(info?.count, 3)
        XCTAssertEqual(info?.oldestDays, 2, "From 2026-11-08 10:15 to 2026-11-10 12:00")
    }

    func testOtherLinesAreIgnored() {
        let now = Date()
        XCTAssertNil(LocalSnapshots.parse("Snapshots for disk /:\n", now: now), "The header only: there are none")
        XCTAssertNil(LocalSnapshots.parse("", now: now))
        XCTAssertNil(LocalSnapshots.parse("tmutil: error\nsomething com.apple.TimeMachine.2026-11-08-101500.local in the middle\n", now: now))
        XCTAssertEqual(LocalSnapshots.parse("com.apple.TimeMachine.2026-11-08-101500\ncom.apple.TimeMachine.not-a-date.local\n", now: now)?.count, 1,
                       "The ending is optional, and a bad date is not a snapshot")
    }

    func testABadDateStillCountsWhenTheNameLooksRight() {
        let info = LocalSnapshots.parse("com.apple.TimeMachine.2026-13-45-999999.local\n", now: Date())
        XCTAssertEqual(info?.count, 1)
        XCTAssertNil(info?.oldestDays, "The age is unknown")
    }

    // MARK: The note

    func testTheNoteAppearsOnlyWhenSnapshotsExist() throws {
        let box = try Sandbox()
        let none = try fakeTmutil(box, output: "Snapshots for disk /:\n")
        XCTAssertTrue(scanner(box, tool: none.path).scanSnapshots().isEmpty)
        let box2 = try Sandbox()
        let some = try fakeTmutil(box2, output: real)
        let found = scanner(box2, tool: some.path, now: DateFormatter.snapshotNoon("2026-11-10-120000")).scanSnapshots()
        let f = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(f.title, "Time Machine · 3 local snapshots")
        XCTAssertTrue(f.location.contains("the oldest is 2 days old"), f.location)
        XCTAssertFalse(f.isActionable, "Information only")
        XCTAssertEqual(f.ecosystem, .snapshots)
        XCTAssertEqual(f.helpURL, LocalSnapshots.helpURL)
        XCTAssertTrue(f.note?.contains("does not delete") == true)
    }

    func testOneSnapshotUsesTheSingular() throws {
        let box = try Sandbox()
        let t = try fakeTmutil(box, output: "com.apple.TimeMachine.2026-11-09-211012.local\n")
        XCTAssertEqual(scanner(box, tool: t.path).scanSnapshots().first?.title, "Time Machine · 1 local snapshot")
    }

    func testNothingWhenTmutilFailsOrIsMissing() throws {
        let box = try Sandbox()
        let failing = try fakeTmutil(box, output: real, status: 1)
        XCTAssertTrue(scanner(box, tool: failing.path).scanSnapshots().isEmpty)
        XCTAssertTrue(scanner(box, tool: "/nonexistent/tmutil").scanSnapshots().isEmpty)
    }

    func testTheNoteIsInNoTotalAndNothingIsDeleted() throws {
        let box = try Sandbox()
        let t = try fakeTmutil(box, output: real)
        let found = scanner(box, tool: t.path).scanSnapshots()
        let result = ScanResult(findings: found, disk: DiskUsage(total: 1, free: 1))
        XCTAssertEqual(result.reclaimable, 0)
        XCTAssertEqual(result.reviewable, 0)
        let report = Cleaner(guardian: PathGuard(home: box.home)).clean(found)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(t.calls().filter { $0 != "listlocalsnapshots /" }, [], "Only the read command was ever run")
        XCTAssertFalse(t.calls().contains { $0.contains("UNEXPECTED") })
    }

    func testTheSourceNeverDeletesOrThinsASnapshot() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var checked = 0
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)) where url.pathExtension == "swift" {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                checked += 1
                for banned in ["deletelocalsnapshots", "thinlocalsnapshots", "thinlocalbackups", "disablelocal", "deletelocalsnapshotdates", "delete-snapshot"] {
                    XCTAssertFalse(t.lowercased().contains(banned), "\(url.lastPathComponent): \(t)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }
}

private extension DateFormatter {
    static func snapshotNoon(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: text)!
    }
}
