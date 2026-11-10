import XCTest
@testable import PandaCore

/// Base class for every test that touches Docker.
/// It hides the real `docker` tool, so that no test can reach a real engine.
/// A test that forgets to inject the fake gets "docker is not installed", never a real call.
class DockerTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        Shell.searchDirsOverride = ["/usr/bin", "/bin"]
    }

    override func tearDown() {
        Shell.searchDirsOverride = nil
        super.tearDown()
    }
}

/// A fake `docker` tool for tests. It needs no Docker installation.
///
/// - It answers `context inspect`, `system df`, and `system df -v` from fixture files.
/// - It serves one inventory before a delete command and another one after it.
/// - It records every call in a log, so a test can prove what ran and what did not.
/// - Any command that it does not know is logged as `UNEXPECTED` and fails.
///
/// Fixtures live in `Tests/PandaCoreTests/Fixtures/docker`. They have the shape of real Docker output.
/// All names in them are made up.
final class FakeDocker {
    let path: String
    private let logPath: String

    /// Loads a fixture by name, for example `inventory-full`.
    static func fixture(_ name: String, ext: String = "json") throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext,
                                                  subdirectory: "Fixtures/docker"), "missing fixture \(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static let buildCacheOnly = #"{"Type":"Build Cache","Reclaimable":"2.5GB (100%)"}"#

    /// The full form. `context` is the text that `docker context inspect` prints.
    init(box: Sandbox, context: String, inventory: String = "{}", inventoryAfter: String? = nil,
         summary: String = FakeDocker.buildCacheOnly, tagTimes: String = "") throws {
        path = box.home.appendingPathComponent("bin/docker").path
        logPath = box.home.appendingPathComponent("docker-calls.log").path
        let dir = (path as NSString).deletingLastPathComponent
        let files = ["context": dir + "/context.json", "before": dir + "/inventory-before.json",
                     "after": dir + "/inventory-after.json", "summary": dir + "/summary.jsonl",
                     "tagtimes": dir + "/tagtimes.txt"]
        let marker = dir + "/changed"
        let script = """
        #!/bin/bash
        echo "$*" >> "\(logPath)"
        echo "ENV DOCKER_HOST=${DOCKER_HOST:-} DOCKER_CONTEXT=${DOCKER_CONTEXT:-}" >> "\(logPath)"
        if [ "$1" = "context" ] && [ "$2" = "inspect" ]; then cat "\(files["context"]!)"; exit 0; fi
        case "$*" in
          *"system df -v"*)
            if [ -f "\(marker)" ]; then cat "\(files["after"]!)"; else cat "\(files["before"]!)"; fi
            exit 0;;
          *"system df"*) cat "\(files["summary"]!)"; exit 0;;
          *"image inspect"*) cat "\(files["tagtimes"]!)"; exit 0;;
          *"container inspect"*) cat "$(dirname "$0")/mounts.txt" 2>/dev/null; exit 0;;
          *"builder prune"*|*"image prune"*|*"image rm "*|*"container rm "*|*"volume rm "*) touch "\(marker)"; exit 0;;
        esac
        echo "UNEXPECTED $*" >> "\(logPath)"
        exit 1
        """
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try context.write(toFile: files["context"]!, atomically: true, encoding: .utf8)
        try inventory.write(toFile: files["before"]!, atomically: true, encoding: .utf8)
        try (inventoryAfter ?? inventory).write(toFile: files["after"]!, atomically: true, encoding: .utf8)
        try summary.write(toFile: files["summary"]!, atomically: true, encoding: .utf8)
        try tagTimes.write(toFile: files["tagtimes"]!, atomically: true, encoding: .utf8)
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// A one-line context. Most tests use this.
    convenience init(box: Sandbox, contextName: String, host: String, inventory: String = "{}",
                     inventoryAfter: String? = nil, summary: String = FakeDocker.buildCacheOnly,
                     tagTimes: String = "") throws {
        let context = #"[{"Name":"\#(contextName)","Endpoints":{"docker":{"Host":"\#(host)"}}}]"#
        try self.init(box: box, context: context, inventory: inventory, inventoryAfter: inventoryAfter,
                      summary: summary, tagTimes: tagTimes)
    }

    /// A context and inventory from fixture files. The local context points to the sandbox socket.
    convenience init(box: Sandbox, contextFixture: String, inventoryFixture: String,
                     summaryFixture: String? = nil, inventoryAfterFixture: String? = nil,
                     tagTimesFixture: String? = nil, socketInHome: String = ".orbstack/run/docker.sock") throws {
        let socket = box.home.appendingPathComponent(socketInHome).path
        let context = try FakeDocker.fixture(contextFixture).replacingOccurrences(of: "__SOCKET__", with: socket)
        try self.init(box: box, context: context,
                      inventory: try FakeDocker.fixture(inventoryFixture),
                      inventoryAfter: try inventoryAfterFixture.map { try FakeDocker.fixture($0) },
                      summary: try summaryFixture.map { try FakeDocker.fixture($0, ext: "jsonl") }
                          ?? FakeDocker.buildCacheOnly,
                      tagTimes: try tagTimesFixture.map { try FakeDocker.fixture($0, ext: "txt") } ?? "")
    }

    /// What `docker container inspect` answers: one line `<container id>|<volume>,<volume>,` for each container.
    /// The names are plain here: the fake prints each as a `volume:<name>` mount, like the real tool.
    func setMounts(_ text: String) throws {
        let lines = text.split(whereSeparator: \.isNewline).map { line -> String in
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return String(line) }
            return parts[0] + "|" + parts[1].split(separator: ",").map { "volume:\($0)," }.joined()
        }
        try setRawMounts(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
    }

    func setRawMounts(_ text: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try text.write(toFile: dir + "/mounts.txt", atomically: true, encoding: .utf8)
    }

    /// Changes what the engine reports from now on. Use it to test a change after the scan.
    func setInventory(_ json: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try json.write(toFile: dir + "/inventory-before.json", atomically: true, encoding: .utf8)
    }

    private var lines: [String] {
        ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    var calls: [String] { lines.filter { !$0.hasPrefix("ENV ") && !$0.hasPrefix("UNEXPECTED ") } }
    var environments: [String] { lines.filter { $0.hasPrefix("ENV ") } }
    var unexpected: [String] { lines.filter { $0.hasPrefix("UNEXPECTED ") } }
}

/// Builds a `docker system df -v --format json` document for tests that need exact numbers.
enum DockerJSON {
    static func image(_ repo: String, _ tag: String, containers: Int, unique: String, size: String = "100MB") -> String {
        """
        {"Repository":"\(repo)","Tag":"\(tag)","ID":"sha256:\(UUID().uuidString)","Size":"\(size)","SharedSize":"0B",\
        "UniqueSize":"\(unique)","Containers":"\(containers)","CreatedSince":"2 weeks ago","CreatedAt":"2026-10-23 14:21:40 +0530 IST"}
        """
    }

    static func inventory(images: [String]) -> String {
        "{\"Images\":[\(images.joined(separator: ","))],\"Containers\":[],\"Volumes\":[],\"BuildCache\":[]}"
    }
}

// MARK: - The four cases that every Docker feature must handle (#11)

final class DockerFixtureTests: DockerTestCase {
    private func scanner(_ box: Sandbox, _ fake: FakeDocker?) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false,
                    dockerPath: fake?.path, isSocket: { _ in true })
    }

    func testNoEngine() throws {
        // The real docker tool is hidden by DockerTestCase, so this holds on any machine.
        let box = try Sandbox()
        XCTAssertNil(Shell.resolve("docker"), "The real docker tool is hidden in Docker tests")
        let s = scanner(box, nil)
        XCTAssertEqual(s.dockerEngine().failureReason, .noDocker)
        XCTAssertTrue(s.scanDocker().isEmpty)
    }

    func testRemoteEngines() throws {
        for context in ["context-remote-tcp", "context-remote-ssh"] {
            let box = try Sandbox()
            let fake = try FakeDocker(box: box, contextFixture: context, inventoryFixture: "inventory-full",
                                      summaryFixture: "summary-full")
            let s = scanner(box, fake)
            XCTAssertTrue(s.scanDocker().isEmpty, context)
            XCTAssertEqual(fake.calls, ["context inspect"], "\(context): only the context is read")
            XCTAssertTrue(fake.unexpected.isEmpty)
        }
    }

    func testEmptyEngine() throws {
        let box = try Sandbox()
        let fake = try FakeDocker(box: box, contextFixture: "context-local", inventoryFixture: "inventory-empty",
                                  summaryFixture: "summary-empty")
        XCTAssertTrue(scanner(box, fake).scanDocker().isEmpty, "An empty engine gives no items")
        XCTAssertTrue(fake.unexpected.isEmpty)
    }

    func testFullEngine() throws {
        let box = try Sandbox()
        let fake = try FakeDocker(box: box, contextFixture: "context-local", inventoryFixture: "inventory-full",
                                  summaryFixture: "summary-full")
        let found = Dictionary(uniqueKeysWithValues: scanner(box, fake).scanDocker().map { ($0.id, $0) })

        XCTAssertEqual(found["docker.buildcache"]?.bytes, 567_600_000)
        XCTAssertEqual(found["docker.images.dangling"]?.bytes, 150_500_000, "120 MB + 30.5 MB. The used one stays.")
        XCTAssertTrue(fake.unexpected.isEmpty, "Only known commands ran: \(fake.unexpected)")
    }

    func testFixturesHaveTheShapeOfRealDockerOutput() throws {
        let inventory = try XCTUnwrap(DockerInventory.parse(try FakeDocker.fixture("inventory-full")))
        XCTAssertEqual(inventory.images.count, 13)
        XCTAssertEqual(inventory.danglingImages.count, 2)
        let empty = try XCTUnwrap(DockerInventory.parse(try FakeDocker.fixture("inventory-empty")))
        XCTAssertTrue(empty.images.isEmpty)
    }
}

extension Result where Failure == DockerRefusal {
    var failureReason: DockerRefusal? { if case .failure(let e) = self { return e } else { return nil } }
}

// MARK: - Docker: stopped containers (#8)

final class DockerContainerTests: DockerTestCase {
    private let fullInventory = { try FakeDocker.fixture("inventory-full") }

    private func setup(_ box: Sandbox, after: String? = nil) throws -> (FakeDocker, DiskScanner) {
        let fake = try FakeDocker(box: box, contextFixture: "context-local", inventoryFixture: "inventory-full",
                                  summaryFixture: "summary-full")
        if let after { try? after.write(toFile: (fake.path as NSString).deletingLastPathComponent + "/inventory-after.json",
                                        atomically: true, encoding: .utf8) }
        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false,
                                  dockerPath: fake.path, isSocket: { _ in true })
        return (fake, scanner)
    }

    private func containers(_ s: DiskScanner) -> [Finding] { s.scanDocker().filter { $0.id.hasPrefix("docker.container:") } }

    /// The full inventory without one container, as the engine reports it after a removal.
    private func inventoryWithout(containerNamed name: String) throws -> String {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try fullInventory().utf8)) as? [String: Any])
        root["Containers"] = (root["Containers"] as? [[String: Any]] ?? []).filter { ($0["Names"] as? String) != name }
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    func testOnlyStoppedContainersAppear() throws {
        let box = try Sandbox()
        let (_, scanner) = try setup(box)
        let found = containers(scanner)

        XCTAssertEqual(found.count, 3, "The running container is not listed")
        XCTAssertFalse(found.contains { $0.title.contains("· db") }, "db is running")
        XCTAssertTrue(found.allSatisfy { $0.tier == .review && $0.ecosystem == .docker && $0.rebuild == .recreate })

        let old = try XCTUnwrap(found.first { $0.title == "Stopped container · old-db" })
        XCTAssertEqual(old.bytes, 217_000)
        XCTAssertTrue(old.location.contains("postgres:17-alpine"))
        XCTAssertTrue(old.location.contains("Exited (0) 4 months ago"))
        if case .docker(.removeContainer(let id)) = old.action { XCTAssertEqual(id.count, 16) } else { XCTFail() }
    }

    func testCleaningOneContainerTouchesOnlyThatContainer() throws {
        let box = try Sandbox()
        let (fake, scanner) = try setup(box, after: try inventoryWithout(containerNamed: "cache"))
        let target = try XCTUnwrap(containers(scanner).first { $0.title.hasSuffix("· cache") })
        guard case .docker(.removeContainer(let id)) = target.action else { return XCTFail() }

        let report = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:),
                             dockerEngine: { scanner.dockerEngine() }).clean([target])

        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, 1_000_000)
        let removals = fake.calls.filter { $0.contains("container rm") }
        XCTAssertEqual(removals, ["--host unix://\(box.home.path)/.orbstack/run/docker.sock container rm \(id)"])
        XCTAssertFalse(removals[0].contains(" -f"), "Never force")
        XCTAssertFalse(removals[0].contains(" -v"), "Never remove volumes")
        XCTAssertTrue(fake.unexpected.isEmpty)
    }

    func testARunningContainerIsNeverRemoved() throws {
        let box = try Sandbox()
        let (fake, scanner) = try setup(box)
        // A finding for the running container that the scan never made.
        let inventory = try XCTUnwrap(DockerInventory.parse(try fullInventory()))
        let running = try XCTUnwrap(inventory.containers.first { $0.state == "running" })
        let forged = Finding(id: "x", ecosystem: .docker, title: "Stopped container · db", location: "x", bytes: 193_000,
                             tier: .review, rebuild: .recreate, action: .docker(.removeContainer(id: running.id)))

        let report = Cleaner(guardian: scanner.guardian, dockerEngine: { scanner.dockerEngine() }).clean([forged])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.skipped.joined().contains("not stopped"))
        XCTAssertFalse(fake.calls.contains { $0.contains("container rm") })
    }

    func testAContainerStartedAfterTheScanIsSkipped() throws {
        let box = try Sandbox()
        let (fake, scanner) = try setup(box)
        let target = try XCTUnwrap(containers(scanner).first { $0.title.hasSuffix("· cache") })

        // Between the scan and the clean, the user starts that container.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try fullInventory().utf8)) as? [String: Any])
        root["Containers"] = (root["Containers"] as? [[String: Any]] ?? []).map { item in
            var item = item
            if item["Names"] as? String == "cache" { item["State"] = "running"; item["Status"] = "Up 1 second" }
            return item
        }
        try fake.setInventory(String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self))
        let report = Cleaner(guardian: scanner.guardian, dockerEngine: { scanner.dockerEngine() }).clean([target])

        XCTAssertEqual(report.removed, 0)
        XCTAssertFalse(fake.calls.contains { $0.contains("container rm") }, "Nothing is removed: \(fake.calls)")
    }

    func testBadIdentifiersGiveNoCommand() {
        for bad in ["", "--force", "-f", "abc", "ABCDEF0123456789", "a b c d e f 1 2 3 4 5 6", "0123456789ab; rm -rf /",
                    "../../etc", "0123456789ab\n--volumes", String(repeating: "a", count: 65)] {
            XCTAssertNil(DockerAction.removeContainer(id: bad).arguments, "\"\(bad)\"")
        }
        XCTAssertEqual(DockerAction.removeContainer(id: "0123456789ab").arguments, ["container", "rm", "0123456789ab"])
        XCTAssertNotNil(DockerAction.removeContainer(id: String(repeating: "f", count: 64)).arguments)
    }

    func testAnInvalidIdentifierInAFindingRunsNothing() throws {
        let box = try Sandbox()
        let (fake, scanner) = try setup(box)
        let forged = Finding(id: "x", ecosystem: .docker, title: "x", location: "x", bytes: 1, tier: .review,
                             rebuild: .recreate, action: .docker(.removeContainer(id: "--force")))
        let report = Cleaner(guardian: scanner.guardian, dockerEngine: { scanner.dockerEngine() }).clean([forged])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(fake.calls.isEmpty, "Not even the engine is contacted: \(fake.calls)")
    }

    func testRemoteEngineGivesNoContainers() throws {
        let box = try Sandbox()
        let fake = try FakeDocker(box: box, contextFixture: "context-remote-ssh", inventoryFixture: "inventory-full")
        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false,
                                  dockerPath: fake.path, isSocket: { _ in true })
        XCTAssertTrue(containers(scanner).isEmpty)
        XCTAssertEqual(fake.calls, ["context inspect"])
    }
}

// MARK: - Docker: unused images older than N days (#9)

final class DockerOldImageTests: DockerTestCase {
    /// The fixtures were written for this day. A fixed clock keeps the ages the same on every run.
    private let now = ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z")!
    private var socket: (Sandbox) -> String { { $0.home.path + "/.orbstack/run/docker.sock" } }

    private func setup(_ box: Sandbox, staleDays: Int = 30, after: String? = nil) throws -> (FakeDocker, DiskScanner) {
        let fake = try FakeDocker(box: box, contextFixture: "context-local", inventoryFixture: "inventory-full",
                                  summaryFixture: "summary-full", tagTimesFixture: "tagtimes-full")
        if let after {
            try after.write(toFile: (fake.path as NSString).deletingLastPathComponent + "/inventory-after.json",
                            atomically: true, encoding: .utf8)
        }
        let scanner = DiskScanner(home: box.home, config: Config(staleDays: staleDays), useOwnerTools: false,
                                  dockerPath: fake.path, isSocket: { _ in true }, now: { [now] in now })
        return (fake, scanner)
    }

    private func images(_ s: DiskScanner) -> [Finding] { s.scanDocker().filter { $0.id.hasPrefix("docker.image:") } }

    private func inventory(removing refs: Set<String>) throws -> String {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try FakeDocker.fixture("inventory-full").utf8)) as? [String: Any])
        root["Images"] = (root["Images"] as? [[String: Any]] ?? []).filter {
            !refs.contains("\($0["Repository"] as? String ?? ""):\($0["Tag"] as? String ?? "")")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    func testOnlyOldUnusedNamedImagesAppear() throws {
        let box = try Sandbox()
        let (fake, scanner) = try setup(box)
        let found = images(scanner)

        XCTAssertEqual(Set(found.map(\.title)), ["Image · web-api:latest", "Image · legacy-tool:1.0 (+1 more names)"])
        XCTAssertTrue(found.allSatisfy { $0.tier == .review && $0.rebuild == .download && $0.ecosystem == .docker })
        XCTAssertTrue(fake.unexpected.isEmpty)

        let web = try XCTUnwrap(found.first { $0.title.contains("web-api") })
        XCTAssertEqual(web.bytes, 289_600_000, "The unique size, which is what removal frees")
        XCTAssertTrue(web.location.contains("on this Mac for 126 days"), web.location)
        XCTAssertTrue(web.location.hasPrefix("Docker engine: OrbStack"))
    }

    func testWhatIsLeftOutAndWhy() throws {
        let box = try Sandbox()
        let titles = try images(setup(box).1).map(\.title).joined(separator: " | ")
        XCTAssertFalse(titles.contains("postgres"), "A running container uses it")
        XCTAssertFalse(titles.contains("redis"), "A container uses it")
        XCTAssertFalse(titles.contains("batch-job"), "A STOPPED container uses it. That still counts.")
        XCTAssertFalse(titles.contains("cache-builder"), "On this Mac for 3 days only")
        XCTAssertFalse(titles.contains("base-image"), "Built 2 years ago, but it arrived 4 days ago")
        XCTAssertFalse(titles.contains("tools:x"), "Docker did not say how many containers use it")
        XCTAssertFalse(titles.contains("mystery"), "Its age on this Mac is unknown. We never guess.")
    }

    func testTheLimitComesFromTheSetting() throws {
        let box = try Sandbox()
        XCTAssertEqual(try images(setup(box, staleDays: 200).1).count, 0, "126 days is not old when the limit is 200")
        XCTAssertEqual(try images(setup(box, staleDays: 100).1).count, 2)
        XCTAssertEqual(try images(setup(box, staleDays: 5).1).count, 2, "base-image is 4 days on this Mac: not old enough")
        XCTAssertEqual(try images(setup(box, staleDays: 4).1).count, 3, "base-image counts now. cache-builder (3 days) does not.")
    }

    func testCleaningOneImageUsesAnExactNameAndMeasuresTheResult() throws {
        let box = try Sandbox()
        let (fake, scanner) = try setup(box, after: try inventory(removing: ["web-api:latest"]))
        let target = try XCTUnwrap(images(scanner).first { $0.title.contains("web-api") })

        let report = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:),
                             dockerEngine: { scanner.dockerEngine() }).clean([target])

        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, 289_600_000)
        let removals = fake.calls.filter { $0.contains("image rm") }
        XCTAssertEqual(removals, ["--host unix://\(socket(box)) image rm web-api:latest"])
        XCTAssertFalse(fake.calls.contains { $0.contains("prune") || $0.contains(" -a") || $0.contains("--all") },
                       "Never prune all images: \(fake.calls)")
        XCTAssertFalse(removals[0].contains(" -f"), "Never force")
    }

    func testAnImageWithTwoNamesIsRemovedByBothNames() throws {
        let box = try Sandbox()
        let (fake, scanner) = try setup(box, after: try inventory(removing: ["legacy-tool:1.0", "legacy-tool:latest"]))
        let target = try XCTUnwrap(images(scanner).first { $0.title.contains("legacy-tool") })
        let report = Cleaner(guardian: scanner.guardian, remaining: scanner.remainingBytes(of:),
                             dockerEngine: { scanner.dockerEngine() }).clean([target])

        XCTAssertEqual(report.freed, 200_000_000, "Counted once, not once for each name")
        XCTAssertEqual(fake.calls.filter { $0.contains("image rm") },
                       ["--host unix://\(socket(box)) image rm legacy-tool:1.0 legacy-tool:latest"])
    }

    func testAnImageThatBecomesUsedAfterTheScanIsSkipped() throws {
        let box = try Sandbox()
        let (fake, scanner) = try setup(box)
        let target = try XCTUnwrap(images(scanner).first { $0.title.contains("web-api") })

        // Between the scan and the clean, a container starts to use the image.
        var root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try FakeDocker.fixture("inventory-full").utf8)) as? [String: Any])
        root["Images"] = (root["Images"] as? [[String: Any]] ?? []).map { item in
            var item = item
            if item["Repository"] as? String == "web-api" { item["Containers"] = "1" }
            return item
        }
        try fake.setInventory(String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self))

        let report = Cleaner(guardian: scanner.guardian, dockerEngine: { scanner.dockerEngine() }).clean([target])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.skipped.joined().contains("a container uses this image"))
        XCTAssertFalse(fake.calls.contains { $0.contains("image rm") })
    }

    func testBadNamesGiveNoCommand() {
        for bad in [["-f"], ["--all"], ["web-api"], [":latest"], ["web-api:"], ["a b:c"], ["x:y; rm -rf /"],
                    ["UPPER:tag"], ["web-api:latest\n--force"], [], ["ok:1", "-f"], Array(repeating: "a:b", count: 21)] {
            XCTAssertNil(DockerAction.removeImage(refs: bad).arguments, "\(bad)")
        }
        XCTAssertEqual(DockerAction.removeImage(refs: ["postgis/postgis:16-3.4"]).arguments,
                       ["image", "rm", "postgis/postgis:16-3.4"])
        XCTAssertNotNil(DockerAction.removeImage(refs: ["localhost:5000/team/app:1.2.3"]).arguments)
    }

    func testDatesAreReadInBothFormats() {
        XCTAssertEqual(DockerInventory.parseDate("2026-10-23 14:21:40 +0530 IST"),
                       ISO8601DateFormatter().date(from: "2026-10-23T08:51:40Z"), "A zone name with a T (IST) works")
        XCTAssertEqual(DockerInventory.parseDate("2026-10-23 14:21:40 -0700 PST"),
                       ISO8601DateFormatter().date(from: "2026-10-23T21:21:40Z"))
        XCTAssertEqual(DockerInventory.parseDate("2026-10-31T03:45:57.348516651Z"),
                       ISO8601DateFormatter().date(from: "2026-10-31T03:45:57Z"))
        XCTAssertNil(DockerInventory.parseDate("0001-01-01T00:00:00Z"), "Docker's 'not set'")
        XCTAssertNil(DockerInventory.parseDate(""))
        XCTAssertNil(DockerInventory.parseDate("yesterday"))
    }

    /// The fix for a risk in #7: a count that Docker does not give must never mean "unused".
    func testAnUnknownContainerCountIsNeverUnused() throws {
        let json = DockerJSON.inventory(images: [
            DockerJSON.image("<none>", "<none>", containers: 0, unique: "120MB")
                .replacingOccurrences(of: "\"Containers\":\"0\"", with: "\"Containers\":\"N/A\""),
        ])
        let inventory = try XCTUnwrap(DockerInventory.parse(json))
        XCTAssertEqual(inventory.images.first?.containers, -1)
        XCTAssertTrue(inventory.danglingImages.isEmpty, "Unknown count: the dangling image is left alone")
    }
}

// MARK: - Docker: volumes (#10)

final class DockerVolumeTests: DockerTestCase {
    private func setup(_ box: Sandbox, after: String? = nil) throws -> (FakeDocker, DiskScanner) {
        let fake = try FakeDocker(box: box, contextFixture: "context-local", inventoryFixture: "inventory-full",
                                  summaryFixture: "summary-full", tagTimesFixture: "tagtimes-full")
        if let after {
            try after.write(toFile: (fake.path as NSString).deletingLastPathComponent + "/inventory-after.json",
                            atomically: true, encoding: .utf8)
        }
        return (fake, DiskScanner(home: box.home, config: Config(), useOwnerTools: false, dockerPath: fake.path,
                                  isSocket: { _ in true }))
    }

    private func cleaner(_ s: DiskScanner) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), dockerEngine: { s.dockerEngine() })
    }

    private func volumeFindings(_ s: DiskScanner) -> [Finding] { s.scanDocker().filter { $0.id.hasPrefix("docker.volume") } }

    private func fullInventory(editing change: (inout [[String: Any]]) -> Void) throws -> String {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try FakeDocker.fixture("inventory-full").utf8)) as? [String: Any])
        var volumes = root["Volumes"] as? [[String: Any]] ?? []
        change(&volumes)
        root["Volumes"] = volumes
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    func testOnlyUnusedLocalVolumesCanBeRemoved() throws {
        let box = try Sandbox()
        let found = volumeFindings(try setup(box).1)
        let removable = found.filter(\.isActionable)

        XCTAssertEqual(Set(removable.map(\.id)),
                       ["docker.volume:scratch_data",
                        "docker.volume:fe11eb3b691c945aebe4b3e02a00dbbf130f4f8326526edcbb76d3644b64dcb3"])
        XCTAssertEqual(Set(removable.map(\.title)),
                       ["Unused volume · scratch_data", "Unused anonymous volume · fe11eb3b691c…"])
        XCTAssertTrue(removable.allSatisfy { $0.tier == .review && $0.rebuild == .never })
        XCTAssertEqual(removable.first { $0.title.contains("scratch") }?.bytes, 40_000_000)
    }

    func testEveryOtherVolumeIsShownForInformationOnly() throws {
        let box = try Sandbox()
        let info = volumeFindings(try setup(box).1).filter { !$0.isActionable }

        XCTAssertEqual(Set(info.map(\.title)),
                       ["Volume · app_pgdata", "Volume · old_pgdata", "Volume · remote_data", "Volume · mystery_vol"])
        XCTAssertTrue(info.allSatisfy { if case .inform = $0.action { return true } else { return false } })
        func why(_ name: String) -> String { info.first { $0.title.hasSuffix(name) }?.location ?? "" }
        XCTAssertTrue(why("app_pgdata").contains("used by 1 container"))
        XCTAssertTrue(why("remote_data").contains("driver rclone"), "A non-local volume is never removable")
        XCTAssertTrue(why("mystery_vol").contains("did not say"), "Unknown use counts as in use")
    }

    func testInformationLinesAreNotInAnyTotal() throws {
        let box = try Sandbox()
        let found = try setup(box).1.scanDocker()
        let result = ScanResult(findings: found, disk: DiskUsage(total: 1_000_000_000_000, free: 500_000_000_000))
        let infoBytes = found.filter { !$0.isActionable }.reduce(Int64(0)) { $0 + $1.bytes }

        XCTAssertGreaterThan(infoBytes, 800_000_000)
        XCTAssertEqual(result.reclaimable + result.reviewable,
                       found.filter(\.isActionable).reduce(Int64(0)) { $0 + $1.bytes })
        XCTAssertEqual(result.reviewable, found.filter { $0.isActionable && $0.tier == .review }.reduce(0) { $0 + $1.bytes })
    }

    func testDeletingOneVolumeRunsOneExactCommandAndMeasuresIt() throws {
        let box = try Sandbox()
        let (fake, scanner) = try setup(box, after: try fullInventory { $0.removeAll { $0["Name"] as? String == "scratch_data" } })
        let target = try XCTUnwrap(volumeFindings(scanner).first { $0.title.hasSuffix("scratch_data") })

        let report = cleaner(scanner).clean([target])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, 40_000_000)
        XCTAssertEqual(fake.calls.filter { $0.contains("volume") },
                       ["--host unix://\(box.home.path)/.orbstack/run/docker.sock volume rm scratch_data"])
        XCTAssertFalse(fake.calls.contains { $0.contains("prune") || $0.contains(" -f") || $0.contains("--all") },
                       "Never prune and never force: \(fake.calls)")
    }

    func testAVolumeThatBecomesUsedAfterTheScanIsSkipped() throws {
        let box = try Sandbox()
        let (fake, scanner) = try setup(box)
        let target = try XCTUnwrap(volumeFindings(scanner).first { $0.title.hasSuffix("scratch_data") })

        // Between the scan and the clean, a container starts to use the volume.
        try fake.setInventory(try fullInventory { volumes in
            volumes = volumes.map { var v = $0; if v["Name"] as? String == "scratch_data" { v["Links"] = "1" }; return v }
        })
        let report = cleaner(scanner).clean([target])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.skipped.joined().contains("in use"))
        XCTAssertFalse(fake.calls.contains { $0.contains("volume rm") })
    }

    func testNoForgedFindingCanRemoveAVolumeThatIsInUseOrNotLocalOrUnknown() throws {
        for name in ["app_pgdata", "old_pgdata", "remote_data", "mystery_vol"] {
            let box = try Sandbox()
            let (fake, scanner) = try setup(box)
            let forged = Finding(id: "x", ecosystem: .docker, title: name, location: "x", bytes: 1, tier: .review,
                                 rebuild: .never, action: .docker(.removeVolume(name: name)))
            let report = cleaner(scanner).clean([forged])
            XCTAssertEqual(report.removed, 0, name)
            XCTAssertFalse(fake.calls.contains { $0.contains("volume rm") }, "\(name): \(fake.calls)")
        }
    }

    func testAnInformationLineCannotBeCleaned() throws {
        let box = try Sandbox()
        let (fake, scanner) = try setup(box)
        let info = try XCTUnwrap(volumeFindings(scanner).first { !$0.isActionable })
        let report = cleaner(scanner).clean([info])
        XCTAssertEqual(report.removed, 0)
        XCTAssertFalse(fake.calls.contains { $0.contains(" rm ") })
    }

    func testBadVolumeNamesGiveNoCommand() {
        for bad in ["", "-f", "--all", "-v", "a b", "x;rm -rf /", "../x", ".hidden", "_x", "name\n--force",
                    String(repeating: "a", count: 256)] {
            XCTAssertNil(DockerAction.removeVolume(name: bad).arguments, "\"\(bad)\"")
        }
        XCTAssertEqual(DockerAction.removeVolume(name: "app_pgdata").arguments, ["volume", "rm", "app_pgdata"])
        XCTAssertNotNil(DockerAction.removeVolume(name: "my-project.data_1").arguments)
    }

    func testRemoteEngineShowsNoVolumes() throws {
        let box = try Sandbox()
        let fake = try FakeDocker(box: box, contextFixture: "context-remote-tcp", inventoryFixture: "inventory-full")
        let scanner = DiskScanner(home: box.home, config: Config(), useOwnerTools: false, dockerPath: fake.path,
                                  isSocket: { _ in true })
        XCTAssertTrue(scanner.scanDocker().isEmpty)
    }

    /// A guard for the future. These commands remove more than the list shows. No code may use them.
    func testTheCodeNeverContainsABulkDeleteCommand() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 5, "The test must find the source files")

        let forbidden: [(String, String)] = [
            ("volume prune", #"volume["\s,]+prune"#),
            ("system prune", #"system["\s,]+prune"#),
            ("--volumes", #"--volumes"#),
            ("image prune with -a or --all", #"image["\s,]+prune["\s,]+[^\n]*("-a"|"--all"|\s-a\b)"#),
            ("container prune", #"container["\s,]+prune"#),
            // The bulk forms of the simulator tools. Each removes more than the list shows.
            ("simctl delete all", #"delete["\s,]+all["\s,\]]"#),
            ("simctl runtime delete --outdated", #"--outdated"#),
            ("simctl runtime delete --unusable", #"--unusable"#),
            ("simctl runtime delete --notUsedSinceDays", #"--notUsedSinceDays"#),
            ("simctl erase", #"["\s,]erase["\s,\]]"#),
        ]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (name, pattern) in forbidden where text.range(of: pattern, options: .regularExpression) != nil {
                XCTFail("\(file.lastPathComponent) contains \"\(name)\". It removes more than the list shows.")
            }
        }
    }
}

// MARK: - Docker: the Docker Desktop disk image (#12)

final class DockerDesktopDiskTests: DockerTestCase {
    private let diskPath = "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"

    /// A file that Finder shows as `logical` bytes but that uses only `written` bytes. Docker Desktop's file is like this.
    @discardableResult
    private func sparseFile(_ box: Sandbox, _ relative: String, logical: UInt64, written: Int) throws -> URL {
        let url = box.home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: written).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: logical)
        try handle.close()
        return url
    }

    private func scanner(_ box: Sandbox, socket: String) throws -> (FakeDocker, DiskScanner) {
        let fake = try FakeDocker(box: box, contextFixture: "context-local", inventoryFixture: "inventory-full",
                                  summaryFixture: "summary-full", tagTimesFixture: "tagtimes-full", socketInHome: socket)
        return (fake, DiskScanner(home: box.home, config: Config(), useOwnerTools: false, dockerPath: fake.path,
                                  isSocket: { _ in true }))
    }

    func testShowsTheRealSizeNextToTheDataInside() throws {
        let box = try Sandbox()
        try sparseFile(box, diskPath, logical: 8_000_000_000, written: 1_000_000)
        let (_, s) = try scanner(box, socket: ".docker/run/docker.sock")      // a Docker Desktop socket
        let item = try XCTUnwrap(s.scanDocker().first { $0.id == "docker.vmdisk" })

        XCTAssertEqual(item.title, "Docker Desktop disk image")
        XCTAssertGreaterThan(item.bytes, 0)
        XCTAssertLessThan(item.bytes, 2_000_000, "The size is what the file uses on this Mac, not the 8 GB that Finder shows")
        XCTAssertFalse(item.isActionable, "Information only")
        XCTAssertTrue(item.note?.contains("Holds 3.0 GB of data") == true, item.note ?? "nil")   // images + containers + volumes + cache
        XCTAssertTrue(item.note?.contains("can stay large after a clean") == true)
        XCTAssertTrue(item.location.contains("Finder may show 8.0 GB"), item.location)
        XCTAssertEqual(item.helpURL?.host, "docs.docker.com")
    }

    func testOnlyForDockerDesktop() throws {
        let box = try Sandbox()
        try sparseFile(box, diskPath, logical: 8_000_000_000, written: 1_000_000)
        let (_, s) = try scanner(box, socket: ".orbstack/run/docker.sock")     // OrbStack
        XCTAssertNil(s.scanDocker().first { $0.id == "docker.vmdisk" }, "No disk line for another engine")
    }

    func testNothingWhenThereIsNoFileOrItIsALink() throws {
        let box = try Sandbox()
        let (_, s) = try scanner(box, socket: ".docker/run/docker.sock")
        XCTAssertNil(s.scanDocker().first { $0.id == "docker.vmdisk" }, "No file")

        let real = try sparseFile(box, "elsewhere/Docker.raw", logical: 8_000_000_000, written: 1_000_000)
        let link = box.home.appendingPathComponent(diskPath)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertNil(s.scanDocker().first { $0.id == "docker.vmdisk" }, "A link is never followed")
    }

    func testNoTotalIncludesTheDiskImage() throws {
        let box = try Sandbox()
        try sparseFile(box, diskPath, logical: 8_000_000_000, written: 3_000_000)
        let found = try scanner(box, socket: ".docker/run/docker.sock").1.scanDocker()
        let result = ScanResult(findings: found, disk: DiskUsage(total: 10, free: 5))
        XCTAssertEqual(result.reclaimable + result.reviewable, found.filter(\.isActionable).reduce(0) { $0 + $1.bytes })
    }

    /// The app must never change this file. Lowering Docker's disk limit deletes it and all containers and images.
    func testTheAppCanNeverDeleteTheDiskImage() throws {
        let box = try Sandbox()
        let file = try sparseFile(box, diskPath, logical: 8_000_000_000, written: 1_000_000)
        let guardian = PathGuard(home: box.home)
        XCTAssertEqual(guardian.check(file), .protectedData("Library/Containers"))

        let forged: [Action] = [.removeContents(file.deletingLastPathComponent()), .removeArtifact(file), .removeContents(file)]
        for action in forged {
            let item = Finding(id: "x", ecosystem: .docker, title: "x", location: "x", bytes: 1, tier: .review,
                               rebuild: .never, action: action)
            XCTAssertEqual(Cleaner(guardian: guardian).clean([item]).removed, 0)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The file is still there")
    }

    func testTheHelpLinkIsTheOfficialPage() {
        XCTAssertEqual(DockerDesktopDisk.helpURL.absoluteString,
                       "https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/")
    }
}
