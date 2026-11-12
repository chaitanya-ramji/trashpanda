import XCTest
@testable import PandaCore

/// The first-start note (#198): it shows once, at the first start, never in demo mode, and never in a loop.
final class FirstStartNoteTests: XCTestCase {
    private func settingsFile(_ box: Sandbox) -> URL {
        box.home.appendingPathComponent(".config/trashpanda/settings")
    }

    // MARK: The decision

    func testTheFirstStartShowsTheNote() {
        var note = FirstStartNote()
        XCTAssertTrue(note.showNow(isDemo: false, recorded: false))
        XCTAssertTrue(note.shownThisRun)
    }

    func testASecondStartDoesNotShowTheNote() {
        var note = FirstStartNote()
        XCTAssertFalse(note.showNow(isDemo: false, recorded: true), "the settings file says it was shown")
        XCTAssertFalse(note.shownThisRun)
    }

    func testDemoModeNeverShowsTheNoteAndKeepsTheChoice() {
        var note = FirstStartNote()
        XCTAssertFalse(note.showNow(isDemo: true, recorded: false))
        XCTAssertFalse(note.shownThisRun, "demo mode does not use up the note")
        XCTAssertTrue(note.showNow(isDemo: false, recorded: false), "a real start after a demo run still shows it")
    }

    func testInOneRunTheNoteShowsAtMostOnce() {
        var note = FirstStartNote()
        XCTAssertTrue(note.showNow(isDemo: false, recorded: false))
        XCTAssertFalse(note.showNow(isDemo: false, recorded: false), "a second ask in the same run is no")
        XCTAssertFalse(note.showNow(isDemo: false, recorded: false))
    }

    func testAFailedWriteDoesNotRepeatTheNoteInTheSameRun() throws {
        let box = try Sandbox()
        // A file where the settings folder should be: the write fails.
        let folder = box.home.appendingPathComponent(".config/trashpanda")
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "blocked".write(to: folder, atomically: true, encoding: .utf8)

        var note = FirstStartNote()
        XCTAssertTrue(note.showNow(isDemo: false, recorded: FirstStartNote.isRecorded(home: box.home)))
        XCTAssertFalse(FirstStartNote.record(home: box.home), "the settings file cannot be written")
        XCTAssertFalse(FirstStartNote.isRecorded(home: box.home), "the line was not saved")
        for _ in 0..<5 {
            XCTAssertFalse(note.showNow(isDemo: false, recorded: FirstStartNote.isRecorded(home: box.home)),
                           "the note does not come back in a loop")
        }
    }

    // MARK: The settings line

    func testRecordingWritesTheLineAndTheNextStartDoesNotShow() throws {
        let box = try Sandbox()
        XCTAssertFalse(FirstStartNote.isRecorded(home: box.home), "no file yet")
        XCTAssertTrue(FirstStartNote.record(home: box.home))
        XCTAssertTrue(FirstStartNote.isRecorded(home: box.home))
        XCTAssertEqual(try String(contentsOf: settingsFile(box), encoding: .utf8), "first_start_note = shown\n")

        var nextStart = FirstStartNote()
        XCTAssertFalse(nextStart.showNow(isDemo: false, recorded: FirstStartNote.isRecorded(home: box.home)))
    }

    func testRecordingKeepsTheOtherLines() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: settingsFile(box).deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# my note\nstale_days = 14\ndelete_mode = trash\n".write(to: settingsFile(box), atomically: true, encoding: .utf8)
        XCTAssertTrue(FirstStartNote.record(home: box.home))
        XCTAssertEqual(try String(contentsOf: settingsFile(box), encoding: .utf8),
                       "# my note\nstale_days = 14\ndelete_mode = trash\nfirst_start_note = shown\n")
        XCTAssertEqual(Config.readDeleteMode(home: box.home), .trash)
        XCTAssertEqual(Config.load(home: box.home).staleDays, 14)
    }

    func testTheLineIsReadOnlyWhenItSaysShown() {
        XCTAssertTrue(FirstStartNote.isRecorded(settingsText: "first_start_note = shown\n"))
        XCTAssertTrue(FirstStartNote.isRecorded(settingsText: "  first_start_note =  shown  \n"))
        XCTAssertFalse(FirstStartNote.isRecorded(settingsText: "# first_start_note = shown\n"), "a comment is not a record")
        XCTAssertFalse(FirstStartNote.isRecorded(settingsText: "first_start_note = no\n"))
        XCTAssertFalse(FirstStartNote.isRecorded(settingsText: "first_start_note_old = shown\n"))
        XCTAssertFalse(FirstStartNote.isRecorded(settingsText: "stale_days = 30\n"))
        XCTAssertFalse(FirstStartNote.isRecorded(settingsText: ""))
    }

    func testTheSettingsParserDoesNotWarnAboutTheLine() {
        let warnings = Config.parseSettings("first_start_note = shown\n").warnings
        XCTAssertEqual(warnings, [], "the app writes this line, so the log must not warn about it")
    }

    // MARK: The text and the link

    func testTheTextIsTheAgreedSentence() {
        XCTAssertEqual(FirstStartNote.message, "Trash Panda finds build data and caches of developer tools. It removes nothing until you ask. It never touches your code, your documents, or your settings.")
        XCTAssertEqual(FirstStartNote.okTitle, "OK")
        XCTAssertEqual(FirstStartNote.neverTouchesTitle, "What it never touches")
    }

    func testTheSecondButtonOpensTheSectionOfSecurityPolicy() {
        XCTAssertEqual(FirstStartNote.neverTouchesURL.fragment, "what-it-never-touches")
        XCTAssertTrue(FirstStartNote.neverTouchesURL.absoluteString.hasSuffix("/SECURITY.md#what-it-never-touches"))
    }
}
