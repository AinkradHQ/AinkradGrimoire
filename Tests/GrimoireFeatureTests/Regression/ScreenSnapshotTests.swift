import AinkradAppKit
import SwiftUI
import XCTest

@testable import GrimoireFeature

/// Grimoire's main screens under Neon, checked against goldens (see `Snapshot`).
/// XCTest, not Swift Testing: rendering waits on main-queue work. Threads are
/// the recorded fixtures replayed through each harness's parser; no CLI runs —
/// listers stay empty and the "found" Claude is `/usr/bin/true`.
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    private static let threadSize = CGSize(width: 820, height: 640)

    func testSidebarWithThreads() async throws {
        let (model, root) = try await sidebarModel()
        defer { try? FileManager.default.removeItem(at: root) }
        Snapshot.assertMatches(Sidebar(model: model), named: "sidebar", size: CGSize(width: 300, height: 640))
    }

    func testClaudeThreadWithToolCards() throws {
        let model = try threadModel(.claude)
        try assertThread(model, named: "thread-claude")
    }

    func testOpenCodeThreadWithToolCards() throws {
        let model = try threadModel(.opencode)
        try assertThread(model, named: "thread-opencode")
    }

    func testAgyThreadWithToolCards() throws {
        let model = try threadModel(.agy)
        try assertThread(model, named: "thread-agy")
    }

    func testApprovalWaitingOnYou() throws {
        let model = try threadModel(.claude, stopAtApproval: true)
        XCTAssertEqual(model.current?.status, .needsYou)
        try assertThread(model, named: "approval")
    }

    func testReviewPaneOnTheThreadsEdits() async throws {
        let model = try threadModel(.claude)
        model.isReviewOpen = true
        let thread = try XCTUnwrap(model.selectedThread)
        let review = try XCTUnwrap(model.review(for: thread))
        review.scope = .thread
        await review.load()
        XCTAssertEqual(review.files.map(\.path), ["notes.txt"])
        try assertThread(model, named: "review", width: Self.threadSize.width + 440)
    }

    func testNewThreadComposer() async throws {
        let (model, root) = try await sidebarModel()
        defer { try? FileManager.default.removeItem(at: root) }
        Snapshot.assertMatches(
            NewThreadSheet(model: model) {}.padding(20), named: "composer", size: CGSize(width: 600, height: 460))
    }

    /// GD15: a long changed line wraps under its text instead of ending in "…".
    func testDiffWrapsLongLines() {
        let long = "let message = \"The agent exited mid-turn, so this changed end of the line must stay readable\""
        let diff = AinkradDiffEngine.compute(
            old: "let a = 1\n" + long.replacingOccurrences(of: "readable", with: "visible"),
            new: "let a = 1\n" + long, path: "a.swift")
        Snapshot.assertMatches(
            DiffBlock(diff: diff).padding(12), named: "diff-long-lines", size: CGSize(width: 360, height: 220))
    }

    /// GD10: a squeezed thread folds its header buttons into More and drops the composer's captions.
    func testThreadInANarrowPane() throws {
        let model = try threadModel(.claude)
        try assertThread(model, named: "thread-narrow", width: 300)
    }

    /// GD16: at 720 pt the sidebar gives way and Settings stacks its controls under their labels; nothing clips.
    func testSettingsInANarrowWindow() async throws {
        let (model, root) = try await sidebarModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.isShowingSettings = true
        Snapshot.assertMatches(
            HStack(spacing: 0) {
                Sidebar(model: model)
                MainPane(model: model)
            }, named: "settings-narrow", size: CGSize(width: 720, height: 640))
    }

    /// GD23: no agent CLI — install commands each on one line, the PATH as separate folders, left-aligned.
    func testNoAgentFound() {
        let model = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()),
            sessionsRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-none-\(UUID())"))
        model.cli = .missing(searched: "/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        Snapshot.assertMatches(MainPane(model: model), named: "no-agent", size: CGSize(width: 520, height: 560))
    }

    /// GD29 (mockup 12 D): a search with no hits offers "Clear search".
    func testSearchWithNoHits() async throws {
        let (model, root) = try await sidebarModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.searchText = "kubernetes ingress"
        Snapshot.assertMatches(Sidebar(model: model), named: "search-no-hits", size: CGSize(width: 300, height: 420))
    }

    // MARK: - Fixtures

    private func assertThread(_ model: GrimoireModel, named name: String, width: CGFloat = threadSize.width) throws {
        let thread = try XCTUnwrap(model.selectedThread)
        XCTAssertNotEqual(model.current?.status, .working, "a working thread's status line runs a clock")
        Snapshot.assertMatches(
            ThreadView(model: model, thread: thread), named: name,
            size: CGSize(width: width, height: Self.threadSize.height))
    }

    /// A new thread on `harness` whose recorded turn has been played in.
    private func threadModel(_ harness: Harness, stopAtApproval: Bool = false) throws -> GrimoireModel {
        let turn = try FixtureReplay.turn(harness)
        let model = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()),
            sessionsRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-none-\(UUID())")
        )
        model.engineOverride = { FakeEngine() }
        // Frozen: the status line's "Done in …" and the cards' durations come from this clock.
        model.now = { Date(timeIntervalSince1970: 1_791_700_000) }
        model.startThread(
            project: harness == .claude ? "/tmp/work" : "/repo", prompt: turn.prompt, model: nil, mode: .ask,
            worktree: false, harness: harness)
        let live = try XCTUnwrap(model.current)
        // Adopting the CLI's session id reloads the listing, which finds the real `claude`.
        live.onSessionID = nil
        FixtureReplay.play(turn.steps, into: live, stopAtApproval: stopAtApproval)
        return model
    }

    /// The glass sweep's sessions, aged under an hour (relative times don't
    /// shift with the time of day) and listed with the "found" Claude faked.
    private func sidebarModel() async throws -> (GrimoireModel, URL) {
        let root = try SampleSessions.write()
        // Minutes ago; each sits mid-minute, clear of a rounding edge. "glass" reads "now".
        let ages = [
            "release": 4, "engine": 9, "index": 14, "scry": 19, "abi": 24, "lore": 29, "g1": 34, "a1": 39, "u1": 44,
        ]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects ?? []
        for case let file as URL in files where file.pathExtension == "jsonl" {
            let seconds = ages[file.deletingPathExtension().lastPathComponent].map { $0 * 60 + 30 } ?? 20
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -TimeInterval(seconds))], ofItemAtPath: file.path)
        }
        let settings = SettingsStore(documents: MemoryDocs())
        settings.cliPathOverride = "/usr/bin/true"
        let model = GrimoireModel(settings: settings, sessionsRoot: root)
        XCTAssertTrue(model.listers.isEmpty, "a model on a fixture root must not run the real agents")
        await model.reload()
        model.selectedThreadID = "glass"
        let deadline = Date().addingTimeInterval(5)
        while model.current == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(model.current, "the selected thread did not load")
        return (model, root)
    }
}
