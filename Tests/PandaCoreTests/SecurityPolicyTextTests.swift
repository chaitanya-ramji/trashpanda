import XCTest

/// The security policy must not make a promise that the app does not keep.
final class SecurityPolicyTextTests: XCTestCase {
    private func policy() throws -> String {
        // Tests run with the package folder as the current folder. Walk up from this file to be sure.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            let file = dir.appendingPathComponent("SECURITY.md")
            if FileManager.default.fileExists(atPath: file.path) { return try String(contentsOf: file, encoding: .utf8) }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("SECURITY.md not found")
    }

    func testPolicyDoesNotSayThatTheAppNeverUsesTheNetwork() throws {
        let text = try policy().lowercased()
        XCTAssertFalse(text.contains("never sends data over the network"))
        XCTAssertFalse(text.contains("never uses the network"))
    }

    func testPolicyHasTheSectionThatTheFirstStartNoteLinksTo() throws {
        // The second button of the first-start note opens this heading (#198).
        XCTAssertTrue(try policy().contains("\n## What it never touches\n"))
    }

    func testPolicyNamesTheDailyUpdateRequest() throws {
        let text = try policy()
        XCTAssertTrue(text.contains("api.github.com"))
        XCTAssertTrue(text.contains("turn it off in the menu"))
    }
}
