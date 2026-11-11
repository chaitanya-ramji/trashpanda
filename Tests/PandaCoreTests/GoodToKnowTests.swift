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
        let row = StorageFacts.dockerDisk(onDisk: 34 * gb, inside: 12 * gb)
        XCTAssertEqual(row?.title, "Docker disk file: 34 GB, 12 GB in use")
        XCTAssertEqual(row?.detail, "Stays large after a clean")
        XCTAssertEqual(row?.tooltip, "Cannot be cleaned here. Docker does not shrink this file when you delete images or containers inside it.")
        XCTAssertLessThan(row?.title.count ?? 99, 40)
        XCTAssertNotNil(StorageFacts.dockerDisk(onDisk: 17 * gb, inside: 12 * gb), "Exactly 5 GB is enough")
        XCTAssertNil(StorageFacts.dockerDisk(onDisk: 17 * gb - 1, inside: 12 * gb), "Less than 5 GB larger is hidden")
        XCTAssertNil(StorageFacts.dockerDisk(onDisk: 10 * gb, inside: 12 * gb))
    }

    func testRowsFromFindingsUseOnlyTheDiskFileLine() {
        let line = Finding(id: "docker.vmdisk", ecosystem: .docker, title: "Docker Desktop disk image", location: "x", bytes: 34 * gb,
                           tier: .review, rebuild: .never, action: .inform, note: "n", insideBytes: 12 * gb)
        XCTAssertEqual(StorageFacts.rows(from: [trash(gb), line]).map(\.title), ["Docker disk file: 34 GB, 12 GB in use"])
        let noInside = Finding(id: "docker.vmdisk", ecosystem: .docker, title: "d", location: "x", bytes: 34 * gb,
                               tier: .review, rebuild: .never, action: .inform)
        XCTAssertTrue(StorageFacts.rows(from: [noInside]).isEmpty, "We never guess the data inside")
    }

    // MARK: Space that macOS frees, and snapshots

    func testPurgeableRowIsHiddenAtOneGigabyteOrLess() {
        XCTAssertNil(StorageFacts.purgeable(0))
        XCTAssertNil(StorageFacts.purgeable(gb))
        XCTAssertNotNil(StorageFacts.purgeable(gb + 1))
    }

    func testPurgeableRowSaysItIsAnEstimateAndTheTooltipSaysWhatItMayInclude() {
        let row = StorageFacts.purgeable(18 * gb)
        XCTAssertEqual(row?.title, "18 GB of free space is purgeable")
        XCTAssertEqual(row?.detail, "An estimate")
        XCTAssertTrue(row?.tooltip?.contains("taken when the scan ran") == true)
        XCTAssertTrue(row?.tooltip?.contains("snapshots and system files") == true)
    }

    func testDiskUsageKeepsPurgeableAndNeverNegative() {
        XCTAssertEqual(DiskUsage(total: 10, free: 5, purgeable: 3).purgeable, 3)
        XCTAssertEqual(DiskUsage(total: 10, free: 5, purgeable: -3).purgeable, 0)
        XCTAssertEqual(DiskUsage(total: 10, free: 5).purgeable, 0)
    }

    private func snapshot(_ n: Int) -> Finding {
        Finding(id: "snapshots.local", ecosystem: .snapshots, title: n == 1 ? "Time Machine · 1 local snapshot" : "Time Machine · \(n) local snapshots",
                location: "Read with tmutil, read only", bytes: 0, tier: .review, rebuild: .never, action: .inform)
    }

    func testSnapshotRowTextForOneAndMany() {
        XCTAssertEqual(StorageFacts.rows(from: [snapshot(1)]).map(\.title), ["Time Machine · 1 local snapshot"])
        XCTAssertEqual(StorageFacts.rows(from: [snapshot(3)]).map(\.title), ["Time Machine · 3 local snapshots"])
        XCTAssertEqual(StorageFacts.rows(from: [snapshot(3)]).first?.detail,
                       "macOS removes them when it needs space")
    }

    func testAllThreeRowsInOrderAndNoMoreThanThree() {
        let docker = Finding(id: "docker.vmdisk", ecosystem: .docker, title: "d", location: "x", bytes: 34 * gb, tier: .review,
                             rebuild: .never, action: .inform, insideBytes: 12 * gb)
        let rows = StorageFacts.rows(from: [snapshot(2), docker], disk: DiskUsage(total: 500 * gb, free: 100 * gb, purgeable: 18 * gb))
        XCTAssertEqual(rows.map(\.title), ["Docker disk file: 34 GB, 12 GB in use", "Time Machine · 2 local snapshots",
                                           "18 GB of free space is purgeable"])
        XCTAssertTrue(rows.allSatisfy { $0.detail.count <= 40 }, "Short second lines keep the menu narrow")
        XCTAssertTrue(rows.allSatisfy { $0.tooltip?.contains("Cannot be cleaned here") == true })
        XCTAssertLessThanOrEqual(rows.count, StorageFacts.maxRows)
    }

    // MARK: The menu

    func testNoInfoRowsMeansNoSection() {
        XCTAssertFalse(lines(model([trash(2 * gb)], info: [])).contains("# Good to know · can't be cleaned here"))
    }

    func testSectionSitsAfterTheGroupsAndBeforeScanAgain() {
        let info = InfoRow(title: "Docker disk file: 34 GB, 12 GB in use", detail: "Cannot be cleaned here.", tooltip: "tip")
        let m = model([trash(2 * gb)], info: [info])
        let l = lines(m)
        let i = try! XCTUnwrap(l.firstIndex(of: "# Good to know · can't be cleaned here"))
        XCTAssertEqual(Array(l[(i - 2)...(i + 3)]), ["Trash", "---", "# Good to know · can't be cleaned here",
                                                    "Docker disk file: 34 GB, 12 GB in use [off]", "---", "Scan again"])
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

    func testAnInformationRowAddsToNoTotalNoBarAndNoCleanSet() {
        let info = [InfoRow(title: "Docker disk file: 34 GB, 12 GB in use", detail: "d")]
        let plain = model([trash(2 * gb)], info: [])
        let with = model([trash(2 * gb)], info: info)
        XCTAssertEqual(with.header, plain.header)
        // Only the section rows are new. Every other row is the same, and no row of the section can clean anything.
        let extra = with.rows.filter { !plain.rows.contains($0) && $0.kind != .separator }
        XCTAssertEqual(extra.map(\.title), ["Good to know · can't be cleaned here", "Docker disk file: 34 GB, 12 GB in use"])
        XCTAssertTrue(extra.allSatisfy { $0.action == nil })
    }

    func testAGroupWithOneItemAndInfoGivesOneItemRowAndOneInfoRow() {
        let m = model([trash(2 * gb)], info: [InfoRow(title: "Fact", detail: "d")])
        XCTAssertEqual(m.rows.filter { $0.kind == .columns }.map(\.title), ["Trash"])
        XCTAssertEqual(m.rows.filter { $0.title == "Fact" }.count, 1)
    }
}
