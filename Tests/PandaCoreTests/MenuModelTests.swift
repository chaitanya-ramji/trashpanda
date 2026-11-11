import XCTest
@testable import PandaCore

/// Golden tests of the menu. The texts below are what the menu showed before the menu code moved into the model.
/// If one of them changes, the menu changed for the user.
final class MenuModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let xcode = AppOwner(name: "Xcode", bundleIDs: ["com.example.xcode"])
    private let xcodeRunning = RunningSnapshot(apps: [RunningApp(bundleID: "com.example.xcode", name: "Xcode")])
    private let gb: Int64 = 1_000_000_000
    private let mb: Int64 = 1_000_000
    private let disk = DiskUsage(total: 500 * 1_000_000_000, free: 120 * 1_000_000_000)

    private func item(_ id: String, _ eco: Ecosystem, _ title: String, _ bytes: Int64, _ tier: Tier,
                      place: String = "~/Projects", action: Action = .owner(.brewCleanup),
                      owner: AppOwner? = nil, last: Date? = nil, upper: Bool = false) -> Finding {
        Finding(id: id, ecosystem: eco, title: title, location: place, bytes: bytes, tier: tier, rebuild: .minutes,
                action: action, lastActivity: last, owner: owner, sizeIsUpperLimit: upper)
    }

    /// A made-up scan with generic names.
    private func fixture() -> [Finding] {
        let dir = URL(fileURLWithPath: "/tmp/none")
        return [
            item("1", .swift, "Build data", 4_200 * mb, .safe, owner: xcode),
            item("2", .swift, "Unavailable simulators", 2_100 * mb, .safe),
            item("3", .swift, "Device support · example", 3_800 * mb, .review, action: .removeDeviceSupport(dir), owner: xcode),
            item("4", .javascript, "node_modules · app-a", 1_300 * mb, .safe, action: .removeArtifact(dir),
                 last: now.addingTimeInterval(-3 * 86_400)),
            item("5", .javascript, "node_modules · app-b", 500 * mb, .safe, action: .removeArtifact(dir), last: now),
            item("6", .trash, "Trash", 5_300 * mb, .review, place: "~/.Trash", action: .emptyTrash),
            item("7", .docker, "Unused volume · data", 40 * mb, .review, place: "Docker engine: Test Engine · no container uses it",
                 action: .docker(.removeVolume(name: "data"))),
            item("8", .python, "A note", 900 * mb, .review, action: .inform),
        ]
    }

    private func input(_ findings: [Finding]?, scanning: Bool = false, cleaning: Bool = false,
                       running: RunningSnapshot = RunningSnapshot(apps: []), update: String? = nil) -> MenuInput {
        MenuInput(result: findings.map { ScanResult(findings: $0, disk: disk, date: now) }, disk: disk,
                  scanning: scanning, cleaning: cleaning, running: running, staleDays: 90, now: now,
                  updateVersion: update, updateCheckEnabled: true, loginEnabled: false)
    }

    /// One line for each row: "title | size", with "[off]" for a row that cannot be chosen. A submenu is indented.
    private func describe(_ rows: [MenuModel.Row], depth: Int = 0) -> [String] {
        let pad = String(repeating: "  ", count: depth)
        return rows.flatMap { row -> [String] in
            switch row.kind {
            case .separator: return [pad + "---"]
            case .header: return [pad + "<header>"]
            case .sectionHeader: return [pad + "# " + row.title]
            case .text, .columns:
                var line = pad + row.title + (row.size.map { " | \($0)" } ?? "")
                if !row.enabled { line += " [off]" }
                return [line] + (row.submenu.map { describe($0.rows, depth: depth + 1) } ?? [])
            }
        }
    }

    private func titles(_ model: MenuModel) -> [String] { describe(model.rows) }

    private let settingsLines = [
        "Settings",
        "  Check for updates…", "  Check for updates every day", "  Open at login", "  ---",
        "  Open the keep list", "  Open the project folders list", "  ---",
        "  Show log in Finder", "  Help", "  Report a problem", "  About Trash Panda",
        "Quit Trash Panda",
    ]
    private var tail: [String] { ["---", "Scan again"] + settingsLines }

    // MARK: States

    func testNoResultYetSaysScanning() {
        let model = MenuModel.make(input(nil, scanning: true))
        XCTAssertEqual(titles(model), ["<header>", "---", "Scanning… [off]", "---", "Scanning… [off]"] + Array(tail.dropFirst(2)))
        XCTAssertEqual(model.header.activity, .scanning)
        XCTAssertTrue(model.header.segments.isEmpty)
    }

    func testAResultWithNoItemsSaysNothingToClean() {
        let model = MenuModel.make(input([]))
        XCTAssertEqual(titles(model), ["<header>", "---", "Nothing to clean now [off]", "---"] + tail)
        XCTAssertEqual(model.header.activity, .idle)
    }

    func testScanningWithAResultButNothingSafeSaysScanning() {
        let model = MenuModel.make(input([item("a", .trash, "Trash", 1 * gb, .review, action: .emptyTrash)], scanning: true))
        XCTAssertEqual(Array(titles(model).prefix(3)), ["<header>", "---", "Scanning… [off]"])
        XCTAssertEqual(model.rows.first { $0.action == .rescan }?.title, "Scanning…")
        XCTAssertEqual(model.rows.first { $0.action == .rescan }?.enabled, false)
    }

    func testCleaningShowsProgressAndAStopRow() {
        var i = input(fixture(), cleaning: true)
        i.cleaningTitle = "Cleaning 3 of 38 · Xcode build data"
        var model = MenuModel.make(i)
        XCTAssertEqual(model.rows[2].title, "Cleaning 3 of 38 · Xcode build data")
        XCTAssertEqual(model.rows[3].title, "Stop after this item")
        XCTAssertEqual(model.rows[3].action, .stopClean)
        XCTAssertTrue(model.rows[3].enabled)
        i.stopRequested = true
        model = MenuModel.make(i)
        XCTAssertEqual(model.rows[3].title, "Stopping after this item…")
        XCTAssertFalse(model.rows[3].enabled)
        XCTAssertNil(MenuModel.make(input(fixture())).rows.first { $0.action == .stopClean }, "No stop row when no clean runs")
    }

    func testCleaningShowsOneLineAndNoGroups() {
        let model = MenuModel.make(input(fixture(), cleaning: true))
        XCTAssertEqual(titles(model), ["<header>", "---", "Cleaning… [off]", "Stop after this item", "---", "Scan again [off]"] + Array(tail.dropFirst(2)))
        XCTAssertEqual(model.header.activity, .cleaning)
        XCTAssertTrue(model.header.segments.isEmpty, "The bar is empty while cleaning")
    }

    func testOnlyReviewItemsSayNothingToCleanAutomatically() {
        let model = MenuModel.make(input([item("a", .trash, "Trash", 5_300 * mb, .review, action: .emptyTrash)]))
        XCTAssertEqual(titles(model), ["<header>", "---", "Nothing to clean now · 5.3 GB to review [off]", "---",
                                       "Trash | 5.3 GB", "  # Review first", "  Trash | 5.3 GB"] + tail)
    }

    // MARK: The full menu

    func testTheFullMenu() {
        let model = MenuModel.make(input(fixture(), update: "9.9.9"))
        XCTAssertEqual(titles(model), [
            "<header>", "---",
            "Free up 8.1 GB…", "---",
            "Xcode & Swift | 10 GB",
            "  Free up 6.3 GB…",
            "  ---",
            "  # Safe to clean · rebuild in minutes",
            "  Build data | 4.2 GB",
            "  Unavailable simulators | 2.1 GB",
            "  ---",
            "  # Review first",
            "  Device support · example | 3.8 GB",
            "  Show in Finder",
            "Trash | 5.3 GB",
            "  # Review first",
            "  Trash | 5.3 GB",
            "JavaScript & TypeScript | 1.8 GB",
            "  Free up 1.8 GB…",
            "  ---",
            "  # Safe to clean · rebuild in minutes",
            "  node_modules · app-a | 1.3 GB",
            "  Show in Finder",
            "  node_modules · app-b | 500 MB",
            "  Show in Finder",
            "Smaller groups | 40 MB",
            "  Docker | 40 MB",
            "    # Review first",
            "    Unused volume · data | 40 MB",
            "---",
            "Scan again",
            "Update available: 9.9.9…",
        ] + settingsLines)
    }

    // MARK: The main row says what it removes

    func testPrimaryTextForSafeAndReview() {
        let p = MenuText.primary(safeCount: 38, safeBytes: 4_500 * mb, reviewBytes: 41 * gb)
        XCTAssertEqual(p, MenuText.Primary(title: "Free up 4.5 GB…", subtitle: "38 safe items. Review items stay.", enabled: true))
    }

    func testPrimaryTextForSafeOnly() {
        let p = MenuText.primary(safeCount: 1, safeBytes: 300 * mb, reviewBytes: 0)
        XCTAssertEqual(p, MenuText.Primary(title: "Free up 300 MB…", subtitle: "1 safe item.", enabled: true))
    }

    func testPrimaryTextForReviewOnly() {
        let p = MenuText.primary(safeCount: 0, safeBytes: 0, reviewBytes: 41 * gb)
        XCTAssertEqual(p, MenuText.Primary(title: "Nothing to clean now · 41 GB to review", subtitle: nil, enabled: false))
    }

    func testPrimaryTextForNothing() {
        let p = MenuText.primary(safeCount: 0, safeBytes: 0, reviewBytes: 0)
        XCTAssertEqual(p, MenuText.Primary(title: "Nothing to clean now", subtitle: nil, enabled: false))
    }

    // MARK: The time of the last scan

    func testLastScanText() {
        XCTAssertEqual(MenuText.lastScan(now.addingTimeInterval(-12 * 60), now: now), "Last scan: 12 minutes ago")
        XCTAssertEqual(MenuText.lastScan(now.addingTimeInterval(-60), now: now), "Last scan: 1 minute ago")
        XCTAssertEqual(MenuText.lastScan(now.addingTimeInterval(-3 * 3600), now: now), "Last scan: 3 hours ago")
        XCTAssertEqual(MenuText.lastScan(now.addingTimeInterval(-2 * 86_400), now: now), "Last scan: 2 days ago")
        XCTAssertEqual(MenuText.lastScan(now.addingTimeInterval(-20), now: now), "Last scan: just now")
        XCTAssertEqual(MenuText.lastScan(now.addingTimeInterval(30), now: now), "Last scan: just now")
    }

    func testScanAgainRowShowsTheLastScanExceptWhileScanning() {
        func rescan(_ model: MenuModel) -> MenuModel.Row? { model.rows.first { $0.action == .rescan } }
        let idle = MenuModel.make(input(fixture()))
        XCTAssertEqual(rescan(idle)?.subtitle, "Last scan: just now")
        XCTAssertEqual(rescan(idle)?.title, "Scan again")
        XCTAssertEqual(rescan(MenuModel.make(input(fixture(), scanning: true)))?.title, "Scanning…")
        XCTAssertNil(rescan(MenuModel.make(input(fixture(), scanning: true)))?.subtitle)
        XCTAssertNil(rescan(MenuModel.make(input(nil, scanning: true)))?.subtitle)
    }

    func testTheMainRowCarriesTheSubtitle() {
        let model = MenuModel.make(input(fixture()))
        XCTAssertEqual(model.rows[2].subtitle, "4 safe items. Review items stay.")
    }

    func testTheMainRowAndItsDialog() throws {
        let model = MenuModel.make(input(fixture()))
        guard case .clean(let prompt)? = model.rows[2].action else { return XCTFail("The main row cleans") }
        XCTAssertEqual(model.rows[2].title, "Free up 8.1 GB…")
        XCTAssertEqual(prompt.title, "Free up 8.1 GB?")
        XCTAssertEqual(prompt.body, "Trash Panda will clear old build files and caches from Xcode & Swift and JavaScript & TypeScript.")
        XCTAssertEqual(prompt.findings.map(\.id).sorted(), ["1", "2", "4", "5"])
        XCTAssertNil(prompt.footer)
        XCTAssertFalse(prompt.cancelIsDefault)
    }

    func testTheGroupRowDialog() throws {
        let model = MenuModel.make(input(fixture()))
        let xcodeGroup = try XCTUnwrap(model.rows.first { $0.title == "Xcode & Swift" })
        let bulk = try XCTUnwrap(xcodeGroup.submenu?.rows.first)
        guard case .clean(let prompt)? = bulk.action else { return XCTFail("The bulk row cleans") }
        XCTAssertEqual(prompt.title, "Free up 6.3 GB of Xcode & Swift files?")
        XCTAssertEqual(prompt.body, "Trash Panda will clear old build files and caches.")
        XCTAssertEqual(prompt.findings.map(\.id), ["1", "2"])
    }

    func testTheKeysAndTheChecks() throws {
        let model = MenuModel.make(input([]))
        XCTAssertFalse(model.rows.contains { $0.isOptionAlternate }, "No row waits for the Option key")
        let settings = try XCTUnwrap(model.rows.first { $0.title == "Settings" }?.submenu?.rows)
        XCTAssertEqual(settings.first { $0.action == .toggleUpdateCheck }?.checked, true)
        XCTAssertEqual(settings.first { $0.action == .toggleLogin }?.checked, false)
    }

    func testTheMainListHasNoSettingsRowsAndSettingsHasThemInOrder() throws {
        let model = MenuModel.make(input(fixture()))
        let settingsActions: [MenuModel.Action] = [.checkForUpdates, .toggleUpdateCheck, .toggleLogin, .openKeepList, .openRootsList,
                                                   .showLog, .openHelp, .reportProblem, .showAbout]
        for action in settingsActions { XCTAssertFalse(model.rows.contains { $0.action == action }, "\(action) is in Settings only") }
        let settings = try XCTUnwrap(model.rows.first { $0.title == "Settings" }?.submenu?.rows)
        XCTAssertEqual(settings.compactMap(\.action), settingsActions)
        XCTAssertEqual(model.rows.filter { $0.action == .rescan || $0.title == "Settings" }.map(\.title), ["Scan again", "Settings"])
    }

    func testReportURLHoldsOnlyTheTwoVersions() throws {
        let url = MenuText.reportURL(appVersion: "1.2.3", osVersion: "15.1.0")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "github.com")
        XCTAssertEqual(parts.path, "/chaitanya-ramji/trashpanda/issues/new")
        XCTAssertEqual(parts.queryItems?.map(\.name), ["body"])
        XCTAssertEqual(parts.queryItems?.first?.value, "Trash Panda: 1.2.3\nmacOS: 15.1.0")
        XCTAssertEqual(MenuText.helpURL.host, "github.com")
    }

    func testSettingsFilesAreMadeWithTwoCommentLinesAndKept() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tp-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["keep", "roots"] {
            let file = Config.ensureFile(name, home: home)
            XCTAssertEqual(file.lastPathComponent, name)
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(lines.count, 2)
            XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("#") })
        }
        // A file that exists is not changed.
        let keep = home.appendingPathComponent(".config/trashpanda/keep")
        try "~/Projects/old\n".write(to: keep, atomically: true, encoding: .utf8)
        Config.ensureFile("keep", home: home)
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "~/Projects/old\n")
        // The comment lines are not read as paths.
        XCTAssertEqual(Config.load(home: home).roots, [])
    }

    // MARK: An open app

    func testAnItemOfAnOpenAppStaysInTheListAndAsksToQuit() throws {
        let model = MenuModel.make(input(fixture(), running: xcodeRunning))
        // "Free up" does not take the open app's item: 8.1 GB minus 4.2 GB.
        XCTAssertEqual(model.rows[2].title, "Free up 3.9 GB…")
        let group = try XCTUnwrap(model.rows.first { $0.title == "Xcode & Swift" })
        XCTAssertEqual(group.size, "10 GB", "The group still counts the item of the open app")
        XCTAssertEqual(describe(group.submenu?.rows ?? []), [
            "Free up 2.1 GB…", "---",
            "# Safe to clean · rebuild in minutes", "Build data | 4.2 GB", "Unavailable simulators | 2.1 GB", "---",
            "# Review first", "Device support · example | 3.8 GB", "Show in Finder",
        ])
        let blocked = try XCTUnwrap(group.submenu?.rows.first { $0.title == "Build data" })
        guard case .quitAndClean(let prompt)? = blocked.action else { return XCTFail("The click asks to quit first") }
        XCTAssertEqual(prompt.confirmTitle, "Quit Xcode and free 4.2 GB")
        XCTAssertEqual(prompt.cancelTitle, "Not now")
        XCTAssertTrue(prompt.cancelIsDefault)
        XCTAssertTrue(prompt.body.hasSuffix("\n\nXcode is open. Trash Panda will ask it to quit first. If it asks to save your work, answer it."))
        // The bar keeps the group, and the line under the title counts the item as "when apps quit".
        XCTAssertEqual(model.header.totals.waiting, 8_000 * mb)
        XCTAssertEqual(model.header.segments.first?.blockingApps, ["Xcode"])
    }

    func testOnlyOpenAppItemsLeaveNothingToCleanNow() {
        let only = [item("1", .swift, "Build data", 4_200 * mb, .safe, owner: xcode)]
        let model = MenuModel.make(input(only, running: xcodeRunning))
        XCTAssertEqual(Array(titles(model).prefix(3)), ["<header>", "---", "Nothing to clean now [off]"])
    }

    // MARK: Item rows

    func testTooltipsAndSizeText() throws {
        let model = MenuModel.make(input(fixture() + [item("9", .javascript, "node_modules · app-c", 700 * mb, .safe,
                                                           action: .removeArtifact(URL(fileURLWithPath: "/tmp/none")), upper: true)]))
        let js = try XCTUnwrap(model.rows.first { $0.title == "JavaScript & TypeScript" })
        let rows = try XCTUnwrap(js.submenu?.rows)
        XCTAssertEqual(rows.first { $0.title == "node_modules · app-a" }?.tooltip,
                       "~/Projects\nRebuilds in a few minutes\nLast worked on 3 days ago")
        XCTAssertEqual(rows.first { $0.title == "node_modules · app-b" }?.tooltip,
                       "~/Projects\nRebuilds in a few minutes\nLast worked on today")
        XCTAssertEqual(rows.first { $0.title == "node_modules · app-c" }?.size, "up to 700 MB")
        XCTAssertEqual(js.size, "1.8 GB", "An upper limit is not added to the group")
    }

    func testMoreThanTwelveItemsOpenInAMoreSubmenu() throws {
        let many = (1...40).map { item("m\($0)", .python, "Env \($0)", Int64(100 + $0) * mb, .safe) }
        let model = MenuModel.make(input(many))
        let group = try XCTUnwrap(model.rows.first { $0.title == "Python" })
        let rows = try XCTUnwrap(group.submenu?.rows)
        // Free up, a separator, a label, 12 rows, and the "more" row.
        XCTAssertEqual(rows.count, 16)
        XCTAssertEqual(rows[2].title, "Safe to clean · rebuild in minutes")
        XCTAssertEqual(rows[3].title, "Env 40", "The largest first")
        XCTAssertEqual(rows[14].title, "Env 29")
        XCTAssertEqual(rows[15].title, "28 more… · 3.2 GB")
        XCTAssertEqual(rows[15].submenu?.rows.count, 29, "The header and 28 rows")
        XCTAssertEqual(rows[15].submenu?.rows.first?.title, "Safe to clean · rebuild in minutes")
        XCTAssertEqual(rows[15].submenu?.rows.dropFirst().first?.title, "Env 28")
        XCTAssertEqual(rows[15].submenu?.rows.last?.title, "Env 1")
        XCTAssertNil(rows[15].action)
    }

    func testTheFirstListStopsAtTheFirstSmallRow() throws {
        // A group of 2 GB. Three rows are large. The others are below 50 MB and below 1 percent of the group.
        var items = (1...3).map { item("b\($0)", .python, "Big \($0)", 600 * mb + Int64($0), .safe) }
        items += (1...6).map { item("s\($0)", .python, "Small \($0)", Int64($0) * mb, .safe) }
        let group = try XCTUnwrap(MenuModel.make(input(items)).rows.first { $0.title == "Python" })
        let rows = try XCTUnwrap(group.submenu?.rows).filter { $0.kind == .columns || $0.title.contains("more…") }
        XCTAssertEqual(rows.map(\.title), ["Big 3", "Big 2", "Big 1", "6 more… · 21 MB"])
        XCTAssertEqual(rows.last?.submenu?.rows.count, 7, "The header and 6 rows")
    }

    func testASmallRowStaysWhenItIsAtLeastOnePercentOfTheGroup() throws {
        // 40 MB is below 50 MB but it is more than 1 percent of 1 GB.
        let items = [item("a", .python, "Large", 960 * mb, .safe), item("b", .python, "Medium", 40 * mb, .safe)]
        let group = try XCTUnwrap(MenuModel.make(input(items)).rows.first { $0.title == "Python" })
        XCTAssertEqual(try XCTUnwrap(group.submenu?.rows).filter { $0.kind == .columns }.map(\.title), ["Large", "Medium"])
    }

    func testTwoRowsWithTheSameTitleGetTheirFolder() throws {
        let items = [item("a", .javascript, "pnpm store", 300 * mb, .safe, place: "~/Library/pnpm"),
                     item("b", .javascript, "pnpm store", 200 * mb, .safe, place: "~/.local/share/pnpm")]
        let group = try XCTUnwrap(MenuModel.make(input(items)).rows.first { $0.title == "JavaScript & TypeScript" })
        XCTAssertEqual(try XCTUnwrap(group.submenu?.rows).filter { $0.kind == .columns }.map(\.title),
                       ["pnpm store · Library", "pnpm store · .local"])
    }

    func testDistinctTitles() {
        XCTAssertEqual(MenuText.distinct(titles: ["a", "b"], locations: ["~/x", "~/y"]), ["a", "b"])
        XCTAssertEqual(MenuText.distinct(titles: ["pnpm store", "pnpm store", "other"],
                                         locations: ["~/Library/pnpm", "~/.local/share/pnpm", "~/Library/other"]),
                       ["pnpm store · Library", "pnpm store · .local", "other"])
        // The paths share their first parts: the first part that is different is used.
        XCTAssertEqual(MenuText.distinct(titles: ["x", "x"], locations: ["~/Library/A/x", "~/Library/B/x"]), ["x · A", "x · B"])
        // The same path twice cannot be told apart. The titles stay.
        XCTAssertEqual(MenuText.distinct(titles: ["x", "x"], locations: ["~/a", "~/a"]), ["x", "x"])
        // Text after " · " is not a part of the path.
        XCTAssertEqual(MenuText.distinct(titles: ["x", "x"], locations: ["~/a · older than 30 days", "~/b · older than 30 days"]), ["x · a", "x · b"])
    }

    func testAGroupWithNothingToCleanHasNoRow() {
        let model = MenuModel.make(input([item("a", .python, "A note", 900 * mb, .review, action: .inform)]))
        XCTAssertFalse(model.rows.contains { $0.kind == .columns })
    }

    func testReviewItemsAlsoFoldAfterTwelve() throws {
        let many = (1...13).map { item("r\($0)", .python, "Old \($0)", Int64(100 + $0) * mb, .review) }
        let group = try XCTUnwrap(MenuModel.make(input(many)).rows.first { $0.title == "Python" })
        let rows = try XCTUnwrap(group.submenu?.rows)
        XCTAssertEqual(rows.count, 14)
        XCTAssertEqual(rows[0].title, "Review first · rebuild in minutes")
        XCTAssertEqual(rows[0].kind, .sectionHeader)
        XCTAssertEqual(rows[13].title, "1 more… · 101 MB")
    }

    func testSectionLabelsShowOnlyForTheirList() throws {
        func labels(_ findings: [Finding], _ name: String) throws -> [String] {
            let group = try XCTUnwrap(MenuModel.make(input(findings)).rows.first { $0.title == name })
            return try XCTUnwrap(group.submenu?.rows).filter { $0.kind == .sectionHeader }.map(\.title)
        }
        let safe = item("s", .python, "Old safe", 200 * mb, .safe), review = item("r", .python, "Old review", 200 * mb, .review)
        XCTAssertEqual(try labels([safe, review], "Python"), ["Safe to clean", "Review first"])
        XCTAssertEqual(try labels([safe], "Python"), ["Safe to clean"])
        XCTAssertEqual(try labels([review], "Python"), ["Review first"])
        XCTAssertFalse(MenuModel.Row.section("x").enabled)
    }

    func testEveryGroupGetsARowOrIsInSmallerGroups() throws {
        let findings = Ecosystem.allCases.enumerated().map { i, eco in
            item("g\(i)", eco, "Item \(i)", Int64(i + 1) * mb, .review)
        }
        let model = MenuModel.make(input(findings))
        let groups = model.rows.filter { $0.kind == .columns }
        let smaller = try XCTUnwrap(groups.last)
        XCTAssertEqual(smaller.title, "Smaller groups")
        let main = groups.dropLast()
        XCTAssertEqual(main.count, 8)
        let folded = try XCTUnwrap(smaller.submenu?.rows)
        XCTAssertEqual(main.count + folded.count, Ecosystem.allCases.count)
        XCTAssertEqual(Set((main.map(\.title) + folded.map(\.title))).count, Ecosystem.allCases.count)
        // The largest first.
        XCTAssertEqual(groups.first?.title, Ecosystem.allCases.last?.name)
        // The size of the row is the sum of the folded rows: 1 MB to 26 MB.
        XCTAssertEqual(smaller.size, "351 MB")
    }

    func testTheColumnOfSizesFollowsTheTitlesOfTheGroup() throws {
        let model = MenuModel.make(input(fixture()))
        let smaller = try XCTUnwrap(model.rows.first { $0.title == "Smaller groups" })
        let group = try XCTUnwrap(smaller.submenu?.rows.first { $0.title == "Docker" })
        XCTAssertEqual(group.submenu?.widthTitles, ["Unused volume · data"])
        XCTAssertEqual(group.submenu?.alignIcons, true)
        XCTAssertEqual(MenuModel.tab(forWidestTitle: 10), 268)
        XCTAssertEqual(MenuModel.tab(forWidestTitle: 300), 390)
        XCTAssertEqual(MenuModel.tab(forWidestTitle: 900), 520)
    }

    func testTheTitleRoomLeavesTheSizeAndAGap() {
        XCTAssertEqual(MenuModel.titleRoom(tab: 268, sizeWidth: 50), 206)
        XCTAssertEqual(MenuModel.titleRoom(tab: 40, sizeWidth: 50), 0)
        XCTAssertEqual(MenuModel.titleRoom(tab: 268, sizeWidth: 50, minGap: 20), 198)
    }

    func testTheMainTabFollowsTheWidestRowWithAFloor() throws {
        XCTAssertEqual(MenuModel.mainTab(widestRow: 100), MenuModel.minTab)
        XCTAssertEqual(MenuModel.mainTab(widestRow: 219.2), 220)
        XCTAssertEqual(MenuModel.mainTab(widestRow: 251.6), 252)
        let model = MenuModel.make(input(fixture()))
        let rows = model.sharedColumnRows
        XCTAssertTrue(rows.allSatisfy { $0.kind == .columns })
        XCTAssertTrue(rows.contains { $0.title == "Smaller groups" })
        // The groups inside "Smaller groups" share the tab, but the items of a group do not (they have their own titles).
        let smaller = try XCTUnwrap(model.rows.first { $0.title == "Smaller groups" })
        for row in smaller.submenu?.rows ?? [] where row.kind == .columns { XCTAssertTrue(rows.contains { $0.title == row.title }) }
    }

    // MARK: Bar clicks and the AI agents group

    func testAClickOnAPartOfTheBarOpensTheItemsOfThatGroup() throws {
        let inp = input(fixture())
        let model = MenuModel.make(inp)
        let trashPart = try XCTUnwrap(model.header.segments.first { $0.name == "Trash" })
        XCTAssertEqual(describe(MenuModel.popup(for: trashPart, inp).rows), ["# Review first", "Trash | 5.3 GB"])
    }

    func testAClickOnOtherOpensTheSameGroupsAsSmallerGroups() throws {
        let many = Ecosystem.allCases.prefix(10).enumerated().map { i, eco in
            item("o\(i)", eco, "Item \(i)", Int64(i + 1) * 100 * mb, .review)
        }
        let inp = input(many)
        let model = MenuModel.make(inp)
        let other = try XCTUnwrap(model.header.segments.first { $0.isOther })
        let popup = MenuModel.popup(for: other, inp)
        XCTAssertEqual(popup.rows.count, other.ecosystems.count)
        XCTAssertTrue(popup.rows.allSatisfy { $0.kind == .columns && $0.submenu != nil })
        let smaller = try XCTUnwrap(model.rows.first { $0.title == "Smaller groups" })
        XCTAssertEqual(popup, smaller.submenu)
        XCTAssertEqual(smaller.size, ByteText.string(other.bytes))
    }

    func testAManyItemAgentsGroupIsSplitByProduct() throws {
        let agents = ["Claude · cache a", "Claude · cache b", "Claude · cache c", "Claude · cache d",
                      "Codex · cache a", "Codex · cache b", "Codex · cache c"]
            .enumerated().map { i, title in item("a\(i)", .aiAgents, title, Int64(i + 1) * 100 * mb, .safe) }
        let model = MenuModel.make(input(agents))
        let group = try XCTUnwrap(model.rows.first { $0.kind == .columns })
        let rows = try XCTUnwrap(group.submenu?.rows)
        XCTAssertTrue(rows[0].title.hasPrefix("Free up "))
        guard case .clean(let prompt)? = rows[0].action else { return XCTFail("The bulk row cleans") }
        XCTAssertTrue(prompt.title.hasSuffix(" of AI agents files?"))
        XCTAssertEqual(rows[1], .separator)
        let products = rows.dropFirst(2)
        XCTAssertEqual(products.count, 2)
        XCTAssertTrue(products.allSatisfy { $0.icon != nil && $0.submenu != nil })
        XCTAssertNil(group.submenu?.widthTitles, "The product rows use the width of the menu around them")
    }
    // MARK: Show in Finder

    func testRevealURLForEachAction() {
        let url = URL(fileURLWithPath: "/tmp/none")
        func reveal(_ action: Action) -> URL? { item("x", .swift, "x", mb, .safe, action: action).revealURL }
        // One path: Finder can show it.
        XCTAssertEqual(reveal(.removeContents(url)), url)
        XCTAssertEqual(reveal(.removeArtifact(url)), url)
        XCTAssertEqual(reveal(.removeInstaller(url)), url)
        XCTAssertEqual(reveal(.removeArchive(url)), url)
        XCTAssertEqual(reveal(.removeUpdateDownloads(url)), url)
        XCTAssertEqual(reveal(.removeDeviceSupport(url)), url)
        XCTAssertEqual(reveal(.removeCacheFolderContents(name: "com.example.app"))?.lastPathComponent, "com.example.app")
        XCTAssertEqual(reveal(.removeCacheFolderContents(name: "com.example.app"))?.deletingLastPathComponent().lastPathComponent, "Caches")
        XCTAssertNil(reveal(.removeCacheFolderContents(name: "../x")))
        XCTAssertNil(reveal(.removeCacheFolderContents(name: "")))
        // A tool action, or an item with more than one path: no folder.
        XCTAssertNil(reveal(.inform))
        XCTAssertNil(reveal(.emptyTrash))
        XCTAssertNil(reveal(.owner(.brewCleanup)))
        XCTAssertNil(reveal(.docker(.removeVolume(name: "data"))))
        XCTAssertNil(reveal(.simulator(.deleteDevice(udid: "00000000-0000-0000-0000-000000000000"))))
        XCTAssertNil(reveal(.globalPackage(manager: .npm, name: "x")))
        XCTAssertNil(reveal(.removeOldLogs(.crashReports)))
        XCTAssertNil(reveal(.removeBrowserCaches(browserID: "x")))
    }

    func testAnItemWithAFolderHasAnAlternateRowAndADockerItemHasNone() throws {
        let model = MenuModel.make(input(fixture()))
        let swiftRows = try XCTUnwrap(model.rows.first { $0.title == "Xcode & Swift" }?.submenu?.rows)
        let device = try XCTUnwrap(swiftRows.firstIndex { $0.title == "Device support · example" })
        let alternate = swiftRows[device + 1]
        XCTAssertEqual(alternate.title, "Show in Finder")
        XCTAssertTrue(alternate.isOptionAlternate)
        XCTAssertEqual(alternate.action, .reveal(URL(fileURLWithPath: "/tmp/none")))
        // The dialog has the same folder for its third button.
        guard case .clean(let prompt)? = swiftRows[device].action else { return XCTFail("The row asks first") }
        XCTAssertEqual(prompt.revealURL, URL(fileURLWithPath: "/tmp/none"))
        // The Docker volume has no alternate row and no folder.
        let docker = try XCTUnwrap(model.rows.first { $0.title == "Smaller groups" }?.submenu?.rows.first?.submenu?.rows)
        XCTAssertFalse(docker.contains { $0.isOptionAlternate })
        let volume = try XCTUnwrap(docker.first { $0.title == "Unused volume · data" })
        guard case .clean(let volumePrompt)? = volume.action else { return XCTFail("The volume row asks first") }
        XCTAssertNil(volumePrompt.revealURL)
    }

    func testARowKeepsThePathAndTheLabelInTheTooltipAndHasNoRepeatedSubtitle() throws {
        let model = MenuModel.make(input(fixture()))
        let js = try XCTUnwrap(model.rows.first { $0.title == "JavaScript & TypeScript" }?.submenu?.rows)
        let row = try XCTUnwrap(js.first { $0.title == "node_modules · app-a" })
        XCTAssertNil(row.subtitle, "Both rows say the same, so the header says it once")
        XCTAssertEqual(row.tooltip?.hasPrefix("~/Projects"), true)
        XCTAssertEqual(row.tooltip?.contains("Rebuilds in a few minutes"), true)
    }

    func testARowThatDiffersFromItsSectionKeepsItsOwnSubtitle() throws {
        let a = item("a", .python, "Env a", 900 * mb, .safe)
        let b = item("b", .python, "Env b", 800 * mb, .safe)
        let c = Finding(id: "c", ecosystem: .python, title: "Env c", location: "~/p", bytes: 700 * mb, tier: .safe,
                        rebuild: .download, action: .owner(.brewCleanup))
        let rows = try XCTUnwrap(MenuModel.make(input([a, b, c])).rows.first { $0.title == "Python" }?.submenu?.rows)
        XCTAssertEqual(rows.first { $0.title == "Env c" }?.subtitle, "Downloads again when needed")
        XCTAssertNil(rows.first { $0.title == "Env a" }?.subtitle)
    }

    // MARK: Docker group submenu

    private func dockerItem(_ id: String, _ title: String, _ place: String, rebuild: Rebuild, bytes: Int64 = 900 * 1_000_000) -> Finding {
        Finding(id: id, ecosystem: .docker, title: title, location: "Docker engine: Test Engine" + place, bytes: bytes, tier: .review,
                rebuild: rebuild, action: .docker(.removeContainer(id: "abc")))
    }

    func testDockerHasNoEngineHeaderAndNoInfoRowAndTheEngineIsInTheTooltip() throws {
        let running = dockerItem("r", "Running container · web and 1 volume",
                                 " · image app:1 · Up 22 hours · volumes: 5f0999b7b512…, pgdata-prod · will be stopped first", rebuild: .never)
        let rows = try XCTUnwrap(MenuModel.make(input([running])).rows.first { $0.title == "Docker" }?.submenu?.rows)
        XCTAssertEqual(rows.filter { $0.kind == .sectionHeader }.map(\.title), ["Review first"], "One header, no engine header")
        XCTAssertFalse(rows.contains { $0.kind == .text && !$0.enabled }, "No long info row")
        let row = try XCTUnwrap(rows.first { $0.title == "Running container · web and 1 volume" })
        XCTAssertEqual(row.subtitle, "Stopped first · Cannot be recovered")
        let tip = row.tooltip ?? ""
        XCTAssertTrue(tip.hasPrefix("Test Engine · image app:1 · Up 22 hours"), tip)
        XCTAssertTrue(tip.contains("volumes: pgdata-prod"), "A name that a person chose shows in the tooltip")
        XCTAssertFalse(tip.contains("5f0999"), "The id of an anonymous volume never shows")
        XCTAssertFalse((row.subtitle ?? "").contains("5f0999"))
        XCTAssertFalse(tip.contains("(local)"))
    }

    func testAContainerKeepsItsOwnRecreateLabelNextToImages() throws {
        let images = (1...3).map { dockerItem("i\($0)", "Image · app\($0)", " · on this Mac for 90 days", rebuild: .download, bytes: Int64(900 + $0) * 1_000_000) }
        let container = dockerItem("c", "Stopped container · db", " · image db:1 · Exited (0) 3 days ago", rebuild: .recreate)
        let rows = try XCTUnwrap(MenuModel.make(input(images + [container])).rows.first { $0.title == "Docker" }?.submenu?.rows)
        XCTAssertEqual(rows.first { $0.kind == .sectionHeader }?.title, "Review first · re-download when needed")
        let row = try XCTUnwrap(rows.first { $0.title == "Stopped container · db" })
        XCTAssertEqual(row.subtitle, "Exited (0) 3 days ago · You would need to recreate it")
        XCTAssertEqual(rows.first { $0.title == "Image · app1" }?.subtitle, "On this Mac for 90 days")
    }

    func testSectionHeadersAreShort() {
        for r in [Rebuild.seconds, .minutes, .download, .recreate] {
            let notes = MenuText.rebuildNotes([r, r])
            XCTAssertLessThan("Review first · \(notes.sectionSuffix ?? "")".count, 40)
        }
    }

    func testOverflowSubmenuStartsWithTheSectionHeader() throws {
        let many = (1...40).map { item("m\($0)", .python, "Env \($0)", Int64(100 + $0) * mb, .safe) }
        let group = try XCTUnwrap(MenuModel.make(input(many)).rows.first { $0.title == "Python" })
        let more = try XCTUnwrap(group.submenu?.rows.first { $0.title.contains("more…") }?.submenu?.rows)
        XCTAssertEqual(more.first?.title, "Safe to clean · rebuild in minutes")
    }

    func testTwoAnonymousVolumesGetTheStartOfTheirId() throws {
        let a = dockerItem("a", "Unused anonymous volume · 5f0999b7b512…", " · no container uses it", rebuild: .never, bytes: 900 * 1_000_000)
        let b = dockerItem("b", "Unused anonymous volume · aa11bb22cc33…", " · no container uses it", rebuild: .never, bytes: 800 * 1_000_000)
        let rows = try XCTUnwrap(MenuModel.make(input([a, b])).rows.first { $0.title == "Docker" }?.submenu?.rows)
        let titles = rows.filter { $0.kind == .columns }.map(\.title)
        XCTAssertEqual(titles, ["Unused anonymous volume · 5f0999b7", "Unused anonymous volume · aa11bb22"])
        let one = try XCTUnwrap(MenuModel.make(input([a])).rows.first { $0.title == "Docker" }?.submenu?.rows)
        XCTAssertEqual(one.first { $0.kind == .columns }?.title, "Unused anonymous volume", "A single one shows no id")
    }

    func testCacheFolderTitlesDropTheRepeatedSuffix() throws {
        func cache(_ title: String, _ folder: String) -> Finding {
            Finding(id: "c:" + folder, ecosystem: .cacheExplorer, title: title, location: "~/Library/Caches/" + folder, bytes: 900 * mb,
                    tier: .review, rebuild: .download, action: .removeCacheFolderContents(name: folder))
        }
        let list = [cache("com.apple.helpd · system cache", "com.apple.helpd"), cache("bun · cache folder", "bun"),
                    cache("CloudKit · system cache", "CloudKit")]
        let rows = try XCTUnwrap(MenuModel.make(input(list)).rows.first { $0.kind == .columns }?.submenu?.rows)
        XCTAssertEqual(rows.filter { $0.kind == .columns }.map(\.title), ["helpd (macOS)", "bun", "CloudKit (system)"])
    }

    func testGoodToKnowSectionShowsWhileNotCleaningAndNotDuringACleanEvenWithGroups() {
        let info = [InfoRow(title: "Fact", detail: "d")]
        let result = ScanResult(findings: fixture(), disk: disk, date: now, infoRows: info)
        func make(cleaning: Bool) -> MenuModel {
            MenuModel.make(MenuInput(result: result, disk: disk, scanning: false, cleaning: cleaning,
                                     running: RunningSnapshot(apps: []), staleDays: 90, now: now))
        }
        XCTAssertTrue(describe(make(cleaning: false).rows).contains("# Good to know · can't be cleaned here"))
        XCTAssertFalse(describe(make(cleaning: true).rows).contains { $0.hasPrefix("# Good to know") })
        XCTAssertTrue(describe(make(cleaning: true).rows).contains("Cleaning… [off]"))
    }

    // MARK: Friendly titles and width

    func testRowTitleIsFriendlyAndTheTooltipKeepsTheFullName() throws {
        let f = Finding(id: "cache.explorer:x", ecosystem: .cacheExplorer, title: "com.example.tool.helperd · system cache",
                        location: "~/Library/Caches/com.example.tool.helperd", bytes: 900 * mb, tier: .review, rebuild: .download,
                        action: .removeCacheFolderContents(name: "com.example.tool.helperd"))
        let rows = try XCTUnwrap(MenuModel.make(input([f])).rows.first { $0.kind == .columns }?.submenu?.rows)
        let row = try XCTUnwrap(rows.first { $0.kind == .columns })
        XCTAssertEqual(row.title, "helperd (system)")
        XCTAssertEqual(row.tooltip?.hasPrefix("com.example.tool.helperd · system cache\n"), true)
    }

    func testALongTitleIsCappedAndTheTooltipHasItAll() throws {
        let long = String(repeating: "abcdefghij", count: 8)
        let f = item("l", .python, long, 900 * mb, .safe)
        let rows = try XCTUnwrap(MenuModel.make(input([f])).rows.first { $0.title == "Python" }?.submenu?.rows)
        let row = try XCTUnwrap(rows.first { $0.kind == .columns })
        XCTAssertLessThanOrEqual(row.title.count, MenuText.maxTitle)
        XCTAssertTrue(row.tooltip?.hasPrefix(long) == true)
    }
}
