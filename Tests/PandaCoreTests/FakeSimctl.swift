import XCTest
@testable import PandaCore

/// Base class for every test that touches the simulator tools.
/// It hides the real `xcrun`, so that no test can reach a real simulator, runtime, or archive.
class SimctlTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        Shell.searchDirsOverride = ["/nonexistent"]
    }

    override func tearDown() {
        Shell.searchDirsOverride = nil
        super.tearDown()
    }
}

/// A fake `xcrun` for tests. It needs no Xcode.
/// - It answers `simctl runtime list -j` and `simctl list devices -j` from fixture files.
/// - It serves one answer before a delete command and another one after it.
/// - It records every call. A command that it does not know is logged as `UNEXPECTED` and fails.
final class FakeSimctl {
    let path: String
    private let dir: String
    private let logPath: String

    static func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json",
                                                  subdirectory: "Fixtures/simctl"), "missing fixture \(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `__HOME__` in a fixture stands for the fake home folder.
    init(box: Sandbox, runtimes: String = "{}", devices: String = #"{"devices":{}}"#,
         runtimesAfter: String? = nil, devicesAfter: String? = nil) throws {
        path = box.home.appendingPathComponent("bin/xcrun").path
        dir = (path as NSString).deletingLastPathComponent
        logPath = box.home.appendingPathComponent("simctl-calls.log").path
        let marker = dir + "/changed"
        let script = """
        #!/bin/bash
        echo "$*" >> "\(logPath)"
        case "$*" in
          "simctl runtime list -j")
            if [ -f "\(marker)" ]; then /bin/cat "\(dir)/runtimes-after.json"; else /bin/cat "\(dir)/runtimes-before.json"; fi
            exit 0;;
          "simctl list devices -j")
            if [ -f "\(marker)" ]; then /bin/cat "\(dir)/devices-after.json"; else /bin/cat "\(dir)/devices-before.json"; fi
            exit 0;;
          "simctl runtime delete "*|"simctl delete "*) /usr/bin/touch "\(marker)"; exit 0;;
        esac
        echo "UNEXPECTED $*" >> "\(logPath)"
        exit 1
        """
        let home = box.home.path
        func prepared(_ text: String) -> String { text.replacingOccurrences(of: "__HOME__", with: home) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try prepared(runtimes).write(toFile: dir + "/runtimes-before.json", atomically: true, encoding: .utf8)
        try prepared(runtimesAfter ?? runtimes).write(toFile: dir + "/runtimes-after.json", atomically: true, encoding: .utf8)
        try prepared(devices).write(toFile: dir + "/devices-before.json", atomically: true, encoding: .utf8)
        try prepared(devicesAfter ?? devices).write(toFile: dir + "/devices-after.json", atomically: true, encoding: .utf8)
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    convenience init(box: Sandbox, runtimesFixture: String, devicesFixture: String,
                     runtimesAfterFixture: String? = nil, devicesAfterFixture: String? = nil) throws {
        try self.init(box: box, runtimes: try FakeSimctl.fixture(runtimesFixture), devices: try FakeSimctl.fixture(devicesFixture),
                      runtimesAfter: try runtimesAfterFixture.map { try FakeSimctl.fixture($0) },
                      devicesAfter: try devicesAfterFixture.map { try FakeSimctl.fixture($0) })
    }

    /// Changes what `simctl` reports from now on. Use it to test a change after the scan.
    func setDevices(_ json: String) throws {
        try json.replacingOccurrences(of: "__HOME__", with: (dir as NSString).deletingLastPathComponent)
            .write(toFile: dir + "/devices-before.json", atomically: true, encoding: .utf8)
    }
    func setRuntimes(_ json: String) throws {
        try json.write(toFile: dir + "/runtimes-before.json", atomically: true, encoding: .utf8)
    }

    private var lines: [String] {
        ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    var calls: [String] { lines.filter { !$0.hasPrefix("UNEXPECTED ") } }
    var unexpected: [String] { lines.filter { $0.hasPrefix("UNEXPECTED ") } }
    var deletes: [String] { calls.filter { $0.contains(" delete") } }
}
