import XCTest
@testable import PandaCore

/// #64: Hugging Face repositories in the hub cache, one review item each.
final class HuggingFaceTests: SimctlTestCase {
    private let hub = ".cache/huggingface/hub"

    /// A fake `hf`. It needs no Python. It handles only `cache rm <id> --yes`, records every call, and fails on anything else.
    private func fakeHF(_ box: Sandbox, fails: Bool = false) throws -> (path: String, calls: () -> [String]) {
        let dir = box.home.appendingPathComponent("fakehf", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let hubPath = box.home.appendingPathComponent(hub).path
        let script = """
        #!/bin/bash
        echo "$@" >> "\(log.path)"
        [ "$#" = "4" ] && [ "$1" = "cache" ] && [ "$2" = "rm" ] && [ "$4" = "--yes" ] || { echo "UNEXPECTED $@" >> "\(log.path)"; exit 2; }
        \(fails ? "echo 'Error: could not remove' >&2; exit 1" : "")
        f=$(echo "$3" | /usr/bin/sed 's#^model/#models--#; s#^dataset/#datasets--#; s#^space/#spaces--#; s#/#--#g')
        /bin/rm -rf "\(hubPath)/$f"
        exit 0
        """
        let path = dir.appendingPathComponent("hf").path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) })
    }
    private func makeRepo(_ box: Sandbox, _ folder: String, bytes: Int = 2_000_000, age: Int = 40) throws {
        try box.file("\(hub)/\(folder)/blobs/aaaa", bytes: bytes)
        try box.file("\(hub)/\(folder)/refs/main", bytes: 40)
        try box.file("\(hub)/\(folder)/snapshots/rev1/model.bin", bytes: 10)
        box.age(box.home.appendingPathComponent("\(hub)/\(folder)/snapshots"), days: age)
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox, hf: String?) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider, hfTool: { hf })
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func items(_ box: Sandbox) -> [Finding] { scanner(box).scanHuggingFace() }

    // MARK: Names

    func testFolderNames() {
        let ok: [(String, HuggingFace.Kind, String)] = [("models--org--name", .model, "org/name"), ("datasets--org--ds", .dataset, "org/ds"),
                                                       ("spaces--a--b", .space, "a/b"), ("models--gpt2", .model, "gpt2"),
                                                       ("models--Qwen--Qwen2.5-7B_Instruct.v1", .model, "Qwen/Qwen2.5-7B_Instruct.v1")]
        for (folder, kind, name) in ok {
            let r = HuggingFace.parseFolderName(folder)
            XCTAssertEqual(r?.0, kind, folder)
            XCTAssertEqual(r?.1, name, folder)
        }
        for bad in [".locks", "version.txt", "models--", "models----x", "models--a--b--c", "model--x", "models--a/b", "models--a--", "models--a b--c",
                    "models---x", "models--.x--y", "models--a--..", "Models--a--b", "datasets--", "xet", ""] {
            XCTAssertNil(HuggingFace.parseFolderName(bad), bad)
        }
    }

    func testRepoIDs() {
        for good in ["model/org/name", "dataset/org/ds", "space/a/b", "model/gpt2", "model/Qwen/Qwen2.5-7B"] { XCTAssertTrue(HuggingFace.isRepoID(good), good) }
        for bad in ["", "model", "model/", "models/a/b", "model/-x", "model/a/-b", "model/../x", "model/a/b/c", "model/a--b", "/model/a", "model/a b",
                    "model/a;rm", "-x/y", "model/a/b\n", String(repeating: "a", count: 201)] {
            XCTAssertFalse(HuggingFace.isRepoID(bad), bad)
        }
        XCTAssertEqual(HuggingFace.removeArguments("model/org/name"), ["cache", "rm", "model/org/name", "--yes"])
        XCTAssertNil(HuggingFace.removeArguments("-x"))
    }

    // MARK: The list

    func testEachRepositoryIsAReviewItem() throws {
        let box = try Sandbox()
        try makeRepo(box, "models--org--name", bytes: 3_000_000, age: 40)
        try makeRepo(box, "datasets--org--ds", bytes: 2_000_000, age: 5)
        try makeRepo(box, "models--gpt2", bytes: 2_000_000)
        let found = items(box)
        XCTAssertEqual(Set(found.map(\.title)), ["Hugging Face · model org/name", "Hugging Face · dataset org/ds", "Hugging Face · model gpt2"])
        XCTAssertTrue(found.allSatisfy { $0.tier == .review && $0.ecosystem == .aiAgents && $0.owner == nil })
        let m = try XCTUnwrap(found.first { $0.id == "agent.hf:model/org/name" })
        XCTAssertTrue(m.bytes >= 3_000_000 && m.bytes < 3_500_000, "\(m.bytes)")
        XCTAssertTrue(m.location.contains("40 days ago"), m.location)
        XCTAssertTrue(found.first { $0.id == "agent.hf:dataset/org/ds" }?.note?.contains("dataset") == true)
        XCTAssertNotNil(AgentProduct.info(forTitle: m.title))
        XCTAssertEqual(ScanResult(findings: found, disk: DiskUsage(total: 1, free: 1)).reclaimable, 0)
    }

    func testOnlyRepositoryFoldersAreListed() throws {
        let box = try Sandbox()
        try makeRepo(box, "models--org--name")
        try box.file("\(hub)/.locks/models--org--name/x", bytes: 2_000_000)
        try box.file("\(hub)/random/blobs/x", bytes: 2_000_000)
        try box.file("\(hub)/models--empty--shell/notes.txt", bytes: 2_000_000)          // no blobs, refs, or snapshots
        try box.file("\(hub)/version.txt", bytes: 10)
        XCTAssertEqual(items(box).map(\.id), ["agent.hf:model/org/name"])
    }

    func testARepositoryWithAFreshDownloadIsLeftAlone() throws {
        let box = try Sandbox()
        try makeRepo(box, "models--org--busy")
        try makeRepo(box, "models--org--stale")
        try box.file("\(hub)/models--org--busy/blobs/bbbb.incomplete", bytes: 100)
        try box.file("\(hub)/models--org--stale/blobs/cccc.incomplete", bytes: 100, age: 3)
        XCTAssertEqual(items(box).map(\.id), ["agent.hf:model/org/stale"], "A download from 3 days ago is abandoned")
    }

    func testLinksAreNeverFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/blobs/x", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(hub), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(hub)/models--org--link"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(items(box).isEmpty)
    }

    func testAHubThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/models--org--x/blobs/a", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".cache/huggingface"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(hub), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(items(box).isEmpty)
    }

    func testNothingWhenThereIsNoCache() throws {
        XCTAssertTrue(items(try Sandbox()).isEmpty)
    }

    func testTheHubIsNotCountedTwice() throws {
        let box = try Sandbox()
        try makeRepo(box, "models--org--name")
        XCTAssertTrue(scanner(box).scanCaches().filter { $0.id.hasPrefix("hf.cache") }.isEmpty, "The hub rows are per repository now")
    }

    // MARK: The clean

    func testTheToolRemovesOnlyTheChosenRepository() throws {
        let box = try Sandbox()
        try makeRepo(box, "models--org--name", bytes: 3_000_000)
        try makeRepo(box, "models--org--other", bytes: 2_000_000)
        try box.file(".cache/huggingface/token", bytes: 40)
        let fake = try fakeHF(box)
        let item = try XCTUnwrap(items(box).first { $0.id == "agent.hf:model/org/name" })
        let report = cleaner(box, hf: fake.path).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(report.freed >= 3_000_000 && report.freed < 3_500_000, "\(report.freed)")
        XCTAssertEqual(fake.calls(), ["cache rm model/org/name --yes"], "One command, with the id")
        XCTAssertFalse(exists(box, "\(hub)/models--org--name"))
        XCTAssertTrue(exists(box, "\(hub)/models--org--other/blobs/aaaa"))
        XCTAssertTrue(exists(box, ".cache/huggingface/token"), "The login stays")
        XCTAssertEqual(scanner(box).remainingBytes(of: item), 0)
    }

    func testWithoutTheToolOnlyThatRepositoryFolderIsDeleted() throws {
        let box = try Sandbox()
        try makeRepo(box, "datasets--org--ds", bytes: 3_000_000)
        try makeRepo(box, "datasets--org--keep", bytes: 2_000_000)
        try box.file(".cache/huggingface/token", bytes: 40)
        try box.file(".cache/huggingface/xet/c/x", bytes: 2_000_000)
        let item = try XCTUnwrap(items(box).first { $0.id == "agent.hf:dataset/org/ds" })
        let report = cleaner(box, hf: nil).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "\(hub)/datasets--org--ds"))
        XCTAssertTrue(exists(box, "\(hub)/datasets--org--keep/blobs/aaaa"))
        XCTAssertTrue(exists(box, ".cache/huggingface/token") && exists(box, ".cache/huggingface/xet/c/x"))
    }

    func testWhenTheToolFailsNothingIsDeletedByHand() throws {
        let box = try Sandbox()
        try makeRepo(box, "models--org--name")
        let fake = try fakeHF(box, fails: true)
        let item = try XCTUnwrap(items(box).first)
        let report = cleaner(box, hf: fake.path).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(fake.calls().count, 1, "A failed command is not tried again")
        XCTAssertTrue(exists(box, "\(hub)/models--org--name/blobs/aaaa"))
    }

    func testBadOrUnknownIdsNeverReachAnything() throws {
        let box = try Sandbox()
        try makeRepo(box, "models--org--name")
        let fake = try fakeHF(box)
        func forged(_ id: String) -> Finding {
            Finding(id: id, ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .download,
                    action: .agent(.removeHuggingFaceRepo(id: id)))
        }
        let report = cleaner(box, hf: fake.path).clean(["-x", "model/../x", "model/org/ghost", "models/org/name", "", "model/org/name/extra", "model/a;rm"].map(forged))
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 7)
        XCTAssertTrue(fake.calls().isEmpty, "\(fake.calls())")
        XCTAssertTrue(exists(box, "\(hub)/models--org--name/blobs/aaaa"))
    }

    func testADownloadThatStartedAfterThePreviewKeepsTheRepository() throws {
        let box = try Sandbox()
        try makeRepo(box, "models--org--name")
        let item = try XCTUnwrap(items(box).first)
        try box.file("\(hub)/models--org--name/blobs/new.incomplete", bytes: 100)
        let report = cleaner(box, hf: nil).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(box, "\(hub)/models--org--name/blobs/aaaa"))
    }

    func testAFolderThatBecameALinkAfterThePreviewIsNotFollowed() throws {
        let box = try Sandbox()
        try makeRepo(box, "models--org--name")
        try box.file("proj/blobs/precious", bytes: 1_000)
        let item = try XCTUnwrap(items(box).first)
        try FileManager.default.removeItem(at: box.home.appendingPathComponent("\(hub)/models--org--name"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent("\(hub)/models--org--name"),
                                                   withDestinationURL: box.home.appendingPathComponent("proj"))
        _ = cleaner(box, hf: nil).clean([item])
        XCTAssertTrue(exists(box, "proj/blobs/precious"))
    }

    func testTheLoginIsStillProtected() throws {
        let box = try Sandbox()
        try makeRepo(box, "models--org--name")
        let g = PathGuard(home: box.home)
        XCTAssertNil(g.check(box.home.appendingPathComponent("\(hub)/models--org--name")))
        XCTAssertNotNil(g.check(box.home.appendingPathComponent(".cache/huggingface")))
        XCTAssertNotNil(g.check(box.home.appendingPathComponent(".cache/huggingface/token")))
    }

    // MARK: The source and the dialog

    func testTheSourceNeverUsesTheInteractiveOrBulkCommands() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)) where url.pathExtension == "swift" {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                XCTAssertFalse(t.contains("delete-cache"), "\(url.lastPathComponent): \(t)")
                let lower = t.lowercased()
                XCTAssertFalse(lower.contains("\"hf\"") && (lower.contains("prune") || lower.contains("\"clean\"")), "\(url.lastPathComponent): \(t)")
                XCTAssertFalse(lower.contains("huggingface") && lower.contains("prune"), "\(url.lastPathComponent): \(t)")
            }
        }
    }

    func testTheDialogKeepsTheRepositoryByDefault() throws {
        let box = try Sandbox()
        try makeRepo(box, "models--org--name")
        let f = try XCTUnwrap(items(box).first)
        XCTAssertEqual(Confirmation.kind(of: f), .localModel)
        XCTAssertTrue(Confirmation.forOne(f, staleDays: 30).cancelIsDefault)
    }
}
