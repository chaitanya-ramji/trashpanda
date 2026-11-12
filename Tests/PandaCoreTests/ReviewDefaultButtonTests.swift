import XCTest
@testable import PandaCore

/// Issue #232: Return must never delete a review item.
final class ReviewDefaultButtonTests: XCTestCase {
    private func finding(_ action: Action, tier: Tier) -> Finding {
        Finding(id: "x", ecosystem: .swift, title: "Thing", location: "Where", bytes: 3_000_000_000, tier: tier,
                rebuild: .download, action: action)
    }

    private let device = "11111111-1111-1111-1111-111111111111"

    func testAReviewArtifactKeepsByDefault() {
        let f = finding(.removeArtifact(URL(fileURLWithPath: "/x/item")), tier: .review)
        XCTAssertEqual(Confirmation.kind(of: f), .ordinary)
        XCTAssertTrue(Confirmation.forOne(f, staleDays: 30).cancelIsDefault, "Return must not delete")
    }

    func testASafeArtifactStillDeletesOnReturn() {
        let f = finding(.removeArtifact(URL(fileURLWithPath: "/x/item")), tier: .safe)
        XCTAssertFalse(Confirmation.forOne(f, staleDays: 30).cancelIsDefault)
    }

    func testTheDecisionFollowsTheTier() {
        XCTAssertTrue(Confirmation.defaultKeeps(tier: .review))
        XCTAssertFalse(Confirmation.defaultKeeps(tier: .safe))
    }

    /// Every kind of dialog, with a review item: the default button keeps it.
    func testEveryReviewKindKeepsByDefault() {
        let url = URL(fileURLWithPath: "/x/item")
        let repo = URL(fileURLWithPath: "/x/repo")
        let actions: [Action] = [
            .removeArtifact(url), .owner(.brewCleanup),
            .docker(.removeContainer(id: "0123456789ab")), .docker(.removeVolume(name: "data")),
            .simulator(.deleteDevice(udid: device)), .removeArchive(url),
            .removeServiceWorkerStorage(browserID: "b"), .emptyTrash, .removeInstaller(url), .removeOldLogs(.logs),
            .brew(.uninstall(name: "pkg")), .agent(.removeOldClaudeDesktopRuntimes(names: [])), .agent(.removeClaudeVMBundle),
            .agent(.removeOllamaModel(name: "m")),
            .agent(.removeOldSessions(kind: .codex, olderThan: Date(), minimumAgeDays: 30)),
            .globalPackage(manager: .npm, name: "pkg"), .removeRuntime(storeID: "s", tool: "t", name: "n"),
            .simulator(.deleteRuntime(id: device)), .removeDeviceSupport(url),
            .removeCacheFolderContents(name: "Some Cache"),
            .docker(.removeStoppedContainerWithVolumes(id: "0123456789ab", volumes: ["v"])),
            .docker(.stopAndRemoveContainerWithVolumes(id: "0123456789ab", volumes: ["v"])),
            .worktree(.remove(repo: repo, path: url)), .worktree(.prune(repo: repo, paths: ["/x/gone"])),
        ]
        for action in actions {
            let f = finding(action, tier: .review)
            XCTAssertTrue(Confirmation.forOne(f, staleDays: 30).cancelIsDefault, "\(Confirmation.kind(of: f))")
        }
    }

    /// The "Clean up" dialog (a tool decides what it removes) is a review item too: Return keeps it.
    func testAReviewCleanUpToolDialogKeepsByDefault() {
        for command in [OwnerCommand.brewCleanup, .simctlDeleteUnavailable] {
            let f = Finding(id: "x", ecosystem: .swift, title: "Thing", location: "Where", bytes: 3_000_000_000, tier: .review,
                            rebuild: .download, action: .owner(command), sizeIsUpperLimit: true)
            let c = Confirmation.forOne(f, staleDays: 30)
            XCTAssertEqual(c.confirmTitle, "Clean up", "\(command)")
            XCTAssertTrue(c.cancelIsDefault, "\(command)")
        }
    }
}
