import Foundation
import Testing

@testable import GrimoireFeature

/// Events as `opencode serve` 1.18.34 streams them — a recorded live turn
/// (run `ls`, then rewrite a file) with paths sanitised.
@Suite("OpenCodeProtocol")
struct OpenCodeProtocolTests {
    static let session = "ses_ed8f064e5ffeyIEoYiZuviYaUo"

    private func replay() throws -> [EngineEvent] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/opencode-turn.ndjson")
        var wire = OpenCodeProtocol()
        wire.sessionID = Self.session
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .flatMap { wire.decode(try JSONValue.parse(String($0))) }
    }

    @Test("a recorded turn: thinking, three approvals, tool cards with results, the answer, then idle")
    func recordedTurn() throws {
        let events = try replay()
        let approvals = events.compactMap { if case .approval(let request) = $0 { request } else { nil } }
        #expect(approvals.map(\.toolName) == ["Bash", "Outside folder", "Edit"])
        #expect(approvals.first?.input["command"] == "ls")
        #expect(approvals.first?.id.hasPrefix("per_") == true)
        #expect(approvals.last?.input["file_path"] == "/repo/a.txt")

        let tools = events.compactMap { event -> String? in
            guard case .block(_, .toolUse(_, let name, _)) = event else { return nil }
            return name
        }
        #expect(tools.first == "Bash" && tools.contains("Read") && tools.last == "Write")
        let results = events.compactMap { if case .toolResult(_, let content, let isError) = $0 { (content, isError) } else { nil } }
        #expect(results.contains { $0.1 && $0.0.contains("File not found") }, "a failed read is an error result")
        #expect(results.contains { !$0.1 && $0.0 == "Wrote file successfully." })

        #expect(events.contains { if case .block(_, .thinking) = $0 { true } else { false } })
        #expect(!events.contains { $0 == .block(messageID: "prt_1270f9b660013juDbyMp7IRurX", .text("Run the shell command `ls` and then change a.txt so it says bye. Be brief.")) },
            "the prompt's own echo is not shown")
        #expect(events.contains { if case .block(_, .text("Okay, `a.txt` has been changed.")) = $0 { true } else { false } })
        #expect(events.last == .turnFinished(TurnResult(outcome: .success, sessionID: Self.session, costUSD: nil, text: nil)))
    }

    @Test("events for other sessions are ignored")
    func otherSessions() {
        var wire = OpenCodeProtocol()
        wire.sessionID = "ses_mine"
        #expect(wire.decode(["type": "session.idle", "properties": ["sessionID": "ses_other"]]) == [])
    }

    @Test("text deltas stream; reasoning deltas wait for the finished block")
    func deltas() {
        var wire = OpenCodeProtocol()
        wire.sessionID = "s"
        _ = wire.decode(["type": "message.part.updated", "properties": ["sessionID": "s", "part": ["id": "t", "messageID": "m", "type": "text", "text": ""]]])
        _ = wire.decode(["type": "message.part.updated", "properties": ["sessionID": "s", "part": ["id": "r", "messageID": "m", "type": "reasoning", "text": ""]]])
        #expect(wire.decode(["type": "message.part.delta", "properties": ["sessionID": "s", "partID": "t", "field": "text", "delta": "Hi"]]) == [.textDelta(messageID: "t", text: "Hi")])
        #expect(wire.decode(["type": "message.part.delta", "properties": ["sessionID": "s", "partID": "r", "field": "text", "delta": "hmm"]]) == [])
    }

    @Test("an aborted turn ends interrupted; another error fails it")
    func endings() {
        var wire = OpenCodeProtocol()
        wire.sessionID = "s"
        let idle: JSONValue = ["type": "session.idle", "properties": ["sessionID": "s"]]
        _ = wire.decode(["type": "session.error", "properties": ["sessionID": "s", "error": ["name": "MessageAbortedError", "data": [:]]]])
        #expect(wire.decode(idle) == [.turnFinished(TurnResult(outcome: .interrupted, sessionID: "s", costUSD: nil, text: nil))])
        _ = wire.decode(["type": "session.error", "properties": ["sessionID": "s", "error": ["name": "APIError", "data": ["message": "quota"]]]])
        #expect(wire.decode(idle) == [.turnFinished(TurnResult(outcome: .failed("quota"), sessionID: "s", costUSD: nil, text: nil))])
        #expect(wire.decode(idle) == [.turnFinished(TurnResult(outcome: .success, sessionID: "s", costUSD: nil, text: nil))])
    }

    @Test("modes become permission rules and an agent; models split into provider and id")
    func outbound() {
        #expect(OpenCodeProtocol.permission(for: .bypassPermissions) == [["permission": "*", "pattern": "*", "action": "allow"]])
        #expect(OpenCodeProtocol.permission(for: .ask).arrayValue?.first?["action"] == "ask")
        #expect(OpenCodeProtocol.permission(for: .acceptEdits).arrayValue?.first == ["permission": "edit", "pattern": "*", "action": "allow"])
        var wire = OpenCodeProtocol()
        wire.mode = .plan
        wire.model = "google/gemini-2.5-flash"
        let body = wire.prompt("go", images: [EngineImage(mediaType: "image/png", base64: "AAA")])
        #expect(body["agent"] == "plan")
        #expect(body["model"] == ["providerID": "google", "modelID": "gemini-2.5-flash"])
        #expect(body["parts"]?.arrayValue?.first?["url"] == "data:image/png;base64,AAA")
        #expect(body["parts"]?.arrayValue?.last == ["type": "text", "text": "go"])
        #expect(OpenCodeProtocol.answer(.allow) == ["reply": "once"])
        #expect(OpenCodeProtocol.answer(.allowAlways) == ["reply": "always"])
        #expect(OpenCodeProtocol.answer(.deny(reason: "no"))["reply"] == "reject")
    }

    @Test("a stored session reads back; listed sessions become OpenCode summaries")
    func stored() throws {
        let messages = try JSONValue.parse(
            #"[{"info":{"role":"user"},"parts":[{"type":"text","text":"fix it"}]},{"info":{"role":"assistant"},"parts":[{"type":"step-start"},{"type":"tool","tool":"edit","callID":"c","state":{"status":"completed","input":{"filePath":"/r/a.swift","oldString":"a","newString":"b"},"output":"ok"}},{"type":"text","text":"Done."}]}]"#)
        #expect(
            OpenCodeProtocol.transcript(messages) == [
                .user("fix it"),
                .assistant(.toolUse(id: "c", name: "Edit", input: ["file_path": "/r/a.swift", "old_string": "a", "new_string": "b"])),
                .toolResult(toolUseID: "c", content: "ok", isError: false),
                .assistant(.text("Done.")),
            ])
        let session = try JSONValue.parse(
            #"{"id":"ses_1","directory":"/work/app","title":"Draft the handoff","model":{"id":"gemini-2.5-flash","providerID":"google"},"time":{"created":1791364043037,"updated":1791364117498}}"#)
        let summary = try #require(OpenCodeProtocol.summary(session))
        #expect(summary.harness == .opencode && summary.projectPath == "/work/app" && summary.title == "Draft the handoff")
        #expect(summary.model == "google/gemini-2.5-flash")
        #expect(summary.lastActivity == Date(timeIntervalSince1970: 1_791_364_117.498))
        #expect(OpenCodeProtocol.summary(try JSONValue.parse(#"{"id":"ses_2","directory":"/w","parentID":"ses_1"}"#)) == nil, "subagent sessions stay out of the sidebar")
    }
}
