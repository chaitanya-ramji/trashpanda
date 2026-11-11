import XCTest
@testable import PandaCore

/// The "Good to know" section: facts that cannot be cleaned here. They are not items and are in no total.
final class GoodToKnowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let gb: Int64 = 1_000_000_000
    private let disk = DiskUsage(total: 500 * 1_000_000_000, free: 120 * 1_000_000_000)

    private func trash(_ bytes: Int64) -> Finding {
        Finding(id: "t", ecosystem: .trash, title: "Trash", location: "~/.Trash", bytes: bytes, tier: .review,
                rebuild: .never, action: .emptyTrash)
    }

    private func model(_ findings: [Finding], info: [InfoRow], scanning: Bool = false, cleaning: Bool = false) -> MenuModel {
        let result = ScanResult(findings: findings, disk: disk, date: now, infoRows: info)
        return MenuModel.make(MenuInput(result: result, disk: disk, scanning: scanning, cleaning: cleaning,
                                        running: RunningSnapshot(apps: []), staleDays: 90, now: now))
    }

    private func lines(_ m: MenuModel) -> [String] {
        m.rows.map { $0.kind == .separator ? "---" : ($0.kind == .sectionHeader ? "# " + $0.title : $0.title + ($0.enabled ? "" : " [off]")) }
    }

    // MARK: The Docker row text

    func testDockerRowTextAndGap() {
        let row = StorageFacts.dockerDisk(onDisk: 34 * gb, inside: 12 * gb, note: "A note.")
        XCTAssertEqual(row?.title, "Docker disk file: 34 GB on disk, 12 GB in use")
        XCTAssertEqual(row?.detail, "Cannot be cleaned here. The file stays large after a clean.")
        XCTAssertEqual(row?.tooltip, "A note.")
        XCTAssertNotNil(StorageFacts.dockerDisk(onDisk: 17 * gb, inside: 12 * gb, note: nil), "Exactly 5 GB is enough")
        XCTAssertNil(StorageFacts.dockerDisk(onDisk: 17 * gb - 1, inside: 12 * gb, note: nil), "Less than 5 GB larger is hidden")
        XCTAssertNil(StorageFacts.dockerDisk(onDisk: 10 * gb, inside: 12 * gb, note: nil))
    }

    func testRowsFromFindingsUseOnlyTheDiskFileLine() {
        let line = Finding(id: "docker.vmdisk", ecosystem: .docker, title: "Docker Desktop disk image", location: "x", bytes: 34 * gb,
                           tier: .review, rebuild: .never, action: .inform, note: "n", insideBytes: 12 * gb)
        XCTAssertEqual(StorageFacts.rows(from: [trash(gb), line]).map(\.title), ["Docker disk file: 34 GB on disk, 12 GB in use"])
        let noInside = Finding(id: "docker.vmdisk", ecosystem: .docker, title: "d", location: "x", bytes: 34 * gb,
                               tier: .review, rebuild: .never, action: .inform)
        XCTAssertTrue(StorageFacts.rows(from: [noInside]).isEmpty, "We never guess the data inside")
    }

    // MARK: The menu

    func testNoInfoRowsMeansNoSection() {
        XCTAssertFalse(lines(model([trash(2 * gb)], info: [])).contains("# Good to know"))
    }

    func testSectionSitsAfterTheGroupsAndBeforeScanAgain() {
        let info = InfoRow(title: "Docker disk file: 34 GB on disk, 12 GB in use", detail: "Cannot be cleaned here.", tooltip: "tip")
        let m = model([trash(2 * gb)], info: [info])
        let l = lines(m)
        let i = try! XCTUnwrap(l.firstIndex(of: "# Good to know"))
        XCTAssertEqual(Array(l[(i - 2)...(i + 3)]), ["Trash", "---", "# Good to know",
                                                    "Docker disk file: 34 GB on disk, 12 GB in use [off]", "---", "Scan again"])
        let row = m.rows[i + 1]
        XCTAssertFalse(row.enabled)
        XCTAssertNil(row.action)
        XCTAssertNil(row.submenu)
        XCTAssertEqual(row.subtitle, "Cannot be cleaned here.")
        XCTAssertEqual(row.tooltip, "tip")
    }

    func testAtMostThreeRows() {
        let info = (1...5).map { InfoRow(title: "Fact \($0)", detail: "Cannot be cleaned here.") }
        let l = lines(model([trash(2 * gb)], info: info))
        XCTAssertEqual(l.filter { $0.hasPrefix("Fact") }.count, 3)
    }

    func testNoSectionWhileCleaning() {
        let info = InfoRow(title: "Fact", detail: "d")
        XCTAssertFalse(lines(model([trash(2 * gb)], info: [info], cleaning: true)).contains("# Good to know"))
    }

    func testAnInformationRowAddsToNoTotalNoBarAndNoCleanSet() {
        let info = [InfoRow(title: "Docker disk file: 34 GB on disk, 12 GB in use", detail: "d")]
        let plain = model([trash(2 * gb)], info: [])
        let with = model([trash(2 * gb)], info: info)
        XCTAssertEqual(with.header, plain.header)
        // Only the section rows are new. Every other row is the same, and no row of the section can clean anything.
        let extra = with.rows.filter { !plain.rows.contains($0) && $0.kind != .separator }
        XCTAssertEqual(extra.map(\.title), ["Good to know", "Docker disk file: 34 GB on disk, 12 GB in use"])
        XCTAssertTrue(extra.allSatisfy { $0.action == nil })
    }

    func testAGroupWithOneItemAndInfoGivesOneItemRowAndOneInfoRow() {
        let m = model([trash(2 * gb)], info: [InfoRow(title: "Fact", detail: "d")])
        XCTAssertEqual(m.rows.filter { $0.kind == .columns }.map(\.title), ["Trash"])
        XCTAssertEqual(m.rows.filter { $0.title == "Fact" }.count, 1)
    }
}
