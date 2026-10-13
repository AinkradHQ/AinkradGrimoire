import AinkradAppKit
import SwiftUI
import XCTest

@testable import GrimoireFeature

/// E6's engine states under Neon, checked against goldens (see `Snapshot`). The clock is frozen and no CLI
/// runs: the engine is a `FakeEngine`, listers stay empty, the "found" agents are `/usr/bin/true`.
@MainActor
final class StateSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_700_000)
    private let size = CGSize(width: 820, height: 520)

    /// B: a resumed thread's agent coming up — steps, spinner, shimmer, the "sends when ready" line.
    func testEngineStarting() throws {
        let model = makeModel()
        let turn = try FixtureReplay.turn(.claude)
        model.startThread(project: "/tmp/work", prompt: turn.prompt, model: nil, mode: .ask, worktree: false)
        let source = try XCTUnwrap(model.current)
        source.onSessionID = nil
        FixtureReplay.play(turn.steps, into: source)
        model.forkThread(try XCTUnwrap(model.selectedThread))
        let live = try XCTUnwrap(model.current)
        live.ensureStarted()
        XCTAssertNotNil(live.startingSince)
        try assertThread(model, named: "state-starting")
    }

    /// C: the agent exited before it could start; the card, and the message back in the composer.
    func testEngineFailed() throws {
        let model = makeModel()
        model.startThread(
            project: "/tmp/work", prompt: "Run the ABI check again on Xcode beta", model: nil, mode: .ask, worktree: false)
        let live = try XCTUnwrap(model.current)
        let now = now
        model.now = { now.addingTimeInterval(0.8) }
        live.apply(.error("Error: Invalid API key · Please run /login\n    at auth (cli.js:4120)\nexit 1"))
        live.apply(.exited(code: 1))
        XCTAssertEqual(live.failure?.kind, .auth)
        XCTAssertEqual(live.draft, "Run the ABI check again on Xcode beta")
        try assertThread(model, named: "state-failed")
    }

    /// D: Claude's 5-hour window is used up — the amber bar, and the sidebar's "limit · HH:MM".
    func testUsageLimit() throws {
        let model = makeModel()
        model.startThread(
            project: "/tmp/work", prompt: "Now screenshot both themes and attach them to the PR.", model: nil, mode: .ask,
            worktree: false)
        let live = try XCTUnwrap(model.current)
        live.apply(.commands([]))
        live.apply(
            .usage([
                UsageWindow(name: "5-hour", utilization: 1, resetsAt: now.addingTimeInterval(72 * 60)),
                UsageWindow(name: "7-day", utilization: 0.41, resetsAt: now.addingTimeInterval(4 * 86_400)),
            ]))
        live.apply(
            .turnFinished(
                TurnResult(outcome: .failed("You've hit your usage limit"), sessionID: "", costUSD: nil, text: nil)))
        XCTAssertEqual(model.alternative(to: .claude), .codex)
        try assertThread(model, named: "state-limit")
        try assertThread(model, named: "state-limit-narrow", width: 420)
        Snapshot.assertMatches(Sidebar(model: model), named: "state-limit-sidebar", size: CGSize(width: 300, height: 240))
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

    private func assertThread(_ model: GrimoireModel, named name: String, width: CGFloat? = nil) throws {
        let thread = try XCTUnwrap(model.selectedThread)
        Snapshot.assertMatches(
            ThreadView(model: model, thread: thread), named: name,
            size: CGSize(width: width ?? size.width, height: size.height))
    }
}
