import Foundation
import Testing

@testable import GrimoireFeature

/// The recorded harness turns in `Engine/Fixtures/`, decoded by each harness's
/// own protocol parser — no CLI runs. A replay is the prompt that started the
/// turn plus what followed: our later messages, and the agent's events.
@MainActor
enum FixtureReplay {
    enum Step {
        case send(String)
        case event(EngineEvent)
    }

    struct Turn {
        let prompt: String
        let steps: [Step]
        var events: [EngineEvent] { steps.compactMap { if case .event(let event) = $0 { event } else { nil } } }
    }

    static let openCodeSession = "ses_ed8f064e5ffeyIEoYiZuviYaUo"

    static func lines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Engine/Fixtures/\(name).ndjson")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// `claude -p` stream-json: `<` lines are the CLI's, `>` user lines our messages
    /// (the first is the prompt). Our control requests are left out, as `LiveThreadTests` does.
    static func claude() throws -> Turn {
        var wire = ClaudeProtocol()
        var prompt: String?
        var steps: [Step] = []
        for line in try lines("claude-edit-model") {
            let body = String(line.dropFirst(2))
            if line.hasPrefix("<") {
                steps += wire.decode(body).map(Step.event)
            } else if let message = try? JSONValue.parse(body), message["type"]?.stringValue == "user",
                let text = message["message"]?["content"]?.stringValue
            {
                if prompt == nil { prompt = text } else { steps.append(.send(text)) }
            }
        }
        return Turn(prompt: prompt ?? "", steps: steps)
    }

    /// `opencode serve` events for one session; the prompt is the one the recording sent.
    static func openCode() throws -> Turn {
        var wire = OpenCodeProtocol()
        wire.sessionID = openCodeSession
        let events = try lines("opencode-turn").flatMap { wire.decode(try JSONValue.parse($0)) }
        return Turn(
            prompt: "Run the shell command `ls` and then change a.txt so it says bye. Be brief.",
            steps: events.map(Step.event))
    }

    /// `agy` stream-json; the recording has no prompt line, so this is its gist.
    static func agy() throws -> Turn {
        var wire = AgyProtocol()
        let events = try lines("agy-turn").flatMap { wire.decode($0) }
        return Turn(prompt: "Run ls, then change a.txt so it says bye.", steps: events.map(Step.event))
    }

    static func turn(_ harness: Harness) throws -> Turn {
        switch harness {
        case .claude: try claude()
        case .opencode: try openCode()
        case .agy: try agy()
        // No Codex recording yet: its first live turn is recorded on 10-15.
        case .codex: Turn(prompt: "", steps: [])
        }
    }

    /// Plays `steps` into `live`, allowing each approval — or stopping on the
    /// first one when `stopAtApproval`, so the thread waits on you.
    static func play(_ steps: [Step], into live: LiveThread, stopAtApproval: Bool = false) {
        for step in steps {
            switch step {
            case .send(let text): live.send(text)
            case .event(let event):
                live.apply(event)
                if case .approval = event {
                    if stopAtApproval { return }
                    live.answer(.allow)
                }
            }
        }
    }
}

/// Each recorded turn replays into a thread and ends where the live run did.
/// Claude's replay is `LiveThreadTests.recordedSession`; Codex has no recording yet.
@MainActor
@Suite("Fixture replay")
struct FixtureReplayTests {
    private func replay(_ harness: Harness) throws -> (LiveThread, FakeEngine) {
        let turn = try FixtureReplay.turn(harness)
        let engine = FakeEngine()
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { engine })
        live.send(turn.prompt)
        FixtureReplay.play(turn.steps, into: live)
        return (live, engine)
    }

    private func tools(_ live: LiveThread) -> [ToolCall] {
        live.entries.compactMap { if case .tool(let call) = $0 { call } else { nil } }
    }

    @Test("OpenCode: three approvals answered, four tool cards with results, the edit, the answer, idle")
    func openCode() throws {
        let (live, engine) = try replay(.opencode)
        #expect(engine.answers == [.allow, .allow, .allow])
        #expect(live.status == .idle)
        #expect(live.pendingApproval == nil)
        #expect(live.turnStartedAt == nil)
        #expect(live.entries.count == 11, "prompt, 4 tool cards, 5 thinking rows, the answer")
        let calls = tools(live)
        #expect(calls.map(\.name) == ["Bash", "Read", "Read", "Write"])
        #expect(calls.allSatisfy { $0.result != nil }, "every tool card has its result")
        #expect(calls.filter { $0.result?.isError == true }.count == 1, "the read of a missing file failed")
        let edits = ReviewChanges.fromEntries(live.entries, scope: .thread, workingDirectory: "/repo")
        #expect(edits.map(\.path) == ["a.txt"])
        #expect(live.entries.last == .text("Okay, `a.txt` has been changed."))
    }

    @Test("agy: a command, a read and an update, each with a result; the answer; idle")
    func agy() throws {
        let (live, engine) = try replay(.agy)
        #expect(engine.answers.isEmpty, "agy asks no approvals in print mode")
        #expect(live.sessionID == AgyProtocolTests.conversation)
        #expect(live.status == .idle)
        #expect(live.turnStartedAt == nil)
        #expect(live.entries.count == 5, "prompt, 3 tool cards, the answer")
        let calls = tools(live)
        #expect(calls.map(\.name) == ["Bash", "Read", "Update"])
        #expect(calls.allSatisfy { $0.result?.isError == false })
        #expect(calls.last?.input["file_path"]?.stringValue == "/repo/a.txt")
        // GD24: the update reaches the review pane; its diff comes from git (no strings in agy's stream).
        let edits = ReviewChanges.fromEntries(live.entries, scope: .thread, workingDirectory: "/repo")
        #expect(edits == [FileChange(path: "a.txt", status: .modified, diff: nil)])
        #expect(live.entries.last == .text("Ran `ls` and updated [a.txt](file:///repo/a.txt) to say \"bye\".\n"))
    }
}
