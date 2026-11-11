import XCTest
@testable import PandaCore

/// The guard compares names by a key: composed Unicode form, lower case. The usual disk ignores letter case.
final class GuardCaseTests: XCTestCase {
    private func check(_ box: Sandbox, _ rel: String, keep: [String] = []) -> Refusal? {
        PathGuard(home: box.home, keep: keep).check(box.home.appendingPathComponent(rel))
    }

    func testGuardRefusesProtectedTreeInOtherCase() throws {
        let box = try Sandbox()
        for rel in ["documents/a/b", "DOCUMENTS/a/b", ".SSH/x", ".Ssh/id", "library/application support/x", "LIBRARY/APPLICATION SUPPORT/x/y",
                    "library/keychains/x", ".Claude/Settings.json", ".CLAUDE/.CREDENTIALS.JSON", "Library/CACHES/CloudKit/x",
                    ".Claude/Projects/p/Memory/x"] {
            XCTAssertNotNil(check(box, rel), rel)
        }
        // The folder that contains a protected file is protected too, in any case.
        XCTAssertNotNil(check(box, ".CODEX/AUTH.JSON"))
        XCTAssertNotNil(check(box, ".Cache/HuggingFace/TOKEN"))
        XCTAssertNotNil(check(box, ".CACHE/HUGGINGFACE"))
        // The caches folder itself, in other case.
        XCTAssertNotNil(check(box, "library/caches"))
        XCTAssertNotNil(check(box, "LIBRARY/CACHES"))
    }

    func testHomePrefixInOtherCaseIsOutsideHome() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        // The home check stays exact: another case of the home folder is not the home folder.
        let upper = URL(fileURLWithPath: box.home.path.uppercased())
        XCTAssertEqual(g.check(upper.appendingPathComponent("Documents/nothing/x")), .outsideHome)
        XCTAssertEqual(g.check(upper.appendingPathComponent("Projects/app/build")), .outsideHome)
        XCTAssertNil(g.check(box.home.appendingPathComponent("Projects/app/build")))
    }

    func testNoProtectedTreeContainsAnother() {
        func key(_ t: String) -> String { t.precomposedStringWithCanonicalMapping.lowercased() }
        let keys = PathGuard.protectedHomeTrees.map(key)
        for (i, a) in keys.enumerated() {
            for (j, b) in keys.enumerated() where i != j {
                XCTAssertFalse(a == b || a.hasPrefix(b + "/"), "\(a) is inside \(b)")
            }
        }
    }

    func testKeepEntryInOtherCaseStillKeeps() throws {
        let box = try Sandbox()
        let kept = box.home.appendingPathComponent("Projects/Alpha").path
        XCTAssertEqual(check(box, "projects/alpha/build", keep: [kept]), .kept)
        XCTAssertEqual(check(box, "PROJECTS/ALPHA", keep: [kept]), .kept)
        XCTAssertNil(check(box, "projects/beta/build", keep: [kept]))
    }

    func testDecomposedAndComposedNamesAreTheSame() throws {
        let box = try Sandbox()
        let composed = "Caf\u{E9}"
        let decomposed = "Cafe\u{301}"
        // A keep entry in one form, a path in the other form.
        let kept = box.home.appendingPathComponent("work/\(composed)").path
        XCTAssertEqual(check(box, "work/\(decomposed)/x", keep: [kept]), .kept)
        let keptDecomposed = box.home.appendingPathComponent("work/\(decomposed)").path
        XCTAssertEqual(check(box, "work/\(composed.uppercased())/x", keep: [keptDecomposed]), .kept)
        // The home folder written in the other form is still the home folder.
        let homeDir = box.home.deletingLastPathComponent().appendingPathComponent("h\(decomposed)")
        try FileManager.default.createDirectory(at: homeDir.appendingPathComponent("Documents/a"), withIntermediateDirectories: true)
        let g = PathGuard(home: homeDir)
        let alt = URL(fileURLWithPath: homeDir.path.replacingOccurrences(of: decomposed, with: composed))
        XCTAssertNotNil(g.check(alt.appendingPathComponent("Documents/a")))
        XCTAssertNotEqual(g.check(alt.appendingPathComponent("Documents/a")), .outsideHome)
        XCTAssertNil(g.check(alt.appendingPathComponent("Library/Caches/pnpm")))
    }

    func testPathThatDoesNotExistIsStillRefusedInOtherCase() throws {
        let box = try Sandbox()
        for rel in ["documents/nothing/here", ".SSH/none", "library/application support/none/x", ".AWS/none/x"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path), rel)
            XCTAssertNotNil(check(box, rel), rel)
        }
    }

    func testAForgedFindingInOtherCaseIsRefused() throws {
        let box = try Sandbox()
        let data = try box.file("Documents/a/b", bytes: 2_000_000)
        let secret = try box.file(".ssh/key", bytes: 2_000_000)
        let s = DiskScanner(home: box.home, config: Config(), useOwnerTools: false)
        let targets = [box.home.appendingPathComponent("documents/a"), box.home.appendingPathComponent("DOCUMENTS/a/b"),
                       box.home.appendingPathComponent(".SSH/key"), box.home.appendingPathComponent(".SSH/new")]
        for url in targets {
            for action in [Action.removeContents(url), Action.removeArtifact(url)] {
                let f = Finding(id: "f", ecosystem: .python, title: "x", location: "x", bytes: 1, tier: .safe, rebuild: .download, action: action)
                XCTAssertEqual(Cleaner(guardian: s.guardian, runningApps: FakeRunning(apps: []).provider).clean([f]).removed, 0, url.path)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
    }

    func testASymbolicLinkIsRefused() throws {
        let box = try Sandbox()
        let target = try box.file("Library/Caches/pnpm/x", bytes: 10)
        let link = box.home.appendingPathComponent("Library/Caches/pnpm-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        XCTAssertEqual(check(box, "Library/Caches/pnpm-link"), .symlink)
        let docs = try box.file("Documents/a/b", bytes: 10)
        let link2 = box.home.appendingPathComponent("Library/Caches/to-docs")
        try FileManager.default.createSymbolicLink(at: link2, withDestinationURL: docs.deletingLastPathComponent())
        XCTAssertNotNil(check(box, "Library/Caches/to-docs"))
        XCTAssertNotNil(check(box, "Library/Caches/to-docs/b"))
    }

    func testNormalPathsAreStillAllowed() throws {
        let box = try Sandbox()
        for rel in ["Library/Caches/pnpm", "Library/Caches/Yarn/v6", ".npm/_cacache", "Projects/app/node_modules", "Library/Developer/Xcode/DerivedData/App-abc",
                    ".cache/pip", "Library/Caches/Caf\u{E9}/x"] {
            XCTAssertNil(check(box, rel), rel)
        }
    }
}
