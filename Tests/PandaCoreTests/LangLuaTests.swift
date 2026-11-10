import XCTest
@testable import PandaCore

/// Lua: its caches and build folders (#29). Each row has a test, and the folders next to it must stay.
final class LangLuaTests: XCTestCase {
    private func projects(_ box: Sandbox) -> [Finding] {
        ProjectScanner(home: box.home, roots: [box.home.appendingPathComponent("Developer")],
                       guardian: PathGuard(home: box.home), activeDirectories: []).scan().filter { $0.ecosystem == .lua }
    }
    private func scanner(_ box: Sandbox) -> DiskScanner { DiskScanner(home: box.home, config: Config(), useOwnerTools: false) }
    private func cleaner(_ box: Sandbox) -> Cleaner {
        let s = scanner(box)
        return Cleaner(guardian: s.guardian, remaining: s.remainingBytes(of:), runningApps: FakeRunning(apps: []).provider)
    }
    private func exists(_ box: Sandbox, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: box.home.appendingPathComponent(rel).path) }

    func testTheGroupHasNames() {
        XCTAssertEqual(Ecosystem.lua.shortName, "Lua")
        XCTAssertEqual(Ecosystem.lua.name, "Lua")
    }

    func testFinds_1_lua_modules() throws {
        let box = try Sandbox()
        try box.file("Developer/app/app.rockspec", bytes: 10)
        try box.file("Developer/app/src/main.txt", bytes: 10)
        try box.file("Developer/app/lua_modules/x/y", bytes: 20_000)
        box.ageProject("Developer/app", days: 90)
        let found = projects(box)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tier, .review)
        XCTAssertEqual(found.first.map { URL(fileURLWithPath: $0.location).lastPathComponent }, "lua_modules")
        let report = cleaner(box).clean(found)
        XCTAssertEqual(report.removed, 1)
        XCTAssertFalse(exists(box, "Developer/app/lua_modules"))
        XCTAssertTrue(exists(box, "Developer/app/app.rockspec"), "The marker file stays")
        XCTAssertTrue(exists(box, "Developer/app/src/main.txt"), "Source files stay")
    }

    func testMarkerIsRequired_1_lua_modules() throws {
        let box = try Sandbox()
        try box.file("Developer/other/lua_modules/x/y", bytes: 20_000)
        XCTAssertTrue(projects(box).isEmpty, "A folder with this name but no marker file is not ours")
    }

    /// These folders hold installed tools, settings, or your own work. A clean of every item must leave them.
    func testNeverTouchedFolders() throws {
        let box = try Sandbox()
        for rel in [".luarocks/config-5.4.lua"] { try box.file(rel, bytes: 5_000) }
        let s = scanner(box)
        let all = s.scanCaches().filter { $0.ecosystem == .lua } + projects(box)
        _ = cleaner(box).clean(all)
        for rel in [".luarocks/config-5.4.lua"] { XCTAssertTrue(exists(box, rel), rel) }
    }
}
