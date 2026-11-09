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
