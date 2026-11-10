import XCTest
@testable import PandaCore

/// A volume that only a stopped container uses is locked, because Docker refuses `volume rm` while any container uses it.
/// So the container and its volumes are one review item. Nothing is forced, and a running container is never touched.
final class DockerStoppedContainerVolumesTests: DockerTestCase {
    private let stopped = String(repeating: "a", count: 12) + String(repeating: "1", count: 52)     // 64 hex characters
    private let running = String(repeating: "b", count: 12) + String(repeating: "2", count: 52)
    private let other = String(repeating: "c", count: 12) + String(repeating: "3", count: 52)
    private let anon = String(repeating: "f", count: 64)

    private func inventory(stoppedState: String = "exited", volumes: [(String, String, Int)]) -> String {
        let vols = volumes.map { #"{"Name":"\#($0.0)","Size":"\#($0.1)","Links":"\#($0.2)","Driver":"local"}"# }.joined(separator: ",")
        return """
        {"Images":[{"Repository":"postgis","Tag":"16","ID":"sha256:\(String(repeating: "5", count: 64))","Size":"400MB","UniqueSize":"399MB","Containers":"1","CreatedAt":"2026-10-22 02:37:34 +0530 IST"}],
         "Containers":[
           {"ID":"\(stopped)","Names":"old-db","Image":"postgis:16","State":"\(stoppedState)","Status":"Exited (0) 4 months ago","Size":"217kB"},
           {"ID":"\(running)","Names":"live-db","Image":"postgres:17","State":"running","Status":"Up 2 days","Size":"1MB"},
           {"ID":"\(other)","Names":"other-stopped","Image":"redis:7","State":"exited","Status":"Exited (0) 3 days ago","Size":"100kB"}],
         "Volumes":[\(vols)]}
        """
    }
    private func setup(_ box: Sandbox, volumes: [(String, String, Int)], mounts: String, state: String = "exited") throws -> (FakeDocker, DiskScanner) {
        let socket = box.home.appendingPathComponent(".orbstack/run/docker.sock").path
        let fake = try FakeDocker(box: box, contextName: "orbstack", host: "unix://\(socket)", inventory: inventory(stoppedState: state, volumes: volumes))
        try fake.setMounts(mounts)
        return (fake, DiskScanner(home: box.home, config: Config(), useOwnerTools: false, dockerPath: fake.path, isSocket: { _ in true }))
    }
    private func cleaner(_ s: DiskScanner) -> Cleaner { Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), dockerEngine: { s.dockerEngine() }) }
    private func combined(_ s: DiskScanner) -> Finding? { s.scanDocker().first { $0.id.hasPrefix("docker.container.volumes") } }

    // MARK: The item

    func testAVolumeOfAStoppedContainerBecomesOneItemWithTheContainer() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1), ("live_pgdata", "244MB", 1)],
                                  mounts: "\(stopped)|old_pgdata,\n\(running)|live_pgdata,\n\(other)|\n")
        let found = s.scanDocker()
        let item = try XCTUnwrap(found.first { $0.id == "docker.container.volumes:\(stopped.prefix(12))" })
        XCTAssertEqual(item.title, "Stopped container · old-db and 1 volume")
        XCTAssertEqual(item.tier, .review)
        XCTAssertEqual(item.rebuild, .never)
        XCTAssertTrue(item.bytes >= 118_000_000 && item.bytes < 119_000_000, "The size is the volume and the container: \(item.bytes)")
        XCTAssertTrue(item.location.contains("old_pgdata"), item.location)
        XCTAssertTrue(item.note?.contains("Export") == true)
        XCTAssertFalse(found.contains { $0.id == "docker.container:\(stopped.prefix(12))" }, "Not listed twice")
        XCTAssertFalse(found.contains { $0.id == "docker.volume.info:old_pgdata" }, "The volume is part of the item now")
        XCTAssertTrue(found.contains { $0.id == "docker.container:\(other.prefix(12))" }, "A stopped container without volumes keeps its own item")
        XCTAssertTrue(fake.unexpected.isEmpty)
    }

    func testAVolumeOfARunningContainerStaysInformationAndSaysWhy() throws {
        let box = try Sandbox()
        let (_, s) = try setup(box, volumes: [("live_pgdata", "244MB", 1)], mounts: "\(running)|live_pgdata,\n")
        let info = try XCTUnwrap(s.scanDocker().first { $0.id == "docker.volume.info:live_pgdata" })
        XCTAssertFalse(info.isActionable)
        XCTAssertTrue(info.location.contains("live-db (running)") && info.location.contains("stop it to free this"), info.location)
    }

    func testAVolumeShownByTwoContainersIsNotOffered() throws {
        let box = try Sandbox()
        let (_, s) = try setup(box, volumes: [("shared", "50MB", 2)], mounts: "\(stopped)|shared,\n\(other)|shared,\n")
        XCTAssertNil(combined(s), "Two containers use it")
        XCTAssertTrue(s.scanDocker().contains { $0.id == "docker.volume.info:shared" })
    }

    func testAnonymousVolumesAreNamedShortAndPartOfTheItem() throws {
        let box = try Sandbox()
        let (_, s) = try setup(box, volumes: [(anon, "30MB", 1)], mounts: "\(stopped)|\(anon),\n")
        let item = try XCTUnwrap(combined(s))
        XCTAssertTrue(item.location.contains(String(anon.prefix(12)) + "…") && !item.location.contains(anon), item.location)
    }

    func testTheSmallContainerNoLongerHidesTheVolumes() throws {
        // The container has 217 kB. The 1 MB floor of the menu would hide it. The item is the container and the volumes, so it is shown.
        let box = try Sandbox()
        let (_, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "\(stopped)|old_pgdata,\n")
        XCTAssertGreaterThan(try XCTUnwrap(combined(s)).bytes, DiskScanner.minimumBytes)
    }

    func testWhenDockerCannotSayWhoMountsWhatNothingIsOffered() throws {
        let box = try Sandbox()
        let (_, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "")
        XCTAssertNil(combined(s))
        XCTAssertTrue(s.scanDocker().contains { $0.id == "docker.volume.info:old_pgdata" })
    }

    func testABindMountOfAFolderIsNotAVolume() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "")
        try fake.setRawMounts("\(stopped)|bind:<no value>,bind:<no value>,volume:old_pgdata,tmpfs:<no value>,\n")
        XCTAssertEqual(s.scanDocker().first { $0.id.hasPrefix("docker.container.volumes") }?.location.contains("/Users/x") , false)
        XCTAssertNotNil(combined(s), "The volume still counts, and the folder does not")
        let mounts = DockerEngine.detect(dockerPath: fake.path, home: box.home, isSocket: { _ in true })
        if case .success(let engine) = mounts { XCTAssertEqual(engine.volumes(ofContainers: [stopped]), [stopped: ["old_pgdata"]]) } else { XCTFail("engine") }
    }

    func testTheTemplateToleratesAMountWithoutAName() throws {
        // The real tool stops with a template error when the format says `.Name` for a bind mount. The fake does not, so we check the text.
        let box = try Sandbox()
        let (fake, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "\(stopped)|old_pgdata,\n")
        _ = combined(s)
        let call = try XCTUnwrap(fake.calls.first { $0.contains("container inspect") })
        XCTAssertTrue(call.contains(#"index . "Name""#), call)
        XCTAssertFalse(call.contains("{{.Name}}"), call)
    }

    func testOddMountsAreDropped() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "")
        try fake.setRawMounts("\(stopped)|volume:-rf,volume:a b,volume:../x,volume:,volume:old_pgdata,\nnot-hex|volume:x,\nbroken line\n")
        if case .success(let engine) = DockerEngine.detect(dockerPath: fake.path, home: box.home, isSocket: { _ in true }) {
            XCTAssertEqual(engine.volumes(ofContainers: [stopped]), [stopped: ["old_pgdata"]])
        } else { XCTFail("engine") }
        _ = s
    }

    // MARK: The clean

    func testACleanRunsExactlyTheContainerAndThenTheVolume() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "\(stopped)|old_pgdata,\n")
        let item = try XCTUnwrap(combined(s))
        let before = fake.calls.count
        let report = cleaner(s).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        let mine = fake.calls.dropFirst(before).filter { $0.contains(" rm ") }.map { $0.replacingOccurrences(of: "--host unix://\(box.home.path)/.orbstack/run/docker.sock ", with: "") }
        XCTAssertEqual(mine, ["container rm \(stopped)", "volume rm old_pgdata"], "The container first, then the volume, and nothing else")
        XCTAssertTrue(fake.unexpected.isEmpty)
        let bad = fake.calls.filter { !$0.contains("system df") }.filter { $0.contains(" -f ") || $0.contains("--force") || $0.contains("prune") || $0.contains("--volumes") || $0.contains(" -v ") }
        XCTAssertEqual(bad, [], "No force, no prune, and no option that removes volumes with a container")
    }

    func testAContainerThatStartedAfterTheScanRunsNothing() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "\(stopped)|old_pgdata,\n")
        let item = try XCTUnwrap(combined(s))
        try fake.setInventory(inventory(stoppedState: "running", volumes: [("old_pgdata", "118MB", 1)]))
        let report = cleaner(s).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertFalse(fake.calls.contains { $0.contains(" rm ") }, "No remove was sent")
    }

    func testASecondContainerThatTookTheVolumeRunsNothingNotEvenTheContainerRemove() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "\(stopped)|old_pgdata,\n")
        let item = try XCTUnwrap(combined(s))
        try fake.setMounts("\(stopped)|old_pgdata,\n\(running)|old_pgdata,\n")          // the running container mounts it now
        let report = cleaner(s).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertFalse(fake.calls.contains { $0.contains(" rm ") }, "The container is not removed either")
        XCTAssertTrue(report.skipped[0].contains("another container"), report.skipped[0])
    }

    func testAVolumeThatAnotherContainerNowCountsRunsNothing() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "\(stopped)|old_pgdata,\n")
        let item = try XCTUnwrap(combined(s))
        try fake.setInventory(inventory(volumes: [("old_pgdata", "118MB", 2)]))           // Docker says: two links now
        XCTAssertEqual(cleaner(s).clean([item]).removed, 0)
        XCTAssertFalse(fake.calls.contains { $0.contains(" rm ") })
    }

    func testWhenDockerDoesNotAnswerAboutMountsNothingRuns() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "\(stopped)|old_pgdata,\n")
        let item = try XCTUnwrap(combined(s))
        try fake.setMounts("")
        XCTAssertEqual(cleaner(s).clean([item]).removed, 0)
        XCTAssertFalse(fake.calls.contains { $0.contains(" rm ") })
    }

    func testForgedActionsHaveNoArgumentsAndRunNothing() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "\(stopped)|old_pgdata,\n")
        for action in [DockerAction.removeStoppedContainerWithVolumes(id: "-f", volumes: ["old_pgdata"]),
                       .removeStoppedContainerWithVolumes(id: stopped, volumes: ["--force"]),
                       .removeStoppedContainerWithVolumes(id: stopped, volumes: ["a b"]),
                       .removeStoppedContainerWithVolumes(id: stopped, volumes: []),
                       .removeStoppedContainerWithVolumes(id: stopped, volumes: Array(repeating: "v", count: 11)),
                       .removeStoppedContainerWithVolumes(id: "xyz", volumes: ["old_pgdata"])] {
            XCTAssertNil(action.arguments)
            XCTAssertTrue(action.followUpArguments.isEmpty)
            let f = Finding(id: "f", ecosystem: .docker, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .never, action: .docker(action))
            XCTAssertEqual(cleaner(s).clean([f]).removed, 0)
        }
        XCTAssertFalse(fake.calls.contains { $0.contains(" rm ") })
    }

    func testTheRunningContainerAndItsVolumeAreNeverTouched() throws {
        let box = try Sandbox()
        let (fake, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1), ("live_pgdata", "244MB", 1)],
                                  mounts: "\(stopped)|old_pgdata,\n\(running)|live_pgdata,\n")
        _ = cleaner(s).clean(s.scanDocker().filter { $0.isActionable })   // includes the other stopped container, which has no volume
        let removes = fake.calls.filter { $0.contains(" rm ") }
        XCTAssertFalse(removes.contains { $0.contains(running) || $0.contains("live_pgdata") }, "\(removes)")
        XCTAssertEqual(removes.count, 3, "The stopped container with its volume, and the other stopped container: \(removes)")
    }

    func testTheDialogWarnsAboutDatabasesAndKeepsByDefault() throws {
        let box = try Sandbox()
        let (_, s) = try setup(box, volumes: [("old_pgdata", "118MB", 1)], mounts: "\(stopped)|old_pgdata,\n")
        let f = try XCTUnwrap(combined(s))
        XCTAssertEqual(Confirmation.kind(of: f), .containerWithVolumes)
        let c = Confirmation.forOne(f, staleDays: 30)
        XCTAssertEqual(c.title, "Delete this container and its volumes?")
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertTrue(c.footer?.contains("pg_dump") == true && c.footer?.contains("can't be undone") == true)
        XCTAssertEqual(ScanResult(findings: [f], disk: DiskUsage(total: 1, free: 1)).reclaimable, 0, "Never in the one-click clean")
    }
}
