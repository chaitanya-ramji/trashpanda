import XCTest
@testable import PandaCore

/// The validators use `\z`, so a name with a trailing newline never passes (ICU lets `$` match before a final newline).
final class TrailingNewlineTests: XCTestCase {
    func testNoValidatorAcceptsATrailingNewline() {
        XCTAssertTrue(EditorCaches.isLogName("20260213T210548"))
        XCTAssertFalse(EditorCaches.isLogName("20260213T210548\n"))
        XCTAssertTrue(EditorCaches.isExtensionFolderName("pub.name-1.0.0"))
        XCTAssertFalse(EditorCaches.isExtensionFolderName("pub.name-1.0.0\n"))
        XCTAssertTrue(LocalModels.isPart("model-1"))
        XCTAssertFalse(LocalModels.isPart("model-1\n"))
        XCTAssertTrue(HuggingFace.isRepoID("model/org/name"))
        XCTAssertFalse(HuggingFace.isRepoID("model/org/name\n"))
        XCTAssertNil(HuggingFace.parseFolderName("models--org--name\n"))
        XCTAssertNotNil(HuggingFace.parseFolderName("models--org--name"))
        XCTAssertTrue(ClaudeVersions.isVersionName("2.1.3"))
        XCTAssertFalse(ClaudeVersions.isVersionName("2.1.3\n"))
        XCTAssertTrue(Ollama.isModelName("llama3:8b"))
        XCTAssertFalse(Ollama.isModelName("llama3:8b\n"))
        XCTAssertTrue(Brew.isFormulaName("wget"))
        XCTAssertFalse(Brew.isFormulaName("wget\n"))
        XCTAssertTrue(AgentCaches.isPartitionName("p1"))
        XCTAssertFalse(AgentCaches.isPartitionName("p1\n"))
        XCTAssertTrue(CodexRuntimes.isStagingName("codex-runtime-install-abcdef"))
        XCTAssertFalse(CodexRuntimes.isStagingName("codex-runtime-install-abcdef\n"))
    }

    func testPathsWithANewlineAreRefusedByTheShapes() {
        XCTAssertFalse(AgentCaches.isCleanableShape(relative: "Library/Application Support/Claude/claude-code/2.1.3\n"))
        XCTAssertFalse(AgentCaches.isCleanableShape(relative: "Library/Application Support/Claude/Cache\n"))
        XCTAssertFalse(EditorCaches.isShape(relative: "Library/Application Support/Code/logs/20260213T210548\n"))
        XCTAssertFalse(LocalModels.isShape(relative: "Library/Application Support/Jan/data/models/m\n"))
    }
}
