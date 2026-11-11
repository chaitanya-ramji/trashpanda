import XCTest
@testable import PandaCore

/// Q-08: the app has its own version type. The version code of one AI tool is not used for the update check.
final class SemanticVersionTests: XCTestCase {
    private func v(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

    func testABetaIsOlderThanItsRelease() {
        XCTAssertLessThan(v("0.4.0-beta.6"), v("0.4.0"))
        XCTAssertLessThan(v("0.4.0-beta.6"), v("0.4.0-beta.10"))
        XCTAssertGreaterThan(v("0.10.0"), v("0.9.9"))
        XCTAssertLessThan(v("0.8.0-beta.1"), v("0.8.0"))
        XCTAssertLessThan(v("0.4.0-beta.6"), v("0.8.0-beta.1"))
    }

    func testTheLeadingVIsOptional() {
        XCTAssertEqual(v("v1.2.3"), v("1.2.3"))
        XCTAssertEqual(v("v1.2.3-beta.4"), v("1.2.3-beta.4"))
        XCTAssertEqual(v("1.2.3-beta.4").preRelease, ["beta", "4"])
        XCTAssertTrue(v("1.2.3-beta.4").isPreRelease)
        XCTAssertFalse(v("1.2.3").isPreRelease)
    }

    func testTextThatIsNotAVersionGivesNil() {
        for bad in ["", "latest", "dev", "1.2", "1.2.x", "1.2.3.4", "1.2.3-", "1.2.3\n", "vv1.2.3", "1234567890.0.0", " 1.2.3", "1.2.3-beta..1"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testPreReleasePartsAreCompared() {
        XCTAssertLessThan(v("2.2.0-beta.9"), v("2.2.0-rc.1"))
        XCTAssertLessThan(v("2.2.0-1"), v("2.2.0-beta"))
        XCTAssertLessThan(v("2.2.0-beta"), v("2.2.0-beta.1"))
        XCTAssertFalse(v("1.0.0") < v("1.0.0"))
    }

    func testTheClaudeNamesStillWork() {
        XCTAssertTrue(ClaudeVersions.isVersionName("2.1.321"))
        XCTAssertFalse(ClaudeVersions.isVersionName("v2.1.321"), "A folder name has no v")
        XCTAssertTrue(ClaudeVersions.isNewer("2.1.10", than: "2.1.9"))
        XCTAssertTrue(ClaudeVersions.isNewer("3.12", than: "3.9"), "Names that are not versions still compare by number")
    }
}
