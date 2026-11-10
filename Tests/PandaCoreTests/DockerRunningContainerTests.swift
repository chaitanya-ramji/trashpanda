import XCTest
@testable import PandaCore

/// The owner asked to be able to delete a running container with its data too. It is a review item with the strongest dialog.
/// The app stops it with `docker stop` (never `kill`, never forced), checks that it stopped, and only then removes it and its volumes.
final class DockerRunningContainerTests: DockerTestCase {
    private let live = String(repeating: "b", count: 12) + String(repeating: "2", count: 52)
    private let other = String(repeating: "c", count: 12) + String(repeating: "3", count: 52)

    private func inventory(liveState: String, links: Int = 1) -> String {
        """
        {"Images":[],
         "Containers":[
           {"ID":"\(live)","Names":"live-db","Image":"postgres:17","State":"\(liveState)","Status":"\(liveState == "running" ? "Up 2 days" : "Exited (0) 2 seconds ago")","Size":"1MB"},
           {"ID":"\(other)","Names":"web","Image":"nginx","State":"running","Status":"Up 1 hour","Size":"5MB"}],
         "Volumes":[{"Name":"live_pgdata","Size":"244MB","Links":"\(links)","Driver":"local"}]}
        """
    }
    private func setup(_ box: Sandbox, stopWorks: Bool = true) throws -> (FakeDocker, DiskScanner) {
        let socket = box.home.appendingPathComponent(".orbstack/run/docker.sock").path
        let fake = try FakeDocker(box: box, contextName: "orbstack", host: "unix://\(socket)", inventory: inventory(liveState: "running"),
                                  inventoryAfter: inventory(liveState: stopWorks ? "exited" : "running"))
        try fake.setMounts("\(live)|live_pgdata,\n\(other)|\n")
        return (fake, DiskScanner(home: box.home, config: Config(), useOwnerTools: false, dockerPath: fake.path, isSocket: { _ in true }))
    }
    private func cleaner(_ s: DiskScanner) -> Cleaner { Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), dockerEngine: { s.dockerEngine() }) }
    private func item(_ s: DiskScanner) -> Finding? { s.scanDocker().first { $0.id == "docker.running:\(live.prefix(12))" } }
    private func mine(_ fake: FakeDocker, from: Int) -> [String] {
        fake.calls.dropFirst(from).filter { $0.contains(" stop ") || $0.contains(" rm ") }
            .map { $0.components(separatedBy: ".sock ").last ?? $0 }
    }

    // MARK: The item

    func testARunningContainerWithItsVolumeIsAReviewItem() throws {
        let box = try Sandbox()
        let (_, s) = try setup(box)
        let found = s.scanDocker()
        let f = try XCTUnwrap(item(s))
        XCTAssertEqual(f.title, "Running container · live-db and 1 volume")
        XCTAssertEqual(f.tier, .review)
        XCTAssertEqual(f.rebuild, .never)
        XCTAssertTrue(f.bytes >= 244_000_000 && f.bytes < 252_000_000, "\(f.bytes)")
        XCTAssertTrue(f.location.contains("will be stopped first") && f.location.contains("live_pgdata"), f.location)
        XCTAssertFalse(found.contains { $0.id == "docker.volume.info:live_pgdata" }, "The volume is part of the item, not a dead end")
        XCTAssertTrue(found.contains { $0.id == "docker.running:\(other.prefix(12))" }, "A running container without a volume can be deleted too")
        XCTAssertEqual(ScanResult(findings: found.filter { $0.id.hasPrefix("docker.running") }, disk: DiskUsage(total: 1, free: 1)).reclaimable, 0, "Never in the one-click clean")
    }

    func testTheDialogIsTheStrongestAndKeepsEverythingByDefault() throws {
        let box = try Sandbox()
        let (_, s) = try setup(box)
        let f = try XCTUnwrap(item(s))
        XCTAssertEqual(Confirmation.kind(of: f), .runningContainer)
        let c = Confirmation.forOne(f, staleDays: 30)
        XCTAssertEqual(c.title, "Stop and delete this running container?")
        XCTAssertEqual(c.confirmTitle, "Stop and delete")
        XCTAssertTrue(c.cancelIsDefault)
        for word in ["docker stop", "pg_dump", "stop working", "can't be undone"] { XCTAssertTrue(c.footer?.contains(word) == true, word) }
    }

    // MARK: The clean

    func testACleanStopsThenRemovesTheContainerThenTheVolume() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box)
        let f = try XCTUnwrap(item(s))
        let before = fake.calls.count
        let report = cleaner(s).clean([f])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertEqual(mine(fake, from: before), ["container stop \(live)", "container rm \(live)", "volume rm live_pgdata"], "In this order, and nothing else")
        XCTAssertTrue(fake.unexpected.isEmpty)
        let banned = fake.calls.filter { !$0.contains("system df") }.filter { $0.contains("kill") || $0.contains(" -f ") || $0.contains("--force") || $0.contains(" -t 0") || $0.contains("--time 0") || $0.contains("prune") || $0.contains("--volumes") }
        XCTAssertEqual(banned, [], "No kill, no force, no zero wait")
    }

    func testAContainerThatIsAlreadyStoppedIsNotStoppedAgain() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box)
        let f = try XCTUnwrap(item(s))
        try fake.setInventory(inventory(liveState: "exited"))
        let before = fake.calls.count
        XCTAssertEqual(cleaner(s).clean([f]).removed, 1)
        XCTAssertEqual(mine(fake, from: before), ["container rm \(live)", "volume rm live_pgdata"], "No stop for a stopped container")
    }

    func testAnInvalidIdNeverReachesStop() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box)
        let f = try XCTUnwrap(item(s))
        let bad = Finding(id: "x", ecosystem: .docker, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .never,
                          action: .docker(.stopAndRemoveContainerWithVolumes(id: "zz", volumes: [])))
        XCTAssertEqual(cleaner(s).clean([bad]).removed, 0)
        XCTAssertFalse(fake.calls.contains { $0.contains(" stop ") })
        _ = f
    }

    func testAContainerThatStaysRunningAfterStopIsNotRemoved() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box, stopWorks: false)
        let f = try XCTUnwrap(item(s))
        let before = fake.calls.count
        let report = cleaner(s).clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertTrue(report.failed[0].contains("still running"), report.failed[0])
        XCTAssertEqual(mine(fake, from: before), ["container stop \(live)"], "It was asked to stop, and nothing was removed")
    }

    func testAVolumeThatAnotherContainerTookRunsNothingNotEvenTheStop() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box)
        let f = try XCTUnwrap(item(s))
        try fake.setMounts("\(live)|live_pgdata,\n\(other)|live_pgdata,\n")
        let before = fake.calls.count
        let report = cleaner(s).clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(mine(fake, from: before), [], "The container keeps running")
    }

    func testWhenDockerCannotSayWhoMountsWhatNothingRuns() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box)
        let f = try XCTUnwrap(item(s))
        try fake.setMounts("")
        let before = fake.calls.count
        XCTAssertEqual(cleaner(s).clean([f]).removed, 0)
        XCTAssertEqual(mine(fake, from: before), [])
    }

    func testForgedActionsHaveNoArgumentsAndRunNothing() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box)
        for action in [DockerAction.stopAndRemoveContainerWithVolumes(id: "-f", volumes: []), .stopAndRemoveContainerWithVolumes(id: live, volumes: ["--force"]),
                       .stopAndRemoveContainerWithVolumes(id: live, volumes: ["a b"]), .stopAndRemoveContainerWithVolumes(id: "xyz", volumes: []),
                       .stopAndRemoveContainerWithVolumes(id: live, volumes: Array(repeating: "v", count: 11))] {
            XCTAssertNil(action.arguments)
            XCTAssertTrue(action.followUpArguments.isEmpty)
            let f = Finding(id: "f", ecosystem: .docker, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .never, action: .docker(action))
            XCTAssertEqual(cleaner(s).clean([f]).removed, 0)
        }
        XCTAssertFalse(fake.calls.contains { $0.contains(" stop ") || $0.contains(" rm ") })
        XCTAssertEqual(DockerAction.stopAndRemoveContainerWithVolumes(id: live, volumes: ["v"]).arguments, ["container", "stop", live])
        XCTAssertEqual(DockerAction.stopAndRemoveContainerWithVolumes(id: live, volumes: ["v"]).followUpArguments, [["container", "rm", live], ["volume", "rm", "v"]])
    }

    func testAContainerThatIsNotListedAnyMoreIsSkipped() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box)
        let ghost = String(repeating: "d", count: 64)
        let f = Finding(id: "g", ecosystem: .docker, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .never,
                        action: .docker(.stopAndRemoveContainerWithVolumes(id: ghost, volumes: [])))
        XCTAssertEqual(cleaner(s).clean([f]).removed, 0)
        XCTAssertFalse(fake.calls.contains { $0.contains(" stop ") })
    }

    func testARemoteEngineGetsNoStopAtAll() throws {
        let box = try Sandbox()
        let fake = try FakeDocker(box: box, contextName: "prod", host: "tcp://prod.example.com:2375", inventory: inventory(liveState: "running"))
        let s = DiskScanner(home: box.home, config: Config(), useOwnerTools: false, dockerPath: fake.path, isSocket: { _ in true })
        let f = Finding(id: "f", ecosystem: .docker, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .never,
                        action: .docker(.stopAndRemoveContainerWithVolumes(id: live, volumes: [])))
        XCTAssertEqual(cleaner(s).clean([f]).removed, 0)
        XCTAssertFalse(fake.calls.contains { $0.contains(" stop ") || $0.contains(" rm ") })
    }

    func testTheSourceNeverKillsAContainer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)) where url.pathExtension == "swift" {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                XCTAssertFalse(t.contains("\"kill\"") || t.contains("\"pause\"") || t.contains("\"restart\"") || t.contains("\"update\""), "\(url.lastPathComponent): \(t)")
            }
        }
    }
}
