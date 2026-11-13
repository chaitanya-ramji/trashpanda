import XCTest
@testable import PandaCore

/// #40: "Freed 568 MB" is true inside Docker. The Mac may not show it at once.
final class DockerSpaceNoteTests: DockerTestCase {
    private let gb: Int64 = 1_000_000_000, mb: Int64 = 1_000_000

    // MARK: The rule

    func testTheSentenceIsShortAndPlain() {
        let m = DockerSpaceNote.message(engine: "OrbStack", dockerFreed: 568 * mb, otherFreed: 0, volumeChange: -4_620_288)
        XCTAssertEqual(m, "Freed 568 MB inside Docker. Your Mac may take a while to show it.")
    }

    func testSpaceThatCameBackSaysNothing() {
        XCTAssertNil(DockerSpaceNote.message(engine: "OrbStack", dockerFreed: 568 * mb, otherFreed: 0, volumeChange: 568 * mb))
        XCTAssertNil(DockerSpaceNote.message(engine: "Docker Desktop", dockerFreed: 2 * gb, otherFreed: 0, volumeChange: 3 * gb))
    }

    func testAPartialReturnIsJudgedByHalf() {
        XCTAssertNotNil(DockerSpaceNote.message(engine: "Colima", dockerFreed: 1000 * mb, otherFreed: 0, volumeChange: 499 * mb))
        XCTAssertNil(DockerSpaceNote.message(engine: "Colima", dockerFreed: 1000 * mb, otherFreed: 0, volumeChange: 500 * mb), "Exactly half is enough")
        XCTAssertNil(DockerSpaceNote.message(engine: "Colima", dockerFreed: 1000 * mb, otherFreed: 0, volumeChange: 800 * mb))
    }

    func testOtherItemsOfTheSameCleanAreNotCountedAsDockerSpace() {
        // The Mac gained 1 GB, but other items freed 1 GB. Docker returned nothing.
        XCTAssertNotNil(DockerSpaceNote.message(engine: "OrbStack", dockerFreed: 568 * mb, otherFreed: gb, volumeChange: gb))
        XCTAssertNil(DockerSpaceNote.message(engine: "OrbStack", dockerFreed: 568 * mb, otherFreed: gb, volumeChange: gb + 568 * mb))
    }

    func testOnlyEnginesWithADiskFileGetTheNote() {
        for engine in ["OrbStack", "Docker Desktop", "Colima", "Rancher Desktop"] {
            XCTAssertNotNil(DockerSpaceNote.message(engine: engine, dockerFreed: gb, otherFreed: 0, volumeChange: 0), engine)
        }
        XCTAssertNil(DockerSpaceNote.message(engine: "Docker", dockerFreed: gb, otherFreed: 0, volumeChange: 0))
        XCTAssertNil(DockerSpaceNote.message(engine: nil, dockerFreed: gb, otherFreed: 0, volumeChange: 0))
        XCTAssertNil(DockerSpaceNote.message(engine: "Something else", dockerFreed: gb, otherFreed: 0, volumeChange: 0))
    }

    func testASmallAmountSaysNothing() {
        XCTAssertNil(DockerSpaceNote.message(engine: "OrbStack", dockerFreed: 10 * mb, otherFreed: 0, volumeChange: -5 * mb))
        XCTAssertNil(DockerSpaceNote.message(engine: "OrbStack", dockerFreed: 0, otherFreed: 0, volumeChange: 0))
        XCTAssertNil(DockerSpaceNote.message(engine: "OrbStack", dockerFreed: -5, otherFreed: 0, volumeChange: 0))
    }

    func testTheWordsHaveNoJargon() throws {
        let m = try XCTUnwrap(DockerSpaceNote.message(engine: "OrbStack", dockerFreed: 568 * mb, otherFreed: 0, volumeChange: 0))
        for word in ["sparse", "APFS", "volume", "bytes", "inode", "VM"] { XCTAssertFalse(m.contains(word), word) }
        XCTAssertLessThan(m.count, 90)
    }

    // MARK: Through the cleaner, with a fake docker and a fake free-space reader

    private func run(_ box: Sandbox, socket: String = ".orbstack/run/docker.sock", gain: Int64, extra: [Finding] = [],
                     sizeOf: ((URL) -> Int64)? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> CleanReport {
        let s = try socket.hasPrefix("/") ? "unix://\(socket)" : "unix://\(box.home.appendingPathComponent(socket).path)"
        let fake = try FakeDocker(box: box, contextName: "ctx", host: s)
        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false, dockerPath: fake.path, isSocket: { _ in true })
        var reads = 0
        let free: (URL) -> Int64 = { _ in reads += 1; return reads == 1 ? 100 * 1_000_000_000 : 100 * 1_000_000_000 + gain }
        let item = Finding(id: "docker.buildcache", ecosystem: .docker, title: "Build cache", location: "Docker engine: x", bytes: 568 * mb,
                           tier: .safe, rebuild: .minutes, action: .owner(.dockerBuilderPrune))
        let cleaner = Cleaner(guardian: scanner.guardian, remaining: { $0.ecosystem == .docker ? 0 : 0 }, dockerEngine: { scanner.dockerEngine() }, freeSpace: free)
        if let sizeOf { cleaner.sizeOf = sizeOf }
        return cleaner.clean([item] + extra)
    }

    func testSpaceThatDidNotComeBackGivesTheNote() throws {
        let report = try run(try Sandbox(), gain: -4_620_288)
        XCTAssertEqual(report.dockerFreed, 568 * mb)
        XCTAssertEqual(report.freed, 568 * mb)
        XCTAssertEqual(report.volumeChange, -4_620_288, "The two numbers are kept apart")
        XCTAssertEqual(report.dockerNote, "Freed 568 MB inside Docker. Your Mac may take a while to show it.")
    }

    func testSpaceThatCameBackGivesNoNote() throws {
        let report = try run(try Sandbox(), gain: 568 * mb)
        XCTAssertEqual(report.dockerFreed, 568 * mb)
        XCTAssertNil(report.dockerNote)
    }

    func testAPartialReturnThroughTheCleaner() throws {
        XCTAssertNotNil(try run(try Sandbox(), gain: 200 * mb).dockerNote)
        XCTAssertNil(try run(try Sandbox(), gain: 300 * mb).dockerNote)
    }

    func testAnEngineWithoutADiskFileGetsNoNote() throws {
        let report = try run(try Sandbox(), socket: "/var/run/docker.sock", gain: 0)
        XCTAssertEqual(report.dockerFreed, 568 * mb)
        XCTAssertNil(report.dockerNote)
    }

    func testOtherItemsAreCountedApart() throws {
        let box = try Sandbox()
        try box.file(".cache/zig/x", bytes: 3_000_000)
        let other = Finding(id: "zig", ecosystem: .zig, title: "Zig", location: "x", bytes: gb, tier: .safe, rebuild: .minutes,
                            action: .removeContents(box.home.appendingPathComponent(".cache/zig")))
        // The folder holds 3 MB. The cleaner measures the folder, so the test says that it measures 1 GB before, and 0 after.
        let measure: (URL) -> Int64 = { url in ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty ? 0 : self.gb }
        let report = try run(box, gain: gb, extra: [other], sizeOf: measure)    // the Mac gained 1 GB: exactly what the other item freed
        XCTAssertEqual(report.dockerFreed, 568 * mb, "Only the Docker item counts as Docker")
        XCTAssertTrue(report.freed > gb + 500 * mb, "\(report.freed)")
        XCTAssertNotNil(report.dockerNote, "Docker returned nothing. The 1 GB of the other item must not hide that")
        XCTAssertNil(try run(try Sandbox(), gain: gb, extra: []).dockerNote, "Without the other item, 1 GB gained means that Docker returned its space")
    }

    func testACleanWithoutDockerItemsHasNoNote() throws {
        let box = try Sandbox()
        try box.file(".cache/zig/x", bytes: 3_000_000)
        let other = Finding(id: "zig", ecosystem: .zig, title: "Zig", location: "x", bytes: 3_000_000, tier: .safe, rebuild: .minutes,
                            action: .removeContents(box.home.appendingPathComponent(".cache/zig")))
        let report = Cleaner(guardian: PathGuard(home: box.home), freeSpace: { _ in 5 }).clean([other])
        XCTAssertEqual(report.dockerFreed, 0)
        XCTAssertNil(report.dockerNote)
    }

    func testASkippedDockerItemFreesNothing() throws {
        let box = try Sandbox()
        let fake = try FakeDocker(box: box, contextName: "prod", host: "tcp://prod.example.com:2375")
        let s = DiskScanner(home: box.home, config: Config(), useOwnerTools: false, dockerPath: fake.path, isSocket: { _ in true })
        let item = Finding(id: "docker.buildcache", ecosystem: .docker, title: "Build cache", location: "x", bytes: gb, tier: .safe, rebuild: .minutes,
                           action: .owner(.dockerBuilderPrune))
        let report = Cleaner(guardian: s.guardian, dockerEngine: { s.dockerEngine() }, freeSpace: { _ in 1 }).clean([item])
        XCTAssertEqual(report.dockerFreed, 0)
        XCTAssertNil(report.dockerNote)
    }
}
