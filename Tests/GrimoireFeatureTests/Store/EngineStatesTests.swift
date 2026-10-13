import Foundation
import Testing

@testable import GrimoireFeature

/// E6: an engine starting, failing, and stopped by its usage limit.
@MainActor
@Suite("Engine states")
struct EngineStatesTests {
    private let now = Date(timeIntervalSince1970: 1_791_700_000)

    private func make(_ entries: [ThreadEntry] = [], resume: String? = "s1") -> (LiveThread, FakeEngine) {
        let engine = FakeEngine()
        let now = now
        let live = LiveThread(
            entries: entries,
            startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/tmp"), resume: resume),
            clock: { now }, makeEngine: { engine })
        return (live, engine)
    }

    // MARK: - B · starting

    @Test("startup steps: found CLI, loaded history, then the current step")
    func startupSteps() {
        let steps = StartupStep.steps(
            harness: .claude, cli: .found(path: "/x/claude", version: "2.1.296"), loadedMessages: 142,
            location: "feat/glass-sidebar")
        #expect(
            steps == [
                StartupStep(title: "Found", code: "claude 2.1.296", done: true),
                StartupStep(title: "Loaded 142 messages from the session", code: nil, done: true),
                StartupStep(title: "Starting Claude in", code: "feat/glass-sidebar", done: false),
            ])
        // A new thread has no history line.
        #expect(
            StartupStep.steps(harness: .codex, cli: .found(path: "/x", version: ""), loadedMessages: 0, location: "repo")
                .map(\.title) == ["Found", "Starting Codex in"])
    }

    @Test("the thread is starting from spawn until the agent first says anything; history counts messages, not tools")
    func startingUntilReady() {
        let (live, engine) = make([.user("a"), .text("b"), .tool(ToolCall(id: "t", name: "Read", input: [:], result: nil))])
        #expect(live.loadedMessages == 2)
        #expect(live.startingSince == nil)
        live.send("hi")
        #expect(live.startingSince == now)
        #expect(engine.sent == ["hi"], "the message goes to the engine, which holds it until it is ready")
        live.apply(.error("warming up"))
        #expect(live.startingSince != nil, "an error is not an answer")
        live.apply(.commands([]))
        #expect(live.startingSince == nil)
    }

    // MARK: - C · failed

    @Test("failures are classified: auth, usage limit, anything else")
    func classify() {
        #expect(EngineFailure.classify("Error: Invalid API key · Please run /login") == .auth)
        #expect(EngineFailure.classify("Not logged in") == .auth)
        #expect(EngineFailure.classify("Claude AI usage limit reached|1791700000") == .usageLimit)
        #expect(EngineFailure.classify("You've hit your usage limit. Upgrade to Plus") == .usageLimit)
        #expect(EngineFailure.classify("Segmentation fault") == .other)
    }

    @Test("an agent that exits before it starts gets the card; the unsent message goes back to the composer")
    func exitBeforeStart() {
        let (live, _) = make([.user("earlier"), .text("ok")])
        live.send("Run the ABI check again")
        live.apply(.error("Error: Invalid API key · Please run /login\n    at auth (cli.js:4120)"))
        live.apply(.exited(code: 1))
        let failure = try? #require(live.failure)
        #expect(failure?.code == 1)
        #expect(failure?.beforeStart == true)
        #expect(failure?.kind == .auth)
        #expect(failure?.restoredDraft == true)
        #expect(failure?.headline(.claude) == "Claude stopped before it could start")
        #expect(live.draft == "Run the ABI check again")
        #expect(live.entries == [.user("earlier"), .text("ok")])
        if case .failed = live.status {} else { Issue.record("the sidebar dot goes red") }
    }

    @Test("Retry starts the agent again and sends the composer's message")
    func retry() {
        let (live, engine) = make()
        live.send("go")
        live.apply(.exited(code: 1))
        #expect(live.failure != nil)
        live.retry()
        #expect(live.failure == nil)
        #expect(live.draft.isEmpty)
        #expect(engine.sent == ["go", "go"])
        #expect(live.entries == [.user("go")])
    }

    @Test("a stop, a clean exit, or an exit while idle shows no card")
    func noCard() {
        let (live, _) = make()
        live.send("go")
        live.apply(.commands([]))
        live.apply(.turnFinished(TurnResult(outcome: .success, sessionID: "s1", costUSD: nil, text: nil)))
        live.apply(.exited(code: 1))
        #expect(live.failure == nil)
        let (stopped, _) = make()
        stopped.send("go")
        stopped.stop()
        stopped.apply(.exited(code: 1))
        #expect(stopped.failure == nil)
    }

    @Test("an auth error in a turn also gets the card; other turn errors keep the status line")
    func authTurn() {
        let (live, _) = make()
        live.send("go")
        live.apply(.turnFinished(TurnResult(outcome: .failed("boom"), sessionID: "s1", costUSD: nil, text: nil)))
        #expect(live.failure == nil)
        live.send("again")
        live.apply(
            .turnFinished(
                TurnResult(outcome: .failed("Invalid API key · Please run /login"), sessionID: "s1", costUSD: nil, text: nil)))
        #expect(live.failure?.kind == .auth)
        #expect(live.failure?.code == nil)
        #expect(live.draft == "again")
    }

    // MARK: - D · usage limit

    @Test("a window used up and not yet reset is a limit; the one resetting last decides")
    func limitFromWindows() {
        let windows = [
            UsageWindow(name: "5-hour", utilization: 1, resetsAt: now.addingTimeInterval(72 * 60)),
            UsageWindow(name: "7-day", utilization: 0.4, resetsAt: now.addingTimeInterval(86_400)),
        ]
        #expect(
            UsageLimit.current(.claude, windows: windows, now: now)
                == UsageLimit(harness: .claude, resetsAt: now.addingTimeInterval(72 * 60), window: "5-hour", utilization: 1))
        #expect(UsageLimit.current(.claude, windows: windows, now: now.addingTimeInterval(73 * 60)) == nil, "reset passed")
        #expect(UsageLimit.current(.claude, windows: [windows[1]], now: now) == nil)
        #expect(UsageLimit.countdown(to: now.addingTimeInterval(72 * 60), now: now) == "in 1 h 12 min")
        #expect(UsageLimit.countdown(to: now.addingTimeInterval(4 * 60), now: now) == "in 4 min")
    }

    @Test("a turn failing on the limit marks the busiest window used up, or one at the CLI's reset hint")
    func exhausting() {
        let windows = [
            UsageWindow(name: "5-hour", utilization: 0.97, resetsAt: now.addingTimeInterval(600)),
            UsageWindow(name: "7-day", utilization: 0.5, resetsAt: now.addingTimeInterval(86_400)),
        ]
        let marked = UsageLimit.exhausting(windows, resetHint: nil, now: now)
        #expect(UsageLimit.current(.codex, windows: marked, now: now)?.window == "5-hour")
        let hint = UsageLimit.resetHint(in: "Claude AI usage limit reached|1791704320")
        #expect(hint == Date(timeIntervalSince1970: 1_791_704_320))
        let fromHint = UsageLimit.exhausting([], resetHint: hint, now: now)
        #expect(UsageLimit.current(.claude, windows: fromHint, now: now)?.resetsAt == hint)
        #expect(UsageLimit.current(.claude, windows: fromHint, now: now)?.window == nil)
    }

    @Test("the limit failure copies the message to the composer, notes it, and reports the reset hint")
    func limitTurn() {
        let (live, _) = make()
        var hints: [Date?] = []
        live.onUsageLimit = { hints.append($0) }
        live.send("Now screenshot both themes")
        live.apply(
            .turnFinished(
                TurnResult(
                    outcome: .failed("Claude AI usage limit reached|1791704320"), sessionID: "s1", costUSD: nil, text: nil)))
        #expect(live.hitLimit)
        #expect(live.failure == nil, "the limit bar shows it, not the card")
        #expect(live.draft == "Now screenshot both themes")
        #expect(live.entries == [.user("Now screenshot both themes"), .note(LiveThread.limitNote("The agent"))])
        #expect(hints == [Date(timeIntervalSince1970: 1_791_704_320)])
    }

    @Test("Send at reset queues the composer's message; it goes out at the reset, or not at all when cancelled")
    func sendAtReset() {
        let (live, engine) = make()
        live.draft = "later"
        live.sendAtReset(now.addingTimeInterval(3600))
        #expect(live.sendAt == now.addingTimeInterval(3600))
        live.sendQueued()
        #expect(engine.sent == ["later"])
        #expect(live.sendAt == nil)
        #expect(live.draft.isEmpty)
        live.draft = "never"
        live.sendAtReset(now.addingTimeInterval(3600))
        live.cancelSendAtReset()
        live.sendQueued()
        #expect(engine.sent == ["later"])
        #expect(live.draft == "never")
    }

    @Test("the other agent offered: Codex first, else another installed one that isn't limited")
    func alternative() {
        let found = CLIStatus.found(path: "/x", version: "1")
        let all: [Harness: CLIStatus] = [.claude: found, .codex: found, .opencode: found, .agy: .missing(searched: "")]
        #expect(UsageLimit.alternative(to: .claude, statuses: all, limited: []) == .codex)
        #expect(UsageLimit.alternative(to: .codex, statuses: all, limited: []) == .claude)
        #expect(UsageLimit.alternative(to: .codex, statuses: all, limited: [.claude]) == .opencode)
        #expect(UsageLimit.alternative(to: .claude, statuses: [.claude: found], limited: []) == nil)
    }

    @Test("New thread with Codex carries the composer's message (or the last one sent) to a new Codex thread")
    func carryOver() throws {
        let model = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()),
            sessionsRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-none-\(UUID())"))
        #expect(model.listers.isEmpty)
        model.cli = .found(path: "/usr/bin/true", version: "2.1.296")
        model.otherCLIs[.codex] = .found(path: "/usr/bin/true", version: "0.154.0")
        let now = now
        model.now = { now }
        var engines: [FakeEngine] = []
        model.engineOverride = {
            let engine = FakeEngine()
            engines.append(engine)
            return engine
        }
        model.startThread(project: "/repo", prompt: "Screenshot both themes", model: nil, mode: .ask, worktree: false)
        let claude = try #require(model.selectedThread)
        let live = try #require(model.current)
        live.apply(
            .turnFinished(TurnResult(outcome: .failed("You've hit your usage limit"), sessionID: "", costUSD: nil, text: nil)))
        #expect(model.limit(for: .claude) != nil)
        #expect(model.alternative(to: .claude) == .codex)
        model.carryOver(claude, to: .codex)
        let codex = try #require(model.selectedThread)
        #expect(codex.harness == .codex)
        #expect(codex.projectPath == "/repo")
        #expect(engines.last?.sent == ["Screenshot both themes"])
        #expect(live.draft.isEmpty)
    }
}

/// The status line's facts (mockups 1, 2): what runs, for how long, and the tokens the CLI reports.
@MainActor
@Suite("Turn facts")
struct TurnFactsTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_791_700_000) }

    @Test func workingThenDone() {
        let clock = Clock()
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/tmp")),
            clock: { clock.now }, makeEngine: { FakeEngine() })
        live.send("Run the goldens")
        live.apply(.block(messageID: "m1", .toolUse(id: "b", name: "Bash", input: ["command": "make test", "description": "Running goldens"])))
        live.apply(.tokens(messageID: "m1", output: 900))
        live.apply(.tokens(messageID: "m1", output: 1_200))
        live.apply(.tokens(messageID: "m2", output: 300))
        clock.now += 48
        #expect(live.activity == "Running goldens")
        #expect(live.turnOutputTokens == 1_500)
        #expect(live.turnElapsed == 48)
        live.apply(.toolResult(toolUseID: "b", content: "ok", isError: false))
        guard case .tool(let call) = live.entries.last else {
            Issue.record("no tool card")
            return
        }
        #expect(call.duration == 48)
        #expect(live.activity == nil)
        clock.now += 112
        live.apply(.turnFinished(TurnResult(outcome: .success, sessionID: "s", outputTokens: 31_200)))
        #expect(live.lastTurn?.duration == 160)
        #expect(live.lastTurn?.tokens == 31_200)
        #expect(TokenCount.short(31_200) == "31.2k")
        #expect(StatusTime.short(160) == "2m 40s")
    }
}
