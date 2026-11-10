import XCTest
@testable import PandaCore

/// #67: old session transcripts of Codex and Claude Code. Conversations cannot be resumed after they are deleted.
final class AgentSessionsTests: XCTestCase {
    private let uuid1 = "0a1b2c3d-1111-2222-3333-444455556666"
    private let uuid2 = "9f8e7d6c-aaaa-bbbb-cccc-ddddeeeeffff"
    private let big = 1_500_000

    private func makeCodex(_ box: Sandbox) throws {
        try box.file(".codex/sessions/2026/09/01/rollout-a.jsonl", bytes: big, age: 60)
        try box.file(".codex/sessions/2026/09/02/rollout-b.jsonl.zst", bytes: big, age: 45)
        try box.file(".codex/sessions/2026/11/09/rollout-new.jsonl", bytes: big, age: 2)
        try box.file(".codex/archived_sessions/rollout-old.jsonl", bytes: big, age: 90)
        for keep in ["auth.json", "config.toml", "state_5.sqlite", "thread_history_1.sqlite", "memories_1.sqlite", "skills/s/SKILL.md",
                     "sessions/index.sqlite", "sessions/2026/09/01/notes.txt", "sessions/2026/09/01/.hidden.jsonl", "plugins/x/y.jsonl"] {
            try box.file(".codex/\(keep)", bytes: 500, age: 120)
        }
    }
    private func makeClaude(_ box: Sandbox) throws {
        try box.file(".claude/projects/-Users-me-proj/\(uuid1).jsonl", bytes: big, age: 50)
        try box.file(".claude/projects/-Users-me-proj/\(uuid2).jsonl", bytes: big, age: 3)
        try box.file(".claude/projects/-Users-me-proj/memory/MEMORY.md", bytes: 500, age: 200)
        try box.file(".claude/projects/-Users-me-proj/memory/notes.jsonl", bytes: 500, age: 200)
        try box.file(".claude/projects/-Users-me-proj/not-a-uuid.jsonl", bytes: big, age: 200)
        try box.file(".claude/projects/-Users-me-proj/\(uuid1)/subagents/a.jsonl", bytes: big, age: 200)
        try box.file(".claude/history.jsonl", bytes: 500, age: 200)
        try box.file(".claude/.credentials.json", bytes: 50, age: 200)
        try box.file(".claude/settings.json", bytes: 50, age: 200)
        try box.file(".claude/plugins/p/x.jsonl", bytes: 500, age: 200)
    }
    private let keptCodex = [".codex/auth.json", ".codex/config.toml", ".codex/state_5.sqlite", ".codex/thread_history_1.sqlite", ".codex/memories_1.sqlite",
                             ".codex/skills/s/SKILL.md", ".codex/sessions/index.sqlite", ".codex/sessions/2026/09/01/notes.txt",
                             ".codex/sessions/2026/09/01/.hidden.jsonl", ".codex/plugins/x/y.jsonl", ".codex/sessions/2026/11/09/rollout-new.jsonl"]
    private let keptClaude = [".claude/projects/-Users-me-proj/memory/MEMORY.md", ".claude/projects/-Users-me-proj/memory/notes.jsonl",
                              ".claude/projects/-Users-me-proj/not-a-uuid.jsonl", ".claude/history.jsonl", ".claude/.credentials.json",
                              ".claude/settings.json", ".claude/plugins/p/x.jsonl"]

    private func scanner(_ box: Sandbox, stale: Int = 30) -> DiskScanner { DiskScanner(home: box.home, config: Config(staleDays: stale), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }
    private func item(_ box: Sandbox, _ kind: AgentSessions.Kind, stale: Int = 30) -> Finding? { scanner(box, stale: stale).scanAgentSessions().first { $0.id == kind.findingID } }

    // MARK: Which files are transcripts

    func testCodexTranscriptNames() {
        func t(_ p: String) -> Bool { AgentSessions.isTranscript(p.split(separator: "/").map(String.init), kind: .codex) }
        XCTAssertTrue(t("2026/09/01/rollout-a.jsonl"))
        XCTAssertTrue(t("2026/09/01/rollout-a.jsonl.zst"))
        XCTAssertTrue(t("rollout.jsonl"))
        for bad in ["", "auth.json", "x.sqlite", "2026/09/01/.hidden.jsonl", "a/b/c/d/e.jsonl", "2026/09/01/x.jsonl.bak", "../x.jsonl", "a b/x.jsonl", "x.jsonl/y"] {
            XCTAssertFalse(t(bad), bad)
        }
    }

    func testClaudeTranscriptNames() {
        func t(_ p: String) -> Bool { AgentSessions.isTranscript(p.split(separator: "/").map(String.init), kind: .claude) }
        XCTAssertTrue(t("-Users-me-proj/\(uuid1).jsonl"))
        for bad in ["\(uuid1).jsonl", "-Users-me-proj/memory/\(uuid1).jsonl", "-Users-me-proj/\(uuid1)/a.jsonl", "-Users-me-proj/x.jsonl",
                    "-Users-me-proj/\(uuid1).jsonl.zst", "-Users-me-proj/\(uuid1).json", "..//\(uuid1).jsonl", "p/\(uuid1)x.jsonl", "p/.\(uuid1).jsonl"] {
            XCTAssertFalse(t(bad), bad)
        }
    }

    // MARK: The age rule and the items

    func testOnlyTranscriptsOlderThanTheLimitAreListed() throws {
        let box = try Sandbox()
        try makeCodex(box)
        let f = try XCTUnwrap(item(box, .codex))
        XCTAssertEqual(f.title, "Codex · old sessions")
        XCTAssertEqual(f.tier, .review)
        XCTAssertEqual(f.ecosystem, .aiAgents)
        XCTAssertTrue(f.location.contains("3 sessions older than 30 days") && f.location.contains("the oldest is 90 days old"), f.location)
        XCTAssertTrue(f.bytes >= 3 * big && f.bytes < 4 * big, "\(f.bytes)")
        XCTAssertNil(f.owner)
        XCTAssertNotNil(AgentProduct.info(forTitle: f.title))
        XCTAssertEqual(ScanResult(findings: [f], disk: DiskUsage(total: 1, free: 1)).reclaimable, 0)
    }

    func testTheClaudeItemNamesTheToolsOwnSetting() throws {
        let box = try Sandbox()
        try makeClaude(box)
        let f = try XCTUnwrap(item(box, .claude))
        XCTAssertEqual(f.title, "Claude · old Code sessions")
        XCTAssertTrue(f.location.contains("1 session older") && f.location.contains("cleanupPeriodDays"), f.location)
        XCTAssertTrue(f.bytes >= big && f.bytes < 2 * big, "\(f.bytes)")
    }

    func testTheLimitComesFromTheSettings() throws {
        let box = try Sandbox()
        try makeClaude(box)
        XCTAssertNotNil(item(box, .claude, stale: 30))
        XCTAssertNil(item(box, .claude, stale: 60), "The session is 50 days old")
        XCTAssertNotNil(item(box, .claude, stale: 2), "and the other is 3 days old")
    }

    func testTheLimitIsExact() throws {
        let box = try Sandbox()
        let url = try box.file(".codex/sessions/a.jsonl", bytes: big)
        let now = Date()
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: url.path)
        XCTAssertEqual(AgentSessions.entries(.codex, home: box.home, olderThan: cutoff).count, 1, "30 days old counts")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400 + 60)], ofItemAtPath: url.path)
        XCTAssertTrue(AgentSessions.entries(.codex, home: box.home, olderThan: cutoff).isEmpty)
    }

    func testNothingWhenThereIsNothing() throws {
        let box = try Sandbox()
        XCTAssertTrue(scanner(box).scanAgentSessions().isEmpty)
        try box.file(".claude/projects/p/\(uuid1).jsonl", bytes: big, age: 1)
        XCTAssertTrue(scanner(box).scanAgentSessions().isEmpty)
    }

    func testLinksAreNeverFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/x.jsonl", bytes: big, age: 90)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".codex/sessions/link.jsonl"), withDestinationURL: box.home.appendingPathComponent("elsewhere/x.jsonl"))
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".codex/sessions/2026"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(scanner(box).scanAgentSessions().isEmpty)
    }

    func testARootThatIsALinkIsNotFollowed() throws {
        let box = try Sandbox()
        try box.file("elsewhere/p/\(uuid1).jsonl", bytes: big, age: 90)
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".claude/projects"), withDestinationURL: box.home.appendingPathComponent("elsewhere"))
        XCTAssertTrue(scanner(box).scanAgentSessions().isEmpty)
    }

    // MARK: The clean

    func testACleanRemovesOnlyOldCodexTranscripts() throws {
        let box = try Sandbox()
        try makeCodex(box)
        let f = try XCTUnwrap(item(box, .codex))
        let report = cleaner(box).clean([f])
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(report.freed, f.bytes)
        for gone in [".codex/sessions/2026/09/01/rollout-a.jsonl", ".codex/sessions/2026/09/02/rollout-b.jsonl.zst", ".codex/archived_sessions/rollout-old.jsonl"] {
            XCTAssertFalse(exists(box, gone), gone)
        }
        for k in keptCodex { XCTAssertTrue(exists(box, k), k) }
        XCTAssertEqual(scanner(box).remainingBytes(of: f), 0)
    }

    func testACleanKeepsMemoryAndEverythingElseOfClaudeCode() throws {
        let box = try Sandbox()
        try makeClaude(box)
        let f = try XCTUnwrap(item(box, .claude))
        XCTAssertEqual(cleaner(box).clean([f]).removed, 1)
        XCTAssertFalse(exists(box, ".claude/projects/-Users-me-proj/\(uuid1).jsonl"))
        XCTAssertTrue(exists(box, ".claude/projects/-Users-me-proj/\(uuid2).jsonl"), "The recent session stays")
        XCTAssertTrue(exists(box, ".claude/projects/-Users-me-proj/\(uuid1)/subagents/a.jsonl"))
        for k in keptClaude { XCTAssertTrue(exists(box, k), k) }
    }

    func testASessionThatWasUsedAgainAfterThePreviewStays() throws {
        let box = try Sandbox()
        try makeClaude(box)
        let f = try XCTUnwrap(item(box, .claude))
        try Data(repeating: 9, count: 10).write(to: box.home.appendingPathComponent(".claude/projects/-Users-me-proj/\(uuid1).jsonl"))   // the user resumed it
        XCTAssertEqual(cleaner(box).clean([f]).removed, 0)
        XCTAssertTrue(exists(box, ".claude/projects/-Users-me-proj/\(uuid1).jsonl"))
    }

    func testASessionThatBecameOldAfterThePreviewStays() throws {
        let box = try Sandbox()
        try box.file(".codex/sessions/a.jsonl", bytes: big, age: 60)
        try box.file(".codex/sessions/b.jsonl", bytes: big, age: 29)           // not old at the preview
        let f = try XCTUnwrap(item(box, .codex))
        // The preview is a day old now: b crossed the limit meanwhile. It was not in the preview, so it stays.
        let report = cleaner(box).clean([f])
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, ".codex/sessions/a.jsonl"))
        XCTAssertTrue(exists(box, ".codex/sessions/b.jsonl"))
        let later = Finding(id: "l", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .never,
                            action: .agent(.removeOldSessions(kind: .codex, olderThan: Date().addingTimeInterval(-30 * 86_400))))
        XCTAssertEqual(cleaner(box).clean([later]).removed, 0, "29 days is younger than the date in this action")
    }

    func testForgedFindingsCannotReachAnythingElse() throws {
        let box = try Sandbox()
        try makeCodex(box)
        try makeClaude(box)
        let far = Date().addingTimeInterval(86_400 * 365)                // a cutoff in the future: every file counts as old
        for kind in AgentSessions.Kind.allCases {
            let f = Finding(id: "f", ecosystem: .aiAgents, title: "x", location: "x", bytes: 1, tier: .review, rebuild: .never,
                            action: .agent(.removeOldSessions(kind: kind, olderThan: far)))
            _ = cleaner(box).clean([f])
        }
        for k in keptCodex.filter({ !$0.contains("rollout-new") }) + keptClaude { XCTAssertTrue(exists(box, k), k) }
        XCTAssertTrue(exists(box, ".codex/auth.json") && exists(box, ".claude/.credentials.json"))
    }

    // MARK: The guard

    func testTheGuardProtectsLoginsAndMemory() throws {
        let box = try Sandbox()
        let g = PathGuard(home: box.home)
        func check(_ rel: String) -> Refusal? { g.check(box.home.appendingPathComponent(rel)) }
        for rel in [".codex/auth.json", ".claude/.credentials.json", ".claude/projects/p/memory", ".claude/projects/p/memory/MEMORY.md",
                    ".claude/projects/p/memory/deep/x.md"] { XCTAssertNotNil(check(rel), rel) }
        for rel in [".codex/sessions/2026/09/01/rollout-a.jsonl", ".claude/projects/p/\(uuid1).jsonl", ".codex/archived_sessions/x.jsonl"] {
            XCTAssertNil(check(rel), rel)
        }
    }

    // MARK: Gemini

    func testGeminiIsOnlyANoteAndOnlyWhenBig() throws {
        let box = try Sandbox()
        try box.file(".gemini/tmp/abc/chats/c1.json", bytes: 1_000_000)
        XCTAssertTrue(scanner(box).scanAgentSessions().isEmpty, "Under 50 MB")
        try box.file(".gemini/tmp/abc/chats/c2.json", bytes: 60_000_000)
        let f = try XCTUnwrap(scanner(box).scanAgentSessions().first { $0.id == "agent.sessions.gemini" })
        XCTAssertFalse(f.isActionable)
        XCTAssertTrue(f.location.contains("--delete-session"))
        XCTAssertEqual(ScanResult(findings: [f], disk: DiskUsage(total: 1, free: 1)).reviewable, 0, "An information line is in no total")
        let report = cleaner(box).clean([f])
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(exists(box, ".gemini/tmp/abc/chats/c2.json"))
    }

    // MARK: The dialog

    func testTheDialogKeepsTheSessionsByDefault() throws {
        let box = try Sandbox()
        try makeCodex(box)
        let f = try XCTUnwrap(item(box, .codex))
        XCTAssertEqual(Confirmation.kind(of: f), .agentSessions)
        let c = Confirmation.forOne(f, staleDays: 30)
        XCTAssertEqual(c.title, "Delete old sessions?")
        XCTAssertEqual(c.confirmTitle, "Delete sessions")
        XCTAssertTrue(c.cancelIsDefault)
        XCTAssertTrue(c.footer?.contains("resume") == true && c.footer?.contains("can't be undone") == true)
    }
}
