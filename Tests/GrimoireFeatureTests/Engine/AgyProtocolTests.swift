import Foundation
import Testing

@testable import GrimoireFeature

/// Lines as `agy` 1.3.2 prints them in stream-json print mode — a recorded
/// live turn (run `ls`, then rewrite a file) with paths sanitised.
@Suite("AgyProtocol")
struct AgyProtocolTests {
    static let conversation = "fac3c7f3-b57d-4cc3-a6ee-c82797d14048"

    @Test("a recorded turn: session, tool cards with results, streamed answer, result")
    func recordedTurn() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agy-turn.ndjson")
        var wire = AgyProtocol()
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").flatMap { wire.decode(String($0)) }

        #expect(
            events.first
                == .sessionStarted(
                    SessionInfo(sessionID: Self.conversation, model: "", permissionMode: .ask, workingDirectory: "/repo", tools: [])))
        #expect(wire.conversationID == Self.conversation)
        let tools = events.compactMap { event -> String? in
            guard case .block(_, .toolUse(_, let name, _)) = event else { return nil }
            return name
        }
        #expect(tools == ["Bash", "Read", "Update"])
        #expect(events.contains(.block(messageID: "step-2", .toolUse(id: "step-2", name: "Bash", input: ["command": "ls"]))))
        #expect(events.contains(.toolResult(toolUseID: "step-2", content: "a.txt\r\n", isError: false)))
        let answer = "Ran `ls` and updated [a.txt](file:///repo/a.txt) to say \"bye\".\n"
        #expect(events.contains(.textDelta(messageID: "step-7", text: "Ran `ls")))
        #expect(events.contains(.block(messageID: "step-7", .text(answer))))
        #expect(events.last == .turnFinished(TurnResult(outcome: .success, sessionID: Self.conversation, costUSD: nil, text: answer)))
    }

    @Test("a failed run ends the turn with its error")
    func failure() {
        var wire = AgyProtocol()
        let events = wire.decode(
            #"{"event":"result","result":{"conversation_id":"c","status":"ERROR","response":"","error":"stream input message is missing the \"event\" field"}}"#)
        #expect(events == [.turnFinished(TurnResult(outcome: .failed(#"stream input message is missing the "event" field"#), sessionID: "c", costUSD: nil, text: ""))])
    }

    @Test("the command line: conversation, model and mode, with -p= last")
    func arguments() {
        var wire = AgyProtocol()
        #expect(wire.arguments() == ["--input-format", "stream-json", "--output-format", "stream-json", "-p="])
        wire.conversationID = "c"
        wire.model = "Gemini 3.6 Flash (Low)"
        wire.mode = .acceptEdits
        #expect(wire.arguments().suffix(7) == ["--conversation", "c", "--model", "Gemini 3.6 Flash (Low)", "--mode", "accept-edits", "-p="])
        wire.mode = .bypassPermissions
        #expect(wire.arguments().suffix(2) == ["--dangerously-skip-permissions", "-p="])
        #expect(AgyProtocol.message("hi") == ["event": "user", "message": ["role": "user", "content": "hi"]])
    }

    @Test("a summaries row becomes an agy thread")
    func summary() throws {
        let summary = try #require(
            AgySessions.summary(
                id: "c1", title: "Run Shell Command And Edit File", modified: "2026-10-10 18:41:04.859319+00:00",
                workspaces: #"["file:///work/app","file:///tmp/ext"]"#))
        #expect(summary.harness == .agy && summary.projectPath == "/work/app")
        #expect(summary.lastActivity == Date(timeIntervalSince1970: 1_791_657_664))
        #expect(AgySessions.summary(id: "c2", title: "", modified: "", workspaces: "[]") == nil)
    }

    @Test("agy models: one id and display name per tab-separated line")
    func models() {
        #expect(
            AgySessions.parseModels("gemini-3.8-flash-high\tGemini 3.8 Flash (High)\nFetching…\nclaude-opus-5-5-low\tClaude Opus 5.5 (Low)\n")
                == [
                    ModelChoice(id: "gemini-3.8-flash-high", name: "Gemini 3.8 Flash (High)"),
                    ModelChoice(id: "claude-opus-5-5-low", name: "Claude Opus 5.5 (Low)"),
                ])
    }
}
