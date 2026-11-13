import XCTest
@testable import PandaCore

/// The home check of the command line (`CommandLineCheck.homeProblem`). It only reads. The only things written are folders and links
/// inside a fresh temp folder.
final class HomeCheckTests: XCTestCase {
    private func problem(_ path: String, use: CommandLineCheck.HomeUse = .clean) -> String? {
        CommandLineCheck.homeProblem((path, path, path), use: use)?.message
    }

    /// The real path of a folder, from `realpath(3)`. Never `resolvingSymlinksInPath` (it drops `/private`).
    private func realPath(_ url: URL) throws -> String {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(PATH_MAX))
        defer { buffer.deallocate() }
        guard realpath(url.path, buffer) != nil else { throw XCTSkip("realpath failed for \(url.path)") }
        return String(cString: buffer)
    }

    /// A fresh folder with a LOWER case name in the temp folder. The caller removes it.
    private func makeFolder() throws -> (folder: URL, real: String) {
        let name = "tpcase-" + UUID().uuidString.lowercased()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (folder, try realPath(folder))
    }

    /// The real path passes. The `/System/Volumes/Data` form is refused for the clean (and allowed for a read command).
    func testTheDataVolumeFormIsRefusedForTheCleanOnly() throws {
        let (folder, real) = try makeFolder()
        XCTAssertTrue(real.hasPrefix("/private/"), "the test path is built from realpath: \(real)")
        XCTAssertNil(problem(real))
        var form = "/System/Volumes/Data" + real
        if !FileManager.default.fileExists(atPath: form) {
            // This volume has no such form: use a link in the temp folder that leads to the real folder.
            form = folder.deletingLastPathComponent().appendingPathComponent("tplink-" + UUID().uuidString.lowercased()).path
            try FileManager.default.createSymbolicLink(atPath: form, withDestinationPath: real)
            addTeardownBlock { try? FileManager.default.removeItem(atPath: form) }
        }
        XCTAssertEqual(problem(form), CommandLineCheck.homeNotRealPathMessage, form)
        XCTAssertNil(problem(form, use: .read), "a read command allows it")
    }

    /// Another letter case is refused for the clean (and allowed for a read command). A volume that ignores the case is needed.
    func testAnotherLetterCaseIsRefusedForTheCleanOnly() throws {
        let (folder, real) = try makeFolder()
        let upper = folder.deletingLastPathComponent().path + "/" + folder.lastPathComponent.uppercased()
        guard FileManager.default.fileExists(atPath: upper) else {
            throw XCTSkip("This volume is case-sensitive: the case rule cannot be tested here.")
        }
        XCTAssertNotEqual(upper, real)
        XCTAssertNil(problem(real))
        XCTAssertEqual(problem(upper), CommandLineCheck.homeNotRealPathMessage)
        XCTAssertNil(problem(upper, use: .read), "a read command allows it")
    }

    func testNormalHomesPassAndTheMessageNamesNoPath() throws {
        let (_, real) = try makeFolder()
        XCTAssertNil(problem(real))
        XCTAssertNil(problem(NSTemporaryDirectory()))
        for good in ["/tmp", "/private/tmp", "/var/folders"] where FileManager.default.fileExists(atPath: good) {
            XCTAssertNil(problem(good), good)
        }
        XCTAssertFalse(CommandLineCheck.homeNotRealPathMessage.contains(real))
        XCTAssertFalse(CommandLineCheck.homeNotRealPathMessage.lowercased().contains("is a link."))
    }

    func testMissingRootAndFileHomesAreRefusedInBothUses() throws {
        let (folder, _) = try makeFolder()
        let file = folder.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        for use in [CommandLineCheck.HomeUse.read, .clean] {
            let done = use == .clean ? "cleaned" : "scanned"
            XCTAssertEqual(problem("/", use: use), "The home folder could not be found. Nothing was \(done).")
            XCTAssertEqual(problem("/nope-\(UUID().uuidString)", use: use), "The home folder could not be found. Nothing was \(done).")
            XCTAssertEqual(problem(file.path, use: use), "The home folder could not be found. Nothing was \(done).")
            XCTAssertNotNil(problem("~", use: use))
            XCTAssertNotNil(problem("relative", use: use))
            XCTAssertTrue(problem(".", use: use)?.hasSuffix("Nothing was \(done).") == true)
        }
    }

    // MARK: HOME must be the home folder

    private func values(_ cffixed: String?, _ home: String?, _ resolved: String, use: CommandLineCheck.HomeUse = .clean)
        -> (message: String, logLine: String?)? {
        CommandLineCheck.homeProblem((cffixed, home, resolved), use: use)
    }

    private let mismatch = "HOME and the home folder are not the same folder."

    func testHomeThatIsNotTheHomeFolderIsRefusedInEveryUse() throws {
        let (folder, real) = try makeFolder()
        let other = folder.deletingLastPathComponent().appendingPathComponent("tpother-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: other) }
        let missing = other.path + "-missing"
        let link = folder.deletingLastPathComponent().appendingPathComponent("tphome-" + UUID().uuidString.lowercased())
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }

        for use in [CommandLineCheck.HomeUse.read, .clean] {
            // Equal: fine.
            XCTAssertNil(values(real, real, real, use: use), "\(use)")
            // Two different folders that exist: refused, with no log line.
            let different = values(real, other.path, real, use: use)
            XCTAssertTrue(different?.message.hasPrefix(mismatch) == true, "\(use)")
            XCTAssertNil(different?.logLine, "nothing is logged")
            // HOME missing while the other folder exists: refused, and nothing is made.
            XCTAssertTrue(values(real, missing, real, use: use)?.message.hasPrefix(mismatch) == true, "\(use)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
            // The other way round: HOME exists, the home folder does not. That is the missing home.
            XCTAssertTrue(values(missing, real, missing, use: use)?.message.hasPrefix("The home folder could not be found.") == true)
            // Not set: nothing to compare.
            XCTAssertNil(values(nil, nil, real, use: use), "\(use)")
            XCTAssertNil(values(real, nil, real, use: use), "\(use)")
        }
        // HOME is a link to the same folder: the same folder, so it is allowed (the home is the real path).
        XCTAssertNil(values(real, link.path, real, use: .clean))
        XCTAssertNil(values(real, link.path, real, use: .read))
        // The home is the link and HOME is the real folder: the same folder. A read command allows it, the clean refuses the link.
        XCTAssertNil(values(link.path, real, link.path, use: .read))
        XCTAssertEqual(values(link.path, real, link.path, use: .clean)?.message, CommandLineCheck.homeNotRealPathMessage)
    }
}
