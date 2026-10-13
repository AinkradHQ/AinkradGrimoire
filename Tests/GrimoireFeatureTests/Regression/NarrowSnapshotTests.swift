import AinkradAppKit
import SwiftUI
import XCTest

@testable import GrimoireFeature

/// GD26: the whole window at 520 and 720 pt — nothing runs off either edge. Off-screen goldens (see `Snapshot`);
/// the clock is frozen and no CLI runs (`FakeEngine`, empty listers, the "found" agents are `/usr/bin/true`).
@MainActor
final class NarrowSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_700_000)

    func testColumnsGiveWay() {
        XCTAssertEqual(ColumnLayout.forWidth(1200, showsReview: true), ColumnLayout())
        XCTAssertEqual(ColumnLayout.forWidth(900, showsReview: false), ColumnLayout())
        XCTAssertEqual(ColumnLayout.forWidth(720, showsReview: false), ColumnLayout(isSidebarCompact: true))
        XCTAssertEqual(
            ColumnLayout.forWidth(900, showsReview: true), ColumnLayout(showsSidebar: false, isSidebarCompact: false))
        XCTAssertEqual(
            ColumnLayout.forWidth(720, showsReview: true), ColumnLayout(showsSidebar: false, isSidebarCompact: true))
        XCTAssertEqual(
            ColumnLayout.forWidth(520, showsReview: true),
            ColumnLayout(showsSidebar: false, isSidebarCompact: true, reviewReplacesThread: true))
    }

    func testFailedThread() throws {
        let model = try failedModel()
        assertWindow(model, named: "narrow-failed-520", width: 520)
        assertWindow(model, named: "narrow-failed-640", width: 640)
    }

    func testUsageLimit() throws {
        let model = makeModel()
        model.startThread(
            project: "/tmp/work", prompt: "Now screenshot both themes and attach them to the PR.", model: nil, mode: .ask,
            worktree: false)
        let live = try XCTUnwrap(model.current)
        live.apply(.usage([UsageWindow(name: "5-hour", utilization: 1, resetsAt: now.addingTimeInterval(72 * 60))]))
        live.apply(
            .turnFinished(
                TurnResult(outcome: .failed("You've hit your usage limit"), sessionID: "", costUSD: nil, text: nil)))
        XCTAssertEqual(model.alternative(to: .claude), .codex)
        assertWindow(model, named: "narrow-limit-520", width: 520)
    }

    func testNoAgentFound() {
        let model = makeModel()
        model.otherCLIs = [:]
        model.cli = .missing(searched: "/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        assertWindow(model, named: "narrow-no-agent-520", width: 520)
    }

    func testSettings() throws {
        let model = try failedModel()
        model.isShowingSettings = true
        assertWindow(model, named: "narrow-settings-520", width: 520)
    }

    /// At 720 pt the sidebar yields to the open review; at 520 the review stands in for the thread.
    func testReviewOpen() async throws {
        let turn = try FixtureReplay.turn(.claude)
        let model = makeModel()
        model.startThread(project: "/tmp/work", prompt: turn.prompt, model: nil, mode: .ask, worktree: false)
        let live = try XCTUnwrap(model.current)
        live.onSessionID = nil
        FixtureReplay.play(turn.steps, into: live)
        model.isReviewOpen = true
        let review = try XCTUnwrap(model.review(for: try XCTUnwrap(model.selectedThread)))
        review.scope = .thread
        await review.load()
        XCTAssertEqual(review.files.map(\.path), ["notes.txt"])
        assertWindow(model, named: "narrow-review-720", width: 720)
        assertWindow(model, named: "narrow-review-520", width: 520)
    }

    /// GD34: an approval asked while the review stands in for the thread docks under the review.
    func testApprovalWhileReviewStandsIn() async throws {
        let turn = try FixtureReplay.turn(.claude)
        let model = makeModel()
        model.startThread(project: "/tmp/work", prompt: turn.prompt, model: nil, mode: .ask, worktree: false)
        let live = try XCTUnwrap(model.current)
        live.onSessionID = nil
        FixtureReplay.play(turn.steps, into: live)
        live.send("Now run the tests")
        live.apply(.block(messageID: "m9", .toolUse(id: "t9", name: "Bash", input: ["command": "make test"])))
        live.apply(
            .approval(
                ApprovalRequest(
                    id: "r9", toolUseID: "t9", toolName: "Bash", input: ["command": "make test"], summary: "",
                    suggestions: [])))
        model.isReviewOpen = true
        let review = try XCTUnwrap(model.review(for: try XCTUnwrap(model.selectedThread)))
        review.scope = .thread
        await review.load()
        assertWindow(model, named: "narrow-review-approval-520", width: 520)
    }

    // MARK: - Fixtures

    private func assertWindow(_ model: GrimoireModel, named name: String, width: CGFloat) {
        Snapshot.assertMatches(Columns(model: model), named: name, size: CGSize(width: width, height: 640))
    }

    /// The agent exited on an auth error before it could start: the card with all three buttons.
    private func failedModel() throws -> GrimoireModel {
        let model = makeModel()
        model.startThread(
            project: "/tmp/work", prompt: "Run the ABI check again on Xcode beta", model: nil, mode: .ask, worktree: false)
        let live = try XCTUnwrap(model.current)
        let now = now
        model.now = { now.addingTimeInterval(0.8) }
        live.apply(.error("Error: Invalid API key · Please run /login\n    at auth (cli.js:4120)\nexit 1"))
        live.apply(.exited(code: 1))
        XCTAssertEqual(live.failure?.kind, .auth)
        return model
    }

    private func makeModel() -> GrimoireModel {
        let model = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()),
            sessionsRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-none-\(UUID())"))
        XCTAssertTrue(model.listers.isEmpty, "a model on a fixture root must not run the real agents")
        model.cli = .found(path: "/usr/bin/true", version: "2.1.296")
        model.otherCLIs = [.codex: .found(path: "/usr/bin/true", version: "0.154.0")]
        let now = now
        model.now = { now }
        model.engineOverride = { FakeEngine() }
        return model
    }
}
