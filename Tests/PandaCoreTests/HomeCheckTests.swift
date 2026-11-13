import XCTest
@testable import PandaCore

/// The home check of the command line (`CommandLineCheck.homeProblem`). It only reads. No test here writes anything.
final class HomeCheckTests: XCTestCase {
    /// Another letter case, or the `/System/Volumes/Data` form, is refused with the message about the real path. Normal homes pass.
    func testAHomeThatIsNotItsRealPathIsRefusedAndNormalHomesPass() throws {
        func problem(_ path: String) -> String? { CommandLineCheck.homeProblem((path, path, path))?.message }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let real = temp.path
        XCTAssertNil(problem(real))
        XCTAssertNil(problem(NSTemporaryDirectory()))
        XCTAssertNil(problem(NSHomeDirectory()))
        for good in ["/tmp", "/private/tmp", "/var/folders"] where FileManager.default.fileExists(atPath: good) {
            XCTAssertNil(problem(good), good)
        }
        let data = "/System/Volumes/Data" + real
        if FileManager.default.fileExists(atPath: data) {
            XCTAssertEqual(problem(data), CommandLineCheck.homeNotRealPathMessage)
        }
        let upper = temp.deletingLastPathComponent().path + "/" + temp.lastPathComponent.uppercased()
        if upper != real, FileManager.default.fileExists(atPath: upper) {
            XCTAssertEqual(problem(upper), CommandLineCheck.homeNotRealPathMessage)
        }
        XCTAssertFalse(CommandLineCheck.homeNotRealPathMessage.contains(real))
        XCTAssertFalse(CommandLineCheck.homeNotRealPathMessage.lowercased().contains("is a link."))
        XCTAssertEqual(problem("/"), "The home folder could not be found. Nothing was cleaned.")
        XCTAssertEqual(problem("/nope-\(UUID().uuidString)"), "The home folder could not be found. Nothing was cleaned.")
    }
}
