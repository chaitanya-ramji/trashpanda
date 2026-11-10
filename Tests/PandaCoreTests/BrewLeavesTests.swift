import XCTest
@testable import PandaCore

/// A fake `brew`. It needs no Homebrew. It keeps its state in files, records every call,
/// and fails on a command that it does not know.
final class FakeBrew {
    let root: URL
    var path: String { root.appendingPathComponent("bin/brew").path }
    var brew: Brew { Brew(path: path) }
    var calls: [String] { ((try? String(contentsOf: root.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init) }

    init(box: Sandbox, failLeaves: Bool = false) throws {
        root = box.home.appendingPathComponent("brewroot", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Cellar"), withIntermediateDirectories: true)
        for f in ["leaves.txt", "required.txt", "calls.log"] { fm.createFile(atPath: root.appendingPathComponent(f).path, contents: Data()) }
        let r = root.path
        let script = """
        #!/bin/bash
        echo "$@" >> "\(r)/calls.log"
        case "$1" in
          leaves) \(failLeaves ? "exit 3" : "/bin/cat \"\(r)/leaves.txt\"") ;;
          uninstall)
            [ "$2" = "--formula" ] || { echo "UNEXPECTED $@" >> "\(r)/calls.log"; exit 2; }
            name="${3##*/}"
            if /usr/bin/grep -qx "$name" "\(r)/required.txt"; then
              echo "Error: Refusing to uninstall \(r)/Cellar/$name because it is required by other" >&2; exit 1
            fi
            /bin/rm -rf "\(r)/Cellar/$name"
            /usr/bin/grep -vx "$3" "\(r)/leaves.txt" > "\(r)/leaves.tmp"; /bin/mv "\(r)/leaves.tmp" "\(r)/leaves.txt"
            exit 0 ;;
          *) echo "UNEXPECTED $@" >> "\(r)/calls.log"; exit 2 ;;
        esac
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// Adds an installed formula. `leaf` false means that another formula needs it.
    func install(_ name: String, bytes: Int = 2_000_000, daysAgo: Int = 100, onRequest: Bool = true, leaf: Bool = true,
                 required: Bool = false) throws {
        let dir = root.appendingPathComponent("Cellar/\(name)/1.0", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: dir.appendingPathComponent("bin/tool"))
        let time = Int(Date().addingTimeInterval(-Double(daysAgo) * 86_400).timeIntervalSince1970)
        try #"{"time": \#(time), "installed_on_request": \#(onRequest)}"#.write(to: dir.appendingPathComponent("INSTALL_RECEIPT.json"),
                                                                                  atomically: true, encoding: .utf8)
        if leaf { try append("leaves.txt", name) }
        if required { try append("required.txt", name) }
    }

    func append(_ file: String, _ line: String) throws {
        let url = root.appendingPathComponent(file)
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (old + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    func setLeaves(_ names: [String]) throws {
        try (names.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("leaves.txt"), atomically: true, encoding: .utf8)
    }
    func installed(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("Cellar/\(name)").path) }
}

final class BrewLeavesTests: SimctlTestCase {
    private func scanner(_ box: Sandbox, _ fake: FakeBrew) -> DiskScanner {
        DiskScanner(home: box.home, config: Config(), useOwnerTools: false, brewPath: fake.path)
    }
    private func cleaner(_ s: DiskScanner, _ fake: FakeBrew?, programs: [String] = []) -> Cleaner {
        Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider,
                programPaths: { programs }, brew: { fake?.brew })
    }
    private func finding(_ name: String, bytes: Int64 = 2_000_000) -> Finding {
        Finding(id: "brew.leaf:\(name)", ecosystem: .homebrew, title: "Package · \(name)", location: "x", bytes: bytes, tier: .review,
                rebuild: .download, action: .brew(.uninstall(name: name)))
    }

    // MARK: The list

    func testOnlyLeavesAreListed() throws {
        let box = try Sandbox(), fake = try FakeBrew(box: box)
        try fake.install("wget")
        try fake.install("jq")
        try fake.install("openssl@3", leaf: false)              // needed by wget
        let names = scanner(box, fake).scanBrewLeaves().map(\.title)
        XCTAssertEqual(Set(names), ["Package · wget", "Package · jq"])
    }

    func testEachPackageIsAReviewItemThatShowsItsAge() throws {
        let box = try Sandbox(), fake = try FakeBrew(box: box)
        try fake.install("wget", bytes: 3_000_000, daysAgo: 412)
        try fake.install("tmux", daysAgo: 5, onRequest: false)
        let items = scanner(box, fake).scanBrewLeaves()
        let wget = try XCTUnwrap(items.first { $0.title.hasSuffix("wget") })
        XCTAssertEqual(wget.tier, .review)
        XCTAssertEqual(wget.ecosystem, .homebrew)
        XCTAssertEqual(wget.id, "brew.leaf:wget")
        XCTAssertTrue(wget.bytes >= 3_000_000 && wget.bytes < 3_500_000, "\(wget.bytes)")
        XCTAssertTrue(wget.location.contains("installed 412 days ago"), wget.location)
        XCTAssertFalse(wget.location.contains("dependency"))
        let tmux = try XCTUnwrap(items.first { $0.title.hasSuffix("tmux") })
        XCTAssertTrue(tmux.location.contains("added only as a dependency"), tmux.location)
        XCTAssertFalse(items.contains { $0.title.lowercased().contains("unused") }, "Brew does not know if a tool is used")
    }

    func testNeverInTheOneClickTotal() throws {
        let box = try Sandbox(), fake = try FakeBrew(box: box)
        try fake.install("wget", bytes: 3_000_000)
        let result = ScanResult(findings: scanner(box, fake).scanBrewLeaves(), disk: DiskUsage(total: 1, free: 1))
        XCTAssertEqual(result.reclaimable, 0)
        XCTAssertTrue(result.reviewable >= 3_000_000)
    }

    func testBrewFailingOrMissingShowsNothing() throws {
        let box = try Sandbox()
        let bad = try FakeBrew(box: box, failLeaves: true)
        try bad.install("wget")
        XCTAssertTrue(scanner(box, bad).scanBrewLeaves().isEmpty)
        let none = DiskScanner(home: box.home, config: Config(), useOwnerTools: false, brewPath: "/nonexistent/bin/brew")
        XCTAssertTrue(none.scanBrewLeaves().isEmpty)
    }

    func testAnOddNameFromBrewIsNeverUsed() throws {
        let box = try Sandbox(), fake = try FakeBrew(box: box)
        try fake.install("wget")
        try fake.append("leaves.txt", "-rf")
        try fake.append("leaves.txt", "../escape")
        try fake.append("leaves.txt", "Has Space")
        try fake.append("leaves.txt", "--force")
        XCTAssertEqual(scanner(box, fake).scanBrewLeaves().map(\.title), ["Package · wget"])
    }

    func testAFormulaFolderThatIsALinkIsSkipped() throws {
        let box = try Sandbox(), fake = try FakeBrew(box: box)
        try box.file("elsewhere/x/1.0/bin/tool", bytes: 5_000_000)
        try FileManager.default.createSymbolicLink(at: fake.root.appendingPathComponent("Cellar/sneaky"),
                                                   withDestinationURL: box.home.appendingPathComponent("elsewhere/x"))
        try fake.append("leaves.txt", "sneaky")
        XCTAssertTrue(scanner(box, fake).scanBrewLeaves().isEmpty)
    }

    func testATapNameUsesTheFolderOfItsLastPart() throws {
        let box = try Sandbox(), fake = try FakeBrew(box: box)
        try fake.install("terraform", leaf: false)
        try fake.append("leaves.txt", "hashicorp/tap/terraform")
        let item = try XCTUnwrap(scanner(box, fake).scanBrewLeaves().first)
        XCTAssertEqual(item.id, "brew.leaf:hashicorp/tap/terraform")
        XCTAssertTrue(item.bytes >= 2_000_000)
    }

    // MARK: The command

    func testNameRules() {
        for good in ["wget", "openssl@3", "python@3.12", "gcc-12", "c++", "hashicorp/tap/terraform", "a_b", "0ad"] {
            XCTAssertTrue(Brew.isFormulaName(good), good)
        }
        for bad in ["", "-rf", "--force", " wget", "wget ", "a b", "../x", "a/../b", "A", "x;rm", "$(x)", "a/b/c/d", "/etc", "x\n"] {
            XCTAssertFalse(Brew.isFormulaName(bad), bad)
        }
    }

    func testTheCommandHasOneFixedShapeAndNoForce() {
        XCTAssertEqual(BrewAction.uninstall(name: "wget").arguments, ["uninstall", "--formula", "wget"])
        XCTAssertNil(BrewAction.uninstall(name: "-rf").arguments)
        XCTAssertNil(BrewAction.uninstall(name: "").arguments)
        for name in ["wget", "openssl@3", "a/b/c"] {
            let args = BrewAction.uninstall(name: name).arguments ?? []
            for forbidden in ["--force", "-f", "--ignore-dependencies", "--zap", "--cask"] { XCTAssertFalse(args.contains(forbidden)) }
        }
    }

    // MARK: The clean

    func testACleanUninstallsOnlyTheChosenPackageAndMeasuresIt() throws {
        let box = try Sandbox(), fake = try FakeBrew(box: box)
        try fake.install("wget", bytes: 3_000_000)
        try fake.install("jq", bytes: 2_000_000)
        let s = scanner(box, fake)
        let item = try XCTUnwrap(s.scanBrewLeaves().first { $0.title.hasSuffix("wget") })
        let before = fake.calls.count
        let report = cleaner(s, fake).clean([item])
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(report.freed >= 3_000_000 && report.freed < 3_500_000, "\(report.freed)")
        XCTAssertFalse(fake.installed("wget"))
        XCTAssertTrue(fake.installed("jq"))
        XCTAssertEqual(Array(fake.calls.dropFirst(before)), ["leaves", "uninstall --formula wget"], "Nothing else may run")
        XCTAssertEqual(s.remainingBytes(of: item), 0)
    }

    func testAPackageThatIsNotALeafAnyMoreIsSkipped() throws {
        let box = try Sandbox(), fake = try FakeBrew(box: box)
        try fake.install("wget")
        let s = scanner(box, fake)
        let item = try XCTUnwrap(s.scanBrewLeaves().first)
        try fake.setLeaves([])                                   // the user installed a tool that needs it
        let report = cleaner(s, fake).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(fake.installed("wget"))
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("uninstall") }, "No uninstall may be sent")
    }

    func testWhenBrewRefusesNothingChangesAndTheReasonIsShown() throws {
        let box = try Sandbox(), fake = try FakeBrew(box: box)
        try fake.install("wget", required: true)
        let s = scanner(box, fake)
        let item = try XCTUnwrap(s.scanBrewLeaves().first)
        let report = cleaner(s, fake).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.freed, 0)
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertTrue(report.failed[0].contains("Refusing to uninstall"), report.failed[0])
        XCTAssertTrue(fake.installed("wget"))
    }

    func testAPackageThatRunsIsSkipped() throws {
        let box = try Sandbox(), fake = try FakeBrew(box: box)
        try fake.install("postgresql@16")
        let s = scanner(box, fake)
        let item = try XCTUnwrap(s.scanBrewLeaves().first)
        let running = fake.root.appendingPathComponent("Cellar/postgresql@16/1.0/bin/postgres").path
        let report = cleaner(s, fake, programs: [running]).clean([item])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.skipped[0].contains("runs"), report.skipped[0])
        XCTAssertTrue(fake.installed("postgresql@16"))
    }

    func testAnInvalidNameOrMissingBrewIsRefused() throws {
        let box = try Sandbox(), fake = try FakeBrew(box: box)
        try fake.install("wget")
        let s = scanner(box, fake)
        let bad = cleaner(s, fake).clean([finding("-rf"), finding("../x")])
        XCTAssertEqual(bad.removed, 0)
        XCTAssertEqual(bad.skipped.count, 2)
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(cleaner(s, nil).clean([finding("wget")]).skipped.count, 1)
        XCTAssertTrue(fake.installed("wget"))
    }

    // MARK: The dialog

    func testTheDialogKeepsThePackageByDefault() throws {
        let c = Confirmation.forOne(finding("wget"), staleDays: 30)
        XCTAssertEqual(Confirmation.kind(of: finding("wget")), .brewPackage)
        XCTAssertEqual(c.title, "Uninstall this package?")
        XCTAssertEqual(c.confirmTitle, "Uninstall")
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertTrue(c.footer?.contains("refuses when another package needs it") == true)
    }
}
