import XCTest
@testable import PandaCore

/// Caches of conda, Deno, and Terraform (#190). Each row has a test, and the folders next to it must stay.
final class CondaDenoTerraformTests: XCTestCase {
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func found(_ box: Sandbox) -> [Finding] {
        scanner(box).scanCaches().filter { $0.id.hasPrefix("conda.") || $0.id.hasPrefix("deno.") || $0.id.hasPrefix("terraform.") }
    }

    func testTheTerraformGroupHasNames() {
        XCTAssertEqual(Ecosystem.terraform.shortName, "Terraform")
        XCTAssertEqual(Ecosystem.terraform.name, "Terraform")
    }

    func testCondaPackagesAreFoundInEveryDocumentedPlace() throws {
        for root in ["miniconda3", "anaconda3", "miniforge3", "mambaforge", ".conda"] {
            let box = try Sandbox()
            try box.file("\(root)/pkgs/numpy-1.0-0.conda", bytes: 20_000)
            try box.file("\(root)/pkgs/numpy-1.0-0/lib/x", bytes: 20_000)
            let items = found(box)
            XCTAssertEqual(items.map(\.id), ["conda.pkgs:\(root)/pkgs"], root)
            XCTAssertEqual(items.first?.tier, .review, root)
            XCTAssertEqual(items.first?.rebuild, .download, root)
            XCTAssertEqual(items.first?.ecosystem, .python, root)
            XCTAssertNil(items.first?.owner)
        }
    }

    func testCondaCleanKeepsEnvironments() throws {
        let box = try Sandbox()
        for root in ["miniconda3", ".conda"] {
            try box.file("\(root)/pkgs/a.conda", bytes: 20_000)
            try box.file("\(root)/envs/work/bin/python", bytes: 5_000)
            try box.file("\(root)/envs/work/lib/mine.py", bytes: 5_000)
        }
        try box.file(".conda/environments.txt", bytes: 100)
        try box.file("miniconda3/bin/conda", bytes: 100)
        let items = found(box)
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items.contains { $0.location.contains("/envs") }, "envs is never an item")
        let report = cleaner(box).clean(items)
        XCTAssertEqual(report.removed, 2)
        XCTAssertFalse(exists(box, "miniconda3/pkgs/a.conda"))
        XCTAssertFalse(exists(box, ".conda/pkgs/a.conda"))
        for rel in ["miniconda3/envs/work/bin/python", "miniconda3/envs/work/lib/mine.py", ".conda/envs/work/bin/python",
                    ".conda/envs/work/lib/mine.py", ".conda/environments.txt", "miniconda3/bin/conda"] {
            XCTAssertTrue(exists(box, rel), rel)
        }
    }

    func testEnvironmentsAreProtectedByTheGuard() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        for root in ["miniconda3", "anaconda3", "miniforge3", "mambaforge", ".conda"] {
            try box.file("\(root)/envs/work/x", bytes: 10)
            XCTAssertNotNil(g.check(box.home.appendingPathComponent("\(root)/envs")), root)
            XCTAssertNotNil(g.check(box.home.appendingPathComponent("\(root)/envs/work")), root)
            XCTAssertNil(g.check(box.home.appendingPathComponent("\(root)/pkgs")), root)
        }
    }

    func testTheTerraformLoginIsProtectedByTheGuard() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        try box.file(".terraform.d/credentials.tfrc.json", bytes: 10)
        XCTAssertNotNil(g.check(box.home.appendingPathComponent(".terraform.d/credentials.tfrc.json")))
        XCTAssertNil(g.check(box.home.appendingPathComponent(".terraform.d/plugin-cache")))
    }

    func testDenoCache() throws {
        let box = try Sandbox()
        for sub in ["gen", "remote", "deps", "npm"] { try box.file("Library/Caches/deno/\(sub)/x/data", bytes: 20_000) }
        let items = found(box)
        XCTAssertEqual(items.map(\.id), ["deno.gen:Library/Caches/deno/gen", "deno.modules:Library/Caches/deno/remote",
                                         "deno.modules:Library/Caches/deno/deps", "deno.modules:Library/Caches/deno/npm"])
        XCTAssertEqual(items.map(\.tier), [.safe, .review, .review, .review])
        XCTAssertEqual(items.map(\.rebuild), [.seconds, .download, .download, .download])
        XCTAssertEqual(items.map(\.title), ["Deno compiled code cache", "Deno module downloads", "Deno module downloads",
                                            "Deno module downloads"])
        XCTAssertTrue(items.allSatisfy { $0.ecosystem == .javascript })
        let report = cleaner(box).clean(items)
        XCTAssertEqual(report.removed, 4)
        for sub in ["gen", "remote", "deps", "npm"] { XCTAssertFalse(exists(box, "Library/Caches/deno/\(sub)/x/data"), sub) }
    }

    func testDenoRemoteFolderIsAReviewItem() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/deno/remote/https/x/data", bytes: 20_000)
        let items = found(box)
        XCTAssertEqual(items.map(\.id), ["deno.modules:Library/Caches/deno/remote"])
        XCTAssertEqual(items.first?.tier, .review)
        XCTAssertEqual(items.first?.rebuild, .download)
    }

    /// `--clean-safe --yes` cleans only the safe items. Only `gen` is safe, so the modules and the REPL history stay.
    func testDenoUnattendedCleanRemovesOnlyCompiledCode() throws {
        let box = try Sandbox()
        for sub in ["gen", "remote", "deps", "npm"] { try box.file("Library/Caches/deno/\(sub)/x/data", bytes: 20_000) }
        try box.file("Library/Caches/deno/location_data/abc/local_storage", bytes: 5_000)
        try box.file("Library/Caches/deno/deno_history.txt", bytes: 300)
        let items = found(box)
        let plan = CleanPlan(ScanResult(findings: items, disk: DiskUsage(total: 1, free: 1)), guardian: scanner(box).guardian,
                             running: RunningSnapshot(apps: []), deleteMode: .permanent, unattended: true)
        XCTAssertEqual(plan.items.map(\.wouldClean), [true, false, false, false])
        let report = cleaner(box).clean(plan.items.filter(\.wouldClean).map(\.finding))
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Library/Caches/deno/gen/x/data"))
        for rel in ["Library/Caches/deno/remote/x/data", "Library/Caches/deno/deps/x/data", "Library/Caches/deno/npm/x/data",
                    "Library/Caches/deno/location_data/abc/local_storage", "Library/Caches/deno/deno_history.txt"] {
            XCTAssertTrue(exists(box, rel), rel)
        }
    }

    func testDenoCleanKeepsLocalStorageData() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/deno/deps/x", bytes: 20_000)
        try box.file("Library/Caches/deno/location_data/abc/local_storage", bytes: 5_000)
        XCTAssertEqual(found(box).map(\.id), ["deno.modules:Library/Caches/deno/deps"])
        let report = cleaner(box).clean(found(box))
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(exists(box, "Library/Caches/deno/location_data/abc/local_storage"), "your script data stays")
    }

    func testTheDenoFolderIsNotListedAgainInTheCacheExplorer() {
        XCTAssertTrue(CacheExplorer.catalogNames().contains("deno"))
    }

    func testTerraformProviderCacheIsAReviewItem() throws {
        let box = try Sandbox()
        try box.file(".terraform.d/plugin-cache/registry.terraform.io/hashicorp/aws/5.0.0/darwin_arm64/provider", bytes: 20_000)
        let items = found(box)
        XCTAssertEqual(items.map(\.id), ["terraform.plugincache:.terraform.d/plugin-cache"])
        XCTAssertEqual(items.first?.tier, .review)
        XCTAssertEqual(items.first?.rebuild, .download)
        XCTAssertEqual(items.first?.ecosystem, .terraform)
        XCTAssertNil(items.first?.owner)
    }

    func testTerraformCleanKeepsLoginStateAndProjects() throws {
        let box = try Sandbox()
        try box.file(".terraform.d/plugin-cache/p/provider", bytes: 20_000)
        try box.file(".terraform.d/credentials.tfrc.json", bytes: 200)
        try box.file(".terraform.d/plugins/mine/provider", bytes: 2_000)
        try box.file(".config/terraform/settings", bytes: 200)
        try box.file("Developer/infra/.terraform/terraform.tfstate", bytes: 20_000)
        try box.file("Developer/infra/.terraform.lock.hcl", bytes: 200)
        try box.file("Developer/infra/terraform.tfstate", bytes: 20_000)
        try box.file("Developer/infra/main.tf", bytes: 200)
        let items = found(box)
        XCTAssertEqual(items.count, 1)
        let projects = ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                                      guardian: PathGuard(home: box.home), activeDirectories: []).scan()
        XCTAssertTrue(projects.isEmpty, "no project rule for .terraform")
        _ = cleaner(box).clean(items + projects)
        XCTAssertFalse(exists(box, ".terraform.d/plugin-cache/p/provider"))
        XCTAssertTrue(exists(box, ".terraform.d/plugin-cache"), "Terraform does not make this folder, so it stays; only its contents go")
        for rel in [".terraform.d/credentials.tfrc.json", ".terraform.d/plugins/mine/provider", ".config/terraform/settings",
                    "Developer/infra/.terraform/terraform.tfstate", "Developer/infra/.terraform.lock.hcl",
                    "Developer/infra/terraform.tfstate", "Developer/infra/main.tf"] {
            XCTAssertTrue(exists(box, rel), rel)
        }
    }

    func testTheTerraformLoginAndTheEnvironmentsAreRefusedWhenForged() throws {
        let box = try Sandbox()
        try box.file(".terraform.d/credentials.tfrc.json", bytes: 200)
        try box.file(".terraform.d/plugin-cache/p/x", bytes: 20_000)
        try box.file("miniconda3/envs/work/x", bytes: 20_000)
        try box.file(".conda/envs/work/x", bytes: 20_000)
        var all: [Finding] = []
        for rel in [".terraform.d", ".terraform.d/credentials.tfrc.json", "miniconda3/envs", ".conda/envs", ".conda/envs/work"] {
            all.append(Finding(id: "x", ecosystem: .terraform, title: "x", location: rel, bytes: 1, tier: .safe, rebuild: .download,
                               action: .removeContents(box.home.appendingPathComponent(rel))))
        }
        let report = cleaner(box).clean(all)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        for rel in [".terraform.d/credentials.tfrc.json", ".terraform.d/plugin-cache/p/x", "miniconda3/envs/work/x", ".conda/envs/work/x"] {
            XCTAssertTrue(exists(box, rel), rel)
        }
    }

    func testNothingWhenTheFoldersAreMissing() throws {
        XCTAssertTrue(found(try Sandbox()).isEmpty)
    }

    // MARK: Links

    /// A folder above the cache is a link before the clean. The cleaner must delete nothing.
    func testAParentThatIsALinkIsRefused() throws {
        for (parent, cache) in [("miniconda3", "miniconda3/pkgs"), (".terraform.d", ".terraform.d/plugin-cache"),
                                ("Library/Caches/deno", "Library/Caches/deno/deps")] {
            let box = try Sandbox()
            let inner = String(cache.dropFirst(parent.count + 1))
            try box.file("elsewhere/\(inner)/x", bytes: 20_000)
            let link = box.home.appendingPathComponent(parent)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: box.home.appendingPathComponent("elsewhere"))
            let direct = Finding(id: "x", ecosystem: .python, title: "x", location: cache, bytes: 1, tier: .review, rebuild: .download,
                                 action: .removeContents(box.home.appendingPathComponent(cache)))
            let report = cleaner(box).clean(found(box) + [direct])
            XCTAssertEqual(report.removed, 0, parent)
            XCTAssertEqual(report.freed, 0, parent)
            XCTAssertTrue(exists(box, "elsewhere/\(inner)/x"), parent)
        }
    }

    /// The cache folder itself is a link: the guard refuses it.
    func testTheCacheFolderThatIsALinkIsRefused() throws {
        let box = try Sandbox()
        try box.file("elsewhere/x", bytes: 20_000)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".terraform.d"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".terraform.d/plugin-cache"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        let direct = Finding(id: "x", ecosystem: .terraform, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .download,
                             action: .removeContents(box.home.appendingPathComponent(".terraform.d/plugin-cache")))
        XCTAssertEqual(cleaner(box).clean(found(box) + [direct]).removed, 0)
        XCTAssertTrue(exists(box, "elsewhere/x"))
    }

    /// The folder above the cache becomes a link while we measure. Nothing may be deleted.
    func testBecameALinkAfterThePreview() throws {
        for (parent, cache) in [("miniconda3", "miniconda3/pkgs"), (".terraform.d", ".terraform.d/plugin-cache"),
                                ("Library/Caches/deno", "Library/Caches/deno/deps")] {
            let box = try Sandbox()
            let inner = String(cache.dropFirst(parent.count + 1))
            try box.file("\(cache)/x/data", bytes: 3_000_000)
            let items = found(box)
            XCTAssertEqual(items.count, 1, parent)
            let c = cleaner(box)
            let link = box.home.appendingPathComponent(parent)
            let moved = box.home.appendingPathComponent(parent + "-moved")
            var swapped = false
            var deletes = 0
            c.sizeOf = { url in
                if !swapped {
                    swapped = true
                    try? FileManager.default.moveItem(at: link, to: moved)
                    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: moved)
                }
                return Sizer.size(of: url)
            }
            c.deleteItem = { url in deletes += 1; try FileManager.default.removeItem(at: url) }
            let report = c.clean(items)
            XCTAssertEqual(deletes, 0, parent)
            XCTAssertEqual(report.removed, 0, parent)
            XCTAssertEqual(report.freed, 0, parent)
            XCTAssertEqual(report.skipped.count, 1, "\(report.skipped)")
            XCTAssertTrue(exists(box, "\(parent)-moved/\(inner)/x/data"), parent)
        }
    }
}
