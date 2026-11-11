import XCTest
@testable import PandaCore

/// Checks for the clean-up of dead code and code that was written two times (Q-07, Q-12).
final class CodeCleanupTests: XCTestCase {
    func testNoTwoEntriesOfTheCatalogHaveTheSameTitle() {
        let titles = Catalog.caches.map(\.title)
        let repeated = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertTrue(repeated.isEmpty, "Titles used more than once: \(repeated)")
    }

    func testNoTwoEntriesOfTheCatalogHaveTheSameId() {
        let ids = Catalog.caches.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTheSizeTextHasNoSecondCopy() {
        XCTAssertEqual(ByteText.string(4_100_000_000), "4.1 GB")
        XCTAssertEqual(ByteText.string(12_000_000_000), "12 GB")
    }

    func testSizesOfHomebrewAndDockerAreReadByOneFunction() {
        XCTAssertEqual(ByteText.parse("1.2GB (100%)"), 1_200_000_000)
        XCTAssertEqual(ByteText.parse("3.5MB"), 3_500_000)
        XCTAssertEqual(ByteText.parse("42"), 42)
        XCTAssertNil(ByteText.parse("many"))
    }

    // MARK: Volumes that only one container uses

    private func volume(_ name: String, links: Int = 1, driver: String = "local") -> DockerInventory.Volume {
        DockerInventory.Volume(name: name, bytes: 10, links: links, driver: driver)
    }

    func testOwnedOnlyKeepsTheVolumesThatOnlyThisContainerUses() {
        let volumes = [volume("data"), volume("shared"), volume("other"), volume("remote", driver: "nfs"), volume("busy", links: 2)]
        let mounts = ["c1": ["data", "shared", "remote", "busy"], "c2": ["shared", "other"]]
        let own = DockerVolumes.ownedOnly(by: "c1", mounts: mounts, in: volumes)
        XCTAssertEqual(own.map(\.name), ["data"], "A shared, a remote and a busy volume are not owned")
        XCTAssertEqual(DockerVolumes.ownedOnly(by: "c2", mounts: mounts, in: volumes).map(\.name), ["other"])
        XCTAssertTrue(DockerVolumes.ownedOnly(by: "none", mounts: mounts, in: volumes).isEmpty)
    }

    func testOwnedOnlyRefusesAVolumeNameThatIsNotSafe() {
        let volumes = [volume("-rf"), volume("fine")]
        let own = DockerVolumes.ownedOnly(by: "c1", mounts: ["c1": ["-rf", "fine"]], in: volumes)
        XCTAssertEqual(own.map(\.name), ["fine"])
    }

    // MARK: Confirmation

    func testTheOldLogsTitleIsFixed() {
        let f = Finding(id: "logs", ecosystem: .logs, title: "Xcode Logs", location: "~/Library/Logs", bytes: 5, tier: .safe,
                        rebuild: .never, action: .removeOldLogs(.logs))
        XCTAssertEqual(Confirmation.forOne(f, staleDays: 30).title, "Delete these old log files?")
    }
}
