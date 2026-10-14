import Foundation
import Testing

@testable import GrimoireFeature

/// Records what the thread asks of its engine; emits nothing on its own.
@MainActor
final class FakeEngine: HarnessEngine {
    let events = AsyncStream<EngineEvent> { _ in }
    private(set) var started: EngineStartOptions?
    private(set) var sent: [String] = []
    private(set) var images: [[EngineImage]] = []
    private(set) var answers: [ApprovalDecision] = []
    private(set) var interrupts = 0
    private(set) var modes: [PermissionMode] = []
    private(set) var efforts: [String] = []
    /// Set to make `send` throw, as a dead pipe does.
    var sendError: (any Error)?
    /// Set to make `start` throw, as a missing binary does.
    var startError: (any Error)?

    func start(_ options: EngineStartOptions) throws {
        if let startError { throw startError }
        started = options
    }
    func send(_ text: String, images: [EngineImage]) throws {
        if let sendError { throw sendError }
        sent.append(text)
        self.images.append(images)
    }
    func interrupt() throws { interrupts += 1 }
    func answer(_ request: ApprovalRequest, with decision: ApprovalDecision) throws { answers.append(decision) }
    func setPermissionMode(_ mode: PermissionMode) throws { modes.append(mode) }
    func setModel(_ model: String) throws {}
    func setEffort(_ effort: String) throws { efforts.append(effort) }
    func stop() {}
}

@MainActor
@Suite("LiveThread")
struct LiveThreadTests {
    private func make(_ entries: [ThreadEntry] = []) -> (LiveThread, FakeEngine) {
        let engine = FakeEngine()
        let live = LiveThread(
            entries: entries,
            startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/tmp"), resume: "s1"),
            makeEngine: { engine })
        return (live, engine)
    }

    @Test("GD45: an agent gone mid-turn with code 0 (OpenCode's server died) gets the failure card, Retry and the message back")
    func cleanExitMidTurn() {
        let (live, engine) = make()
        live.send("Run the tests")
        live.apply(.exited(code: 0))
        #expect(live.failure?.code == 0)
        #expect(live.failure?.restoredDraft == true)
        #expect(live.draft == "Run the tests")
        #expect(live.entries.isEmpty, "the unanswered message moves back to the composer")
        live.retry()
        #expect(engine.sent == ["Run the tests", "Run the tests"])

        // Between turns a clean exit is just the CLI ending: no card.
        let (idle, _) = make()
        idle.ensureStarted()
        idle.apply(.exited(code: 0))
        #expect(idle.failure == nil && idle.status == .idle)
    }

    @Test("sending starts the agent once, resuming the stored session, and shows the message")
    func send() {
        let (live, engine) = make([.user("earlier")])
        live.send("next")
        live.send("and another")
        #expect(engine.started?.resume == "s1")
        #expect(engine.sent == ["next", "and another"])
        #expect(live.entries == [.user("earlier"), .user("next"), .user("and another")])
        #expect(live.status == .working)
        #expect(live.turnStartedAt != nil)
    }

    @Test("streamed text grows one row, and the finished block replaces it rather than adding another")
    func streaming() {
        let (live, _) = make()
        live.apply(.textDelta(messageID: "m1", text: "Hel"))
        live.apply(.textDelta(messageID: "m1", text: "lo"))
        #expect(live.entries == [.text("Hello")])
        live.apply(.block(messageID: "m1", .text("Hello.")))
        live.apply(.textDelta(messageID: "m2", text: "Next"))
        #expect(live.entries == [.text("Hello."), .text("Next")])
    }

    @Test("an approval waits on you; answering it goes to the engine and clears it")
    func approval() {
        let (live, engine) = make()
        live.send("edit it")
        let request = ApprovalRequest(
            id: "r", toolUseID: "t", toolName: "Edit", input: [:], summary: "a", suggestions: [["mode": "acceptEdits"]])
        live.apply(.block(messageID: "m", .toolUse(id: "t", name: "Edit", input: [:])))
        live.apply(.approval(request))
        #expect(live.status == .needsYou)
        #expect(live.pendingApproval == request)
        live.answer(.allowAlways)
        #expect(engine.answers == [.allowAlways])
        #expect(live.pendingApproval == nil)
        #expect(live.status == .working)
    }

    @Test("GD3: a command a hook rewrote shows as it will run, keeping what the agent wrote")
    func rewrittenCommand() {
        let (live, _) = make()
        live.send("show it")
        live.apply(.block(messageID: "m", .toolUse(id: "t", name: "Bash", input: ["command": "cat -n a.txt"])))
        live.apply(
            .approval(
                ApprovalRequest(
                    id: "r", toolUseID: "t", toolName: "Bash", input: ["command": "rtk read a.txt"], summary: "",
                    suggestions: [])))
        guard case .tool(let call) = live.entries.last else { return #expect(Bool(false), "no tool card") }
        #expect(call.input["command"] == "rtk read a.txt")
        #expect(call.rewrittenFrom == "cat -n a.txt")
        // An approval with no command (Codex's file change) leaves the card alone.
        live.apply(.block(messageID: "m", .toolUse(id: "p", name: "Patch", input: ["changes": []])))
        live.apply(
            .approval(ApprovalRequest(id: "r2", toolUseID: "p", toolName: "Patch", input: .null, summary: "", suggestions: [])))
        #expect(live.entries.last == .tool(ToolCall(id: "p", name: "Patch", input: ["changes": []], result: nil)))
    }

    @Test("a recorded Claude session replays into the thread without duplicates or errors")
    func recordedSession() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Engine/Fixtures/claude-edit-model.ndjson")
        let (live, engine) = make()
        live.ensureStarted()
        var wire = ClaudeProtocol()
        for raw in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where raw.hasPrefix("<") {
            for event in wire.decode(String(raw.dropFirst(2))) {
                live.apply(event)
                if case .approval = event { live.answer(.allow) }
            }
        }
        #expect(engine.answers == [.allow])
        #expect(live.sessionID == "4eebf877-04c2-44d2-baa8-9f78073882d1")
        #expect(live.model == "claude-sonnet-5-5")
        #expect(live.costUSD > 0)
        #expect(live.status == .idle)
        let tools = live.entries.compactMap { if case .tool(let call) = $0 { call } else { nil } }
        #expect(tools.map(\.name) == ["Read", "Edit"])
        #expect(tools.allSatisfy { $0.result != nil })
        let texts = live.entries.compactMap { if case .text(let text) = $0 { text } else { nil } }
        #expect(texts.filter { $0.contains("DONE") }.count == 1, "streamed and finished text must not both show")
    }

    @Test("a failed turn shows its error; the process exiting returns to idle")
    func failure() {
        let (live, _) = make()
        live.send("go")
        live.apply(.turnFinished(TurnResult(outcome: .failed("boom"), sessionID: "s1", costUSD: nil, text: nil)))
        #expect(live.status == .failed("boom"))
        live.send("again")
        live.stop()
        live.apply(.exited(code: 0))
        #expect(live.status == .idle)
        #expect(!live.isRunning)
    }

    @Test("GD13: a CLI that dies mid-turn with no stderr fails the turn and closes its running tool cards")
    func deathMidTurn() {
        let (live, _) = make()
        live.send("go")
        live.apply(.block(messageID: "m1", .toolUse(id: "t1", name: "Bash", input: .object([:]))))
        live.apply(.exited(code: 9))
        #expect(live.status == .failed("The agent exited mid-turn (code 9)"))
        #expect(!live.isRunning)
        let tools = live.entries.compactMap { if case .tool(let call) = $0 { call } else { nil } }
        #expect(tools.first?.result?.isError == true)
    }

    @Test("GD17: Stop is offered while a turn runs or waits; Always allow only when the agent suggests a rule")
    func shortcutAvailability() {
        let (live, _) = make()
        #expect(!live.canInterrupt)
        live.send("go")
        #expect(live.canInterrupt)
        #expect(!live.canAllowAlways)
        live.apply(
            .approval(
                ApprovalRequest(id: "r1", toolUseID: "t", toolName: "Bash", input: [:], summary: "a", suggestions: [])))
        #expect(live.status == .needsYou)
        #expect(live.canInterrupt)
        #expect(!live.canAllowAlways)
        live.answer(.allow)
        live.apply(
            .approval(
                ApprovalRequest(
                    id: "r2", toolUseID: "t", toolName: "Edit", input: [:], summary: "a",
                    suggestions: [["mode": "acceptEdits"]])))
        #expect(live.canAllowAlways)
        live.answer(.deny(reason: "no"))
        #expect(!live.canAllowAlways)
        live.apply(.turnFinished(TurnResult(outcome: .failed("boom"), sessionID: "s1", costUSD: nil, text: nil)))
        #expect(!live.canInterrupt)
    }

    @Test("an exit while idle stays idle")
    func exitWhileIdle() {
        let (live, _) = make()
        live.ensureStarted()
        live.apply(.exited(code: 0))
        #expect(live.status == .idle)
    }
}

@Suite("ProjectFiles")
struct ProjectFilesTests {
    @Test("names that start with the query first, then names, then paths; shorter first")
    func search() {
        let files = [
            "Sources/App/RootView.swift", "Sources/Sidebar.swift", "Tests/SidebarTests.swift", "docs/side/notes.md",
        ]
        #expect(
            ProjectFiles.search(files, query: "side")
                == ["Sources/Sidebar.swift", "Tests/SidebarTests.swift", "docs/side/notes.md"])
        #expect(ProjectFiles.search(files, query: "root") == ["Sources/App/RootView.swift"])
        #expect(ProjectFiles.search(files, query: "", limit: 1) == ["docs/side/notes.md"])
    }

    @Test("listing skips hidden files and build folders")
    func list() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-files-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Sources/a.swift", ".git/HEAD", "build/out.o", "node_modules/x/index.js", ".env", "README.md"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(Set(ProjectFiles.list(root: root)) == ["Sources/a.swift", "README.md"])
    }
}
