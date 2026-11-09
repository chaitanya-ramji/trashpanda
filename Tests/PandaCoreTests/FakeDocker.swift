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
         summary: String = FakeDocker.buildCacheOnly) throws {
        path = box.home.appendingPathComponent("bin/docker").path
        logPath = box.home.appendingPathComponent("docker-calls.log").path
        let dir = (path as NSString).deletingLastPathComponent
        let files = ["context": dir + "/context.json", "before": dir + "/inventory-before.json",
                     "after": dir + "/inventory-after.json", "summary": dir + "/summary.jsonl"]
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
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// A one-line context. Most tests use this.
    convenience init(box: Sandbox, contextName: String, host: String, inventory: String = "{}",
                     inventoryAfter: String? = nil, summary: String = FakeDocker.buildCacheOnly) throws {
        let context = #"[{"Name":"\#(contextName)","Endpoints":{"docker":{"Host":"\#(host)"}}}]"#
        try self.init(box: box, context: context, inventory: inventory, inventoryAfter: inventoryAfter, summary: summary)
    }

    /// A context and inventory from fixture files. The local context points to the sandbox socket.
    convenience init(box: Sandbox, contextFixture: String, inventoryFixture: String,
                     summaryFixture: String? = nil, inventoryAfterFixture: String? = nil) throws {
        let socket = box.home.appendingPathComponent(".orbstack/run/docker.sock").path
        let context = try FakeDocker.fixture(contextFixture).replacingOccurrences(of: "__SOCKET__", with: socket)
        try self.init(box: box, context: context,
                      inventory: try FakeDocker.fixture(inventoryFixture),
                      inventoryAfter: try inventoryAfterFixture.map { try FakeDocker.fixture($0) },
                      summary: try summaryFixture.map { try FakeDocker.fixture($0, ext: "jsonl") }
                          ?? FakeDocker.buildCacheOnly)
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
        XCTAssertEqual(inventory.images.count, 7)
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
