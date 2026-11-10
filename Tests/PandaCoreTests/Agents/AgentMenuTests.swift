import XCTest
@testable import PandaCore

/// #69: the AI agents group is split by product. The rules are in the core; the app only draws them.
final class AgentMenuTests: XCTestCase {
    private func item(_ title: String, _ bytes: Int64, tier: Tier = .safe, info: Bool = false) -> Finding {
        Finding(id: title, ecosystem: .aiAgents, title: title, location: "x", bytes: bytes, tier: tier, rebuild: .download,
                action: info ? .inform : .agent(.removeFixedFolders(appID: "zed")))
    }

    func testProductsAreOrderedByWhatTheyCanFree() {
        let groups = AgentMenu.groups([item("Codex · a", 100), item("Claude · b", 500), item("Claude · c", 300), item("Zed · d", 100), item("Ollama · e", 900)])
        XCTAssertEqual(groups.map(\.product), ["Ollama", "Claude", "Codex", "Zed"], "Claude has 800 in all, so it is second; ties go by name")
        XCTAssertEqual(groups.map(\.bytes), [900, 800, 100, 100])
    }

    func testItemsInAProductAreOrderedBySize() {
        let g = AgentMenu.groups([item("Claude · small", 10), item("Claude · big", 900), item("Claude · mid", 50)])[0]
        XCTAssertEqual(g.items.map(\.title), ["Claude · big", "Claude · mid", "Claude · small"])
    }

    func testNothingIsLostOrCountedTwice() {
        let items = (0..<30).map { item("\(AgentProduct.all[$0 % 10].name) · item \($0)", Int64($0 + 1) * 10) }
        let groups = AgentMenu.groups(items)
        XCTAssertEqual(groups.count, 10)
        XCTAssertEqual(groups.flatMap(\.items).count, 30)
        XCTAssertEqual(groups.reduce(Int64(0)) { $0 + $1.bytes }, items.reduce(Int64(0)) { $0 + $1.bytes })
        XCTAssertEqual(Set(groups.flatMap(\.items).map(\.id)).count, 30)
    }

    func testAnInformationLineIsNotInTheSizeOfAProduct() {
        let g = AgentMenu.groups([item("Gemini · saved chats", 700, tier: .review, info: true), item("Gemini · other", 100)])[0]
        XCTAssertEqual(g.bytes, 100)
        XCTAssertEqual(g.items.count, 2, "The line is still shown")
    }

    func testAnUnknownProductGoesToOther() {
        let groups = AgentMenu.groups([item("Mystery · x", 10), item("No product here", 20), item("Claude · y", 5)])
        let other = groups.first { $0.product == AgentMenu.otherProduct }
        XCTAssertEqual(other?.items.count, 1, "A title with no product goes to Other")
        let mystery = groups.first { $0.product == "Mystery" }
        XCTAssertNil(mystery?.info, "An unknown product has no icon plan")
        XCTAssertNotNil(groups.first { $0.product == "Claude" }?.info)
    }

    func testEveryKnownProductHasAnIconPlan() {
        for p in AgentProduct.all {
            let g = AgentMenu.groups([item("\(p.name) · x", 1)])[0]
            XCTAssertEqual(g.info?.name, p.name)
            XCTAssertFalse(g.info?.symbol.isEmpty ?? true, p.name)
        }
    }

    func testAShortOrSingleProductListStaysFlat() {
        XCTAssertFalse(AgentMenu.shouldNest([]))
        XCTAssertFalse(AgentMenu.shouldNest((0..<6).map { item("Claude · \($0)", 1) }), "6 rows are short")
        XCTAssertFalse(AgentMenu.shouldNest((0..<10).map { item("Claude · \($0)", 1) }), "One product only")
        XCTAssertTrue(AgentMenu.shouldNest((0..<7).map { item(($0 % 2 == 0 ? "Claude" : "Codex") + " · \($0)", 1) }))
        XCTAssertTrue(AgentMenu.shouldNest((0..<6).map { item("Claude · \($0)", 1) } + [item("No product", 1)]), "Other counts as a product")
    }

    func testTheOrderDoesNotDependOnTheInputOrder() {
        let items = [item("Codex · a", 100), item("Claude · b", 100), item("Zed · c", 100), item("Claude · d", 1)]
        XCTAssertEqual(AgentMenu.groups(items).map(\.product), AgentMenu.groups(items.reversed()).map(\.product))
    }

    func testTheScannerTitlesAllHaveAProduct() throws {
        // A rich fake home: one item of every product that has a folder-based scanner. Every title must belong to a known product.
        let box = try Sandbox()
        try box.file(".cache/codex-runtimes/codex-primary-runtime/x", bytes: 2_000_000)
        try box.file("Library/Application Support/Claude/Cache/f", bytes: 2_000_000)
        try box.file("Library/Application Support/Claude/vm_bundles/warm/f", bytes: 2_000_000)
        try box.file("Library/Application Support/Code/CachedData/f", bytes: 2_000_000)
        try box.file("Library/Application Support/Cursor/CachedData/f", bytes: 2_000_000)
        try box.file("Library/Application Support/Antigravity/CachedData/f", bytes: 2_000_000)
        try box.file("Library/Application Support/Zed/languages/f", bytes: 2_000_000)
        try box.file(".cache/huggingface/hub/models--a--b/blobs/x", bytes: 2_000_000)
        try box.file(".lmstudio/models/p/m/x.gguf", bytes: 2_000_000)
        try box.file("Library/Application Support/Jan/data/models/m/x.gguf", bytes: 2_000_000)
        try box.file(".cache/gpt4all/m.gguf", bytes: 2_000_000)
        let found = DiskScanner(home: box.home, config: Config(), useOwnerTools: false).scanAgents()
        XCTAssertGreaterThan(found.count, 9)
        for f in found { XCTAssertNotNil(AgentProduct.info(forTitle: f.title), f.title) }
        XCTAssertTrue(AgentMenu.shouldNest(found))
        XCTAssertGreaterThan(AgentMenu.groups(found).count, 7)
    }
}
