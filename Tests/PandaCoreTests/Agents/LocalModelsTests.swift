import XCTest
@testable import PandaCore

/// #65: models of LM Studio, Jan, and GPT4All. Chats and settings live next to the models.
final class LocalModelsTests: XCTestCase {
    private let jan = "Library/Application Support/Jan/data"
    private let gpt = "Library/Application Support/nomic.ai/GPT4All"

    private func makeAll(_ box: Sandbox) throws {
        try box.file(".lmstudio/models/lmstudio-community/Llama-3-8B-GGUF/llama-3-8b-q4.gguf", bytes: 3_000_000)
        try box.file(".lmstudio/models/lmstudio-community/Llama-3-8B-GGUF/README.md", bytes: 100)
        try box.file(".lmstudio/settings.json", bytes: 100)
        try box.file(".lmstudio/conversations/c1.json", bytes: 100)
        try box.file("\(jan)/models/tinyllama/model.gguf", bytes: 2_000_000)
        try box.file("\(jan)/models/tinyllama/model.json", bytes: 100)
        try box.file("\(jan)/threads/t1/messages.jsonl", bytes: 100)
        try box.file("\(jan)/settings/s.json", bytes: 100)
        try box.file("\(jan)/models/.internal/x", bytes: 100)
        try box.file("\(gpt)/Meta-Llama-3-8B-Instruct.Q4_0.gguf", bytes: 4_000_000)
        try box.file("\(gpt)/chats/c1.chat", bytes: 100)
        try box.file("\(gpt)/gpt4all.ini", bytes: 100)
        try box.file("\(gpt)/localdocs_v3.db", bytes: 100)
        try box.file("\(gpt)/notes.txt", bytes: 100)
        try box.file(".cache/gpt4all/orca-mini.gguf", bytes: 2_500_000)
    }
    private let kept = [".lmstudio/settings.json", ".lmstudio/conversations/c1.json", "Library/Application Support/Jan/data/threads/t1/messages.jsonl",
                        "Library/Application Support/Jan/data/settings/s.json", "Library/Application Support/Jan/data/models/.internal/x",
                        "Library/Application Support/nomic.ai/GPT4All/chats/c1.chat", "Library/Application Support/nomic.ai/GPT4All/gpt4all.ini",
                        "Library/Application Support/nomic.ai/GPT4All/localdocs_v3.db", "Library/Application Support/nomic.ai/GPT4All/notes.txt"]
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox, running: [RunningApp] = [], processes: Set<String> = []) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: running, processes: processes).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func items(_ box: Sandbox) -> [Finding] { scanner(box).scanLocalModels() }

    // MARK: The names and the shapes

    func testPartRules() {
        for good in ["Llama-3-8B-GGUF", "model.v1", "a b", "Q4_0", "x(1)", "a+b", "0"] { XCTAssertTrue(LocalModels.isPart(good), good) }
        for bad in ["", ".internal", ".hidden", " x", "x ", "..", "a..b", "a/b", "x\n", "-", "_x", String(repeating: "a", count: 201)] {
            XCTAssertFalse(LocalModels.isPart(bad), "\"\(bad)\"")
        }
    }

    func testModelNamesMustHaveTheExactDepth() throws {
        let lm = try XCTUnwrap(LocalModels.store(id: "lmstudio")), jn = try XCTUnwrap(LocalModels.store(id: "jan")), g = try XCTUnwrap(LocalModels.store(id: "gpt4all"))
        XCTAssertTrue(LocalModels.isModelName("pub/model", in: lm))
        for bad in ["pub", "pub/model/file.gguf", "pub//model", "/pub/model", "pub/../x", ".x/model"] { XCTAssertFalse(LocalModels.isModelName(bad, in: lm), bad) }
        XCTAssertTrue(LocalModels.isModelName("tinyllama", in: jn))
        XCTAssertFalse(LocalModels.isModelName("a/b", in: jn))
        XCTAssertTrue(LocalModels.isModelName("m.Q4.gguf", in: g))
        XCTAssertTrue(LocalModels.isModelName("M.GGUF", in: g))
        for bad in ["m.bin", ".gguf", "m.gguf.part", "chats/c.gguf", "gpt4all.ini", "m.gguf/x"] { XCTAssertFalse(LocalModels.isModelName(bad, in: g), bad) }
    }

    func testTheGuardAllowsOnlyOneModelInApplicationSupport() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        func check(_ rel: String) -> Refusal? { g.check(box.home.appendingPathComponent(rel)) }
        XCTAssertNil(check("\(jan)/models/tinyllama"))
        XCTAssertNil(check("\(gpt)/Meta-Llama-3-8B-Instruct.Q4_0.gguf"))
        for rel in ["\(jan)", "\(jan)/models", "\(jan)/models/tinyllama/model.gguf", "\(jan)/models/.internal", "\(jan)/threads", "\(jan)/threads/t1",
                    "\(jan)/settings", "\(jan)/models/a/b", "\(gpt)", "\(gpt)/chats", "\(gpt)/chats/c1.chat", "\(gpt)/gpt4all.ini",
                    "\(gpt)/localdocs_v3.db", "\(gpt)/notes.txt", "\(gpt)/model.bin", "Library/Application Support/Jan",
                    "Library/Application Support/Jan/data/models/../threads", "Library/Application Support/nomic.ai"] {
            XCTAssertNotNil(check(rel), rel)
        }
    }

    func testTheTableMatchesTheProductTable() {
        for s in LocalModels.stores {
            XCTAssertNotNil(AgentProduct.info(forTitle: "\(s.product) · model x"), s.id)
            XCTAssertFalse(s.owner.bundleIDs.isEmpty && s.owner.processNames.isEmpty, "\(s.id) needs an owner")
        }
        XCTAssertEqual(Set(LocalModels.stores.map(\.id)).count, LocalModels.stores.count)
    }

    // MARK: The list

    func testEachModelIsAReviewItem() throws {
        let box = try Sandbox()
        try makeAll(box)
        let found = items(box)
        XCTAssertEqual(Set(found.map(\.id)), ["agent.model:lmstudio:lmstudio-community/Llama-3-8B-GGUF", "agent.model:jan:tinyllama",
                                              "agent.model:gpt4all:Meta-Llama-3-8B-Instruct.Q4_0.gguf", "agent.model:gpt4all-py:orca-mini.gguf"])
        XCTAssertTrue(found.allSatisfy { $0.tier == .review && $0.ecosystem == .aiAgents && $0.owner != nil })
        let lm = try XCTUnwrap(found.first { $0.id.hasPrefix("agent.model:lmstudio:") })
        XCTAssertEqual(lm.title, "LM Studio · model lmstudio-community/Llama-3-8B-GGUF")
        XCTAssertTrue(lm.bytes >= 3_000_000 && lm.bytes < 3_200_000, "\(lm.bytes)")
        XCTAssertEqual(ScanResult(findings: found, disk: DiskUsage(total: 1, free: 1)).reclaimable, 0)
    }

    func testOnlyRealModelsAreListed() throws {
        let box = try Sandbox()
        try makeAll(box)
        try box.file(".lmstudio/models/stray.gguf", bytes: 2_000_000)                    // depth 1: not a model of this layout
        try box.file(".lmstudio/models/pub/model/deeper/x.gguf", bytes: 2_000_000)       // counted inside pub/model, not as its own model
        try box.file("\(gpt)/model.bin", bytes: 2_000_000)
        let names = items(box).map(\.title)
        XCTAssertFalse(names.contains { $0.contains("stray") || $0.contains("model.bin") || $0.contains("deeper") })
        XCTAssertFalse(names.contains { $0.contains("internal") || $0.contains("threads") || $0.contains("chats") })
    }

    func testLinksAreNeverFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/x.gguf", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".cache/gpt4all"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".cache/gpt4all/link.gguf"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere/x.gguf"))
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".lmstudio/models/pub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".lmstudio/models/pub/linked"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(items(box).isEmpty)
    }

    func testARootThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/pub/model/x.gguf", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".lmstudio"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".lmstudio/models"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try box.file("elsewhere2/Jan/data/models/m/x.gguf", bytes: 3_000_000)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("Library/Application Support"), withDestinationURL: box.home.appendingPathComponent("elsewhere2"))
        XCTAssertTrue(items(box).isEmpty)
    }

    func testNothingWhenNothingIsInstalled() throws {
        XCTAssertTrue(items(try Sandbox()).isEmpty)
    }

    // MARK: The clean

    func testACleanRemovesOnlyThatModel() throws {
        let box = try Sandbox()
        try makeAll(box)
        let item = try XCTUnwrap(items(box).first { $0.id == "agent.model:jan:tinyllama" })
        let report = cleaner(box).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, item.bytes)
        XCTAssertFalse(exists(box, "\(jan)/models/tinyllama"))
        XCTAssertTrue(exists(box, "\(jan)/models"), "The folder of the models stays")
        XCTAssertTrue(exists(box, ".lmstudio/models/lmstudio-community/Llama-3-8B-GGUF/llama-3-8b-q4.gguf"))
        XCTAssertTrue(exists(box, "\(gpt)/Meta-Llama-3-8B-Instruct.Q4_0.gguf"))
        for k in kept { XCTAssertTrue(exists(box, k), k) }
        XCTAssertEqual(scanner(box).remainingBytes(of: item), 0)
    }

    func testEveryModelCanBeRemovedAndEverythingElseStays() throws {
        let box = try Sandbox()
        try makeAll(box)
        let report = cleaner(box).clean(items(box))
        XCTAssertEqual(report.removed, 4)
        XCTAssertTrue(items(box).isEmpty)
        for k in kept { XCTAssertTrue(exists(box, k), k) }
    }

    func testAnOpenAppBlocksItsModels() throws {
        let box = try Sandbox()
        try makeAll(box)
        let lm = try XCTUnwrap(items(box).first { $0.id.hasPrefix("agent.model:lmstudio:") })
        let report = cleaner(box, running: [RunningApp(bundleID: "ai.elementlabs.lmstudio", name: "LM Studio")]).clean([lm])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.blockedApps, ["LM Studio"])
        XCTAssertTrue(exists(box, ".lmstudio/models/lmstudio-community/Llama-3-8B-GGUF/llama-3-8b-q4.gguf"))
    }

    func testARunningGPT4AllProcessBlocksItsModels() throws {
        let box = try Sandbox()
        try makeAll(box)
        let g = try XCTUnwrap(items(box).first { $0.id == "agent.model:gpt4all:Meta-Llama-3-8B-Instruct.Q4_0.gguf" })
        XCTAssertEqual(cleaner(box, processes: ["gpt4all"]).clean([g]).removed, 0)
        XCTAssertTrue(exists(box, "\(gpt)/Meta-Llama-3-8B-Instruct.Q4_0.gguf"))
    }

    func testForgedNamesRemoveNothing() throws {
        let box = try Sandbox()
        try makeAll(box)
        func forged(_ store: String, _ name: String) -> Finding {
            Finding(id: name, ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .download,
                    action: .agent(.removeLocalModel(storeID: store, name: name)))
        }
        let report = cleaner(box).clean([forged("jan", ".internal"), forged("jan", "../threads"), forged("jan", "threads"), forged("jan", "models"),
                                         forged("jan", ""), forged("gpt4all", "gpt4all.ini"), forged("gpt4all", "chats"), forged("gpt4all", "notes.txt"),
                                         forged("lmstudio", "lmstudio-community"), forged("lmstudio", "lmstudio-community/Llama-3-8B-GGUF/llama-3-8b-q4.gguf"),
                                         forged("nope", "x"), forged("../x", "y")])
        XCTAssertEqual(report.removed, 0)
        for k in kept { XCTAssertTrue(exists(box, k), k) }
        XCTAssertTrue(exists(box, ".lmstudio/models/lmstudio-community/Llama-3-8B-GGUF/llama-3-8b-q4.gguf"))
        XCTAssertTrue(exists(box, "\(jan)/threads/t1/messages.jsonl"))
    }

    func testAModelThatBecameALinkAfterThePreviewIsNotFollowed() throws {
        let box = try Sandbox()
        try makeAll(box)
        try box.file("proj/precious", bytes: 1_000)
        let item = try XCTUnwrap(items(box).first { $0.id == "agent.model:jan:tinyllama" })
        try FileManager.default.removeItem(at: box.home.appendingPathComponent("\(jan)/models/tinyllama"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(jan)/models/tinyllama"), withDestinationURL: box.home.appendingPathComponent("proj"))
        _ = cleaner(box).clean([item])
        XCTAssertTrue(exists(box, "proj/precious"))
    }

    func testAForgedPathFindingForUserDataIsRefused() throws {
        let box = try Sandbox()
        try makeAll(box)
        for rel in ["\(jan)/threads", "\(jan)/threads/t1", "\(gpt)/chats", "\(gpt)/localdocs_v3.db", "\(gpt)/gpt4all.ini"] {
            let f = Finding(id: rel, ecosystem: .aiAgents, title: "x", location: rel, bytes: 1, tier: .review, rebuild: .download,
                            action: .removeContents(box.home.appendingPathComponent(rel)))
            XCTAssertEqual(cleaner(box).clean([f]).removed, 0, rel)
        }
        for k in kept { XCTAssertTrue(exists(box, k), k) }
    }

    func testTheDialogKeepsTheModelByDefault() throws {
        let box = try Sandbox()
        try makeAll(box)
        let f = try XCTUnwrap(items(box).first)
        XCTAssertEqual(Confirmation.kind(of: f), .localModel)
        let c = Confirmation.forOne(f, staleDays: 30)
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertFalse(c.footer?.contains("Ollama") == true, "The wording is for every kind of model")
    }
}
