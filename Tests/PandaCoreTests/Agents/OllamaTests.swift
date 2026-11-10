import XCTest
@testable import PandaCore

/// A fake `ollama`. It needs no Ollama. It answers `ls` and `ps` from files, `rm` removes a row and a blob file,
/// it records every call, and it fails on a command that it does not know.
final class FakeOllama {
    let root: URL
    var path: String { root.appendingPathComponent("bin/ollama").path }
    var tool: Ollama { Ollama(path: path) }
    var calls: [String] { ((try? String(contentsOf: root.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    private let blobs: URL

    init(box: Sandbox, serverUp: Bool = true, psFails: Bool = false, rmFails: Bool = false) throws {
        root = box.home.appendingPathComponent("fakeollama", isDirectory: true)
        blobs = box.home.appendingPathComponent(".ollama/models/blobs", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        for f in ["ls.txt", "ps.txt", "calls.log"] { fm.createFile(atPath: root.appendingPathComponent(f).path, contents: Data()) }
        try "NAME    ID    SIZE    MODIFIED\n".write(to: root.appendingPathComponent("ls.txt"), atomically: true, encoding: .utf8)
        try "NAME    ID    SIZE    PROCESSOR    UNTIL\n".write(to: root.appendingPathComponent("ps.txt"), atomically: true, encoding: .utf8)
        let r = root.path, b = blobs.path
        let script = """
        #!/bin/bash
        echo "$@" >> "\(r)/calls.log"
        case "$1" in
          ls) \(serverUp ? "/bin/cat \"\(r)/ls.txt\"" : "echo 'Error: could not connect to ollama app, is it running?' >&2; exit 1") ;;
          ps) \(psFails ? "exit 1" : "/bin/cat \"\(r)/ps.txt\"") ;;
          rm)
            [ "$#" = "2" ] || { echo "UNEXPECTED $@" >> "\(r)/calls.log"; exit 2; }
            \(rmFails ? "echo 'Error: model not found' >&2; exit 1" : "")
            /usr/bin/grep -v "^$2 " "\(r)/ls.txt" > "\(r)/ls.tmp"; /bin/mv "\(r)/ls.tmp" "\(r)/ls.txt"
            /bin/rm -f "\(b)/$(echo "$2" | /usr/bin/tr '/:' '__')"
            exit 0 ;;
          *) echo "UNEXPECTED $@" >> "\(r)/calls.log"; exit 2 ;;
        esac
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// Adds a downloaded model. The blob file has the size of the model, so that a remove can be measured.
    func add(_ name: String, size: String = "4.7 GB", modified: String = "45 days ago", blobBytes: Int = 3_000_000, loaded: Bool = false) throws {
        try append("ls.txt", "\(name)    365c0bd3c000    \(size)    \(modified)")
        if loaded { try append("ps.txt", "\(name)    365c0bd3c000    5.5 GB    100% GPU    4 minutes from now") }
        try Data(repeating: 7, count: blobBytes).write(to: blobs.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")))
    }
    func append(_ file: String, _ line: String) throws {
        let url = root.appendingPathComponent(file)
        try ((try? String(contentsOf: url, encoding: .utf8)) ?? "" + "").appending(line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    func setLoaded(_ names: [String]) throws {
        try (["NAME    ID    SIZE    PROCESSOR    UNTIL"] + names.map { "\($0)    365c0bd3c000    5.5 GB    100% GPU    4 minutes from now" })
            .joined(separator: "\n").appending("\n").write(to: root.appendingPathComponent("ps.txt"), atomically: true, encoding: .utf8)
    }
    func listed(_ name: String) -> Bool { tool.models()?.contains { $0.name == name } ?? false }
    func blobExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: blobs.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")).path)
    }
}

/// #63: Ollama models. Only `ollama rm` removes a model. Nothing in `~/.ollama` is ever deleted by a path.
final class OllamaTests: SimctlTestCase {
    private func scanner(_ box: Sandbox, _ fake: FakeOllama?, stale: Int = 30) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(staleDays: stale), useOwnerTools: false, ollamaPath: fake?.path ?? "/nonexistent/ollama")
    }
    private func cleaner(_ s: DiskScanner, _ fake: FakeOllama?) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider, ollama: { fake?.tool })
    }
    private func forged(_ name: String, bytes: Int64 = 4_700_000_000) -> Finding {
        Finding(id: "agent.ollama:\(name)", ecosystem: .aiAgents, title: "Ollama · model \(name)", location: "x", bytes: bytes, tier: .review,
                rebuild: .download, action: .agent(.removeOllamaModel(name: name)))
    }

    // MARK: Reading the tool

    func testTheListIsRead() {
        let out = """
        NAME                       ID              SIZE      MODIFIED
        llama3:8b                  365c0bd3c000    4.7 GB    2 weeks ago
        hf.co/user/model:Q4_K_M    aaaabbbbcccc    274 MB    About an hour ago
        qwen2.5-coder:latest       0123456789ab    1.2 TB    3 months ago
        weird line without columns
        """
        let models = Ollama.parseList(out)
        XCTAssertEqual(models.map(\.name), ["llama3:8b", "hf.co/user/model:Q4_K_M", "qwen2.5-coder:latest"])
        XCTAssertEqual(models.map(\.bytes), [4_700_000_000, 274_000_000, 1_200_000_000_000])
        XCTAssertEqual(models.map(\.ageDays), [14, 0, 90])
    }

    func testTheSizeAndAgeRules() {
        XCTAssertEqual(Ollama.parseSize("4.7 GB"), 4_700_000_000)
        XCTAssertEqual(Ollama.parseSize("512 KB"), 512_000)
        XCTAssertEqual(Ollama.parseSize("12B"), 12)
        XCTAssertNil(Ollama.parseSize("4.7 GiB"))
        XCTAssertNil(Ollama.parseSize("big"))
        XCTAssertNil(Ollama.parseSize(""))
        XCTAssertEqual(Ollama.parseAgeDays("3 days ago"), 3)
        XCTAssertEqual(Ollama.parseAgeDays("a day ago"), 1)
        XCTAssertEqual(Ollama.parseAgeDays("About an hour ago"), 0)
        XCTAssertEqual(Ollama.parseAgeDays("1 year ago"), 365)
        XCTAssertEqual(Ollama.parseAgeDays("2 months ago"), 60)
        XCTAssertNil(Ollama.parseAgeDays("yesterday"))
        XCTAssertNil(Ollama.parseAgeDays("2 fortnights ago"))
    }

    func testTheLoadedModelsAreRead() {
        let out = "NAME          ID              SIZE      PROCESSOR    UNTIL\nllama3:8b     365c0bd3c000    5.5 GB    100% GPU     4 minutes from now\n"
        XCTAssertEqual(Ollama.parseLoaded(out), ["llama3:8b"])
        XCTAssertTrue(Ollama.parseLoaded("NAME    ID    SIZE    PROCESSOR    UNTIL\n").isEmpty)
    }

    func testNameRules() {
        for good in ["llama3:8b", "llama3", "hf.co/user/model:Q4_K_M", "library/x:latest", "a_b-c.d"] { XCTAssertTrue(Ollama.isModelName(good), good) }
        for bad in ["", "-f", "--all", "-a", "a b", "x;rm", "$(x)", "../x", "a/../b", "/abs", "x:", ":tag", "a:b:c", "x\n", "a|b", String(repeating: "a", count: 201)] {
            XCTAssertFalse(Ollama.isModelName(bad), bad)
        }
    }

    func testTheOnlyCommandIsRmWithTheName() {
        XCTAssertEqual(Ollama.removeArguments("llama3:8b"), ["rm", "llama3:8b"])
        XCTAssertNil(Ollama.removeArguments("-a"))
        XCTAssertNil(Ollama.removeArguments("--all"))
        XCTAssertEqual(Ollama.removeArguments("x")?.count, 2, "No option can be added")
    }

    // MARK: The items

    func testOnlyStaleModelsThatAreNotLoadedAreListed() throws {
        let box = try Sandbox(), fake = try FakeOllama(box: box)
        try fake.add("old:8b", modified: "45 days ago")
        try fake.add("fresh:8b", modified: "3 days ago")
        try fake.add("edge:8b", modified: "30 days ago")
        try fake.add("busy:8b", modified: "90 days ago", loaded: true)
        try fake.add("odd:8b", modified: "last tuesday")
        XCTAssertEqual(Set(scanner(box, fake).scanOllama().map(\.title)), ["Ollama · model old:8b", "Ollama · model edge:8b"])
    }

    func testTheItemIsAReviewItem() throws {
        let box = try Sandbox(), fake = try FakeOllama(box: box)
        try fake.add("old:8b")
        let item = try XCTUnwrap(scanner(box, fake).scanOllama().first)
        XCTAssertEqual(item.tier, .review)
        XCTAssertEqual(item.ecosystem, .aiAgents)
        XCTAssertEqual(item.id, "agent.ollama:old:8b")
        XCTAssertEqual(item.bytes, 4_700_000_000)
        XCTAssertNil(item.owner)
        XCTAssertNotNil(AgentProduct.info(forTitle: item.title))
        XCTAssertEqual(ScanResult(findings: [item], disk: DiskUsage(total: 1, free: 1)).reclaimable, 0)
        XCTAssertTrue(item.location.contains("45 days ago") || item.location.contains("45 days"), item.location)
    }

    func testTheStaleLimitComesFromTheSettings() throws {
        let box = try Sandbox(), fake = try FakeOllama(box: box)
        try fake.add("m:8b", modified: "10 days ago")
        XCTAssertEqual(scanner(box, fake, stale: 30).scanOllama().count, 0)
        XCTAssertEqual(scanner(box, fake, stale: 7).scanOllama().count, 1)
    }

    func testNothingWhenOllamaDoesNotAnswer() throws {
        let box = try Sandbox()
        let down = try FakeOllama(box: box, serverUp: false)
        try down.add("old:8b")
        XCTAssertTrue(scanner(box, down).scanOllama().isEmpty, "The server is off")
        XCTAssertTrue(scanner(box, nil).scanOllama().isEmpty, "Ollama is not installed")
        let noPs = try FakeOllama(box: try Sandbox(), psFails: true)
        XCTAssertTrue(DiskScanner(home: box.home, config: Config(), useOwnerTools: false, ollamaPath: noPs.path).scanOllama().isEmpty,
                      "If we cannot tell what is loaded, we show nothing")
    }

    // MARK: The clean

    func testACleanRunsOnlyRmForTheChosenModelAndMeasuresIt() throws {
        let box = try Sandbox(), fake = try FakeOllama(box: box)
        try fake.add("old:8b", blobBytes: 3_000_000)
        try fake.add("other:8b", blobBytes: 2_000_000)
        let s = scanner(box, fake)
        let item = try XCTUnwrap(s.scanOllama().first { $0.title.hasSuffix("old:8b") })
        let before = fake.calls.count
        let report = cleaner(s, fake).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(report.freed >= 3_000_000 && report.freed < 3_500_000, "\(report.freed)")
        XCTAssertFalse(fake.listed("old:8b"))
        XCTAssertTrue(fake.listed("other:8b") && fake.blobExists("other:8b"))
        let after = Array(fake.calls.dropFirst(before))
        XCTAssertEqual(after.filter { $0.hasPrefix("rm") }, ["rm old:8b"], "Exactly one remove, with the name")
        XCTAssertEqual(Set(after.map { String($0.split(separator: " ").first ?? "") }), ["ls", "ps", "rm"])
    }

    func testAModelThatBecameLoadedIsKept() throws {
        let box = try Sandbox(), fake = try FakeOllama(box: box)
        try fake.add("old:8b")
        let s = scanner(box, fake)
        let item = try XCTUnwrap(s.scanOllama().first)
        try fake.setLoaded(["old:8b"])
        let report = cleaner(s, fake).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.skipped[0].contains("loaded"), report.skipped[0])
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("rm") }, "No remove may be sent")
        XCTAssertTrue(fake.listed("old:8b"))
    }

    func testAModelThatIsGoneIsSkipped() throws {
        let box = try Sandbox(), fake = try FakeOllama(box: box)
        let report = cleaner(scanner(box, fake), fake).clean([forged("ghost:8b")])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("rm") })
    }

    func testWhenWeCannotTellWhatIsLoadedNothingIsRemoved() throws {
        let box = try Sandbox(), fake = try FakeOllama(box: box, psFails: true)
        try fake.add("old:8b")
        let report = cleaner(scanner(box, fake), fake).clean([forged("old:8b")])
        XCTAssertEqual(report.removed, 0)
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("rm") })
        XCTAssertTrue(fake.listed("old:8b"))
    }

    func testBadNamesNeverReachTheTool() throws {
        let box = try Sandbox(), fake = try FakeOllama(box: box)
        try fake.add("old:8b")
        let report = cleaner(scanner(box, fake), fake).clean(["-a", "--all", "a b", "x;rm", "../x", ""].map { forged($0) })
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 6)
        XCTAssertTrue(fake.calls.isEmpty, "\(fake.calls)")
    }

    func testWhenOllamaRefusesTheReasonIsShown() throws {
        let box = try Sandbox(), fake = try FakeOllama(box: box, rmFails: true)
        try fake.add("old:8b")
        let s = scanner(box, fake)
        let report = cleaner(s, fake).clean([try XCTUnwrap(s.scanOllama().first)])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("rm") }.count, 1, "A failed remove is not tried again")
        XCTAssertTrue(fake.listed("old:8b"))
    }

    func testOllamaMissingAtCleanTimeIsSkipped() throws {
        let box = try Sandbox()
        XCTAssertEqual(cleaner(scanner(box, nil), nil).clean([forged("old:8b")]).skipped.count, 1)
    }

    // MARK: Nothing in .ollama is ever deleted by a path

    func testTheGuardRefusesEverythingInOllama() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        for rel in [".ollama", ".ollama/models", ".ollama/models/blobs", ".ollama/models/blobs/sha256-abc", ".ollama/models/manifests/x",
                    ".ollama/id_ed25519", ".ollama/history"] {
            XCTAssertNotNil(g.check(box.home.appendingPathComponent(rel)), rel)
        }
    }

    func testAForgedPathFindingRemovesNothingInOllama() throws {
        let box = try Sandbox(), fake = try FakeOllama(box: box)
        try fake.add("old:8b")
        let blobs = box.home.appendingPathComponent(".ollama/models/blobs")
        let f = Finding(id: "f", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download, action: .removeContents(blobs))
        XCTAssertEqual(cleaner(scanner(box, fake), fake).clean([f]).removed, 0)
        XCTAssertTrue(fake.blobExists("old:8b"))
    }

    func testTheSourceNeverDeletesAnOllamaFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var checked = 0
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)) where url.pathExtension == "swift" {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                checked += 1
                XCTAssertFalse(t.lowercased().contains("ollama") && t.lowercased().contains("blobs"), "\(url.lastPathComponent): \(t)")
                XCTAssertFalse(t.lowercased().contains("ollama") && (t.contains("\"-a\"") || t.contains("--all") || t.contains("--force")), "\(url.lastPathComponent): \(t)")
            }
        }
        XCTAssertGreaterThan(checked, 1000, "The test must really read the sources")
    }

    // MARK: The dialog

    func testTheDialogKeepsTheModelByDefault() {
        let f = forged("old:8b")
        let c = Confirmation.forOne(f, staleDays: 30)
        XCTAssertEqual(Confirmation.kind(of: f), .localModel)
        XCTAssertEqual(c.title, "Remove this model?")
        XCTAssertEqual(c.confirmTitle, "Remove model")
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertTrue(c.footer?.contains("downloaded again") == true && c.footer?.contains("share") == true)
    }
}
