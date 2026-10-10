import Foundation
import Testing

@testable import GrimoireFeature

/// Replays a recorded `claude -p` stream-json session (sanitised) through the
/// protocol: an Edit that needs approval, then a model switch and a second turn.
@Suite("ClaudeProtocol")
struct ClaudeProtocolTests {
    /// Feeds the fixture through `ClaudeProtocol`. Our own control requests
    /// (`>` lines) are re-issued through `control(_:)`, and the CLI's answers
    /// are rewritten to the ids it hands out.
    private func replay(_ name: String) throws -> [EngineEvent] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).ndjson")
        var wire = ClaudeProtocol()
        var ids: [String: String] = [:]
        var events: [EngineEvent] = []
        for raw in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            var line = String(raw.dropFirst(2))
            if raw.hasPrefix(">") {
                let message = try JSONValue.parse(line)
                guard message["type"]?.stringValue == "control_request", let id = message["request_id"]?.stringValue
                else { continue }
                let request = message["request"]
                let kind: ClaudeProtocol.Pending =
                    switch request?["subtype"]?.stringValue {
                    case "set_model": .model(request?["model"]?.stringValue ?? "")
                    case "set_permission_mode":
                        .permissionMode(PermissionMode(rawValue: request?["mode"]?.stringValue ?? "") ?? .ask)
                    case "interrupt": .interrupt
                    default: .initialize
                    }
                ids[id] = wire.control(kind)["request_id"]?.stringValue
                continue
            }
            for (recorded, issued) in ids {
                line = line.replacingOccurrences(
                    of: "\"request_id\": \"\(recorded)\"", with: "\"request_id\": \"\(issued)\"")
            }
            events += wire.decode(line)
        }
        return events
    }

    @Test("a recorded session decodes into the events the UI needs, with no errors")
    func recordedSession() throws {
        let events = try replay("claude-edit-model")

        let sessions = events.compactMap { if case .sessionStarted(let info) = $0 { info } else { nil } }
        #expect(sessions.count == 2)
        #expect(sessions.first?.model == "claude-haiku-5-5")
        #expect(sessions.first?.permissionMode == .ask)
        #expect(sessions.first?.workingDirectory == "/tmp/work")

        let commands = events.compactMap { if case .commands(let list) = $0 { list } else { nil } }
        #expect(commands.first?.map(\.name) == ["review", "clear"])

        let approvals = events.compactMap { if case .approval(let request) = $0 { request } else { nil } }
        #expect(approvals.count == 1)
        #expect(approvals.first?.toolName == "Edit")
        #expect(approvals.first?.summary == "notes.txt")
        #expect(approvals.first?.input["new_string"]?.stringValue == "hello there")
        #expect(approvals.first?.suggestions.first?["mode"]?.stringValue == "acceptEdits")

        let toolUses = events.compactMap { event -> String? in
            if case .block(_, .toolUse(_, let name, _)) = event { return name }
            return nil
        }
        #expect(toolUses == ["Read", "Edit"])

        let results = events.compactMap {
            if case .toolResult(let id, _, let isError) = $0 { (id, isError) } else { nil }
        }
        #expect(results.count == 2)
        #expect(results.allSatisfy { !$0.1 })

        let streamed = events.compactMap { if case .textDelta(_, let text) = $0 { text } else { nil } }.joined()
        #expect(streamed.contains("DONE"))

        #expect(events.contains(.modelChanged("sonnet")))
        let turns = events.compactMap { if case .turnFinished(let result) = $0 { result } else { nil } }
        #expect(turns.map(\.outcome) == [.success, .success])
        #expect(turns.allSatisfy { ($0.costUSD ?? 0) > 0 })
        #expect(!events.contains { if case .error = $0 { true } else { false } })
    }

    @Test("start arguments carry model, mode, resume and fork")
    func arguments() {
        let base = ClaudeProtocol.arguments(for: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/tmp")))
        #expect(base.contains("--permission-prompt-tool"))
        #expect(!base.contains("--resume"))

        let full = ClaudeProtocol.arguments(
            for: EngineStartOptions(
                workingDirectory: URL(fileURLWithPath: "/tmp"), model: "opus", permissionMode: .plan, resume: "abc",
                fork: true))
        #expect(
            full.suffix(7) == ["--model", "opus", "--permission-mode", "plan", "--resume", "abc", "--fork-session"])

        let noFork = ClaudeProtocol.arguments(
            for: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/tmp"), fork: true))
        #expect(!noFork.contains("--fork-session"))
    }

    @Test("a user message is plain text, or image blocks followed by the text")
    func userMessage() {
        #expect(ClaudeProtocol.userMessage("hi", images: [])["message"]?["content"] == "hi")
        let content = ClaudeProtocol.userMessage("look", images: [EngineImage(mediaType: "image/png", base64: "AAA")])[
            "message"]?["content"]?.arrayValue
        #expect(content?.first?["source"]?["media_type"] == "image/png")
        #expect(content?.last == ["type": "text", "text": "look"])
    }

    @Test("approvals echo the request id; always-allow adopts the CLI's suggestions")
    func answers() {
        let request = ApprovalRequest(
            id: "r1", toolUseID: "t1", toolName: "Edit", input: ["file_path": "/a"], summary: "a",
            suggestions: [["type": "setMode", "mode": "acceptEdits", "destination": "session"]])

        let allow = ClaudeProtocol.answer(request, with: .allow)["response"]
        #expect(allow?["request_id"] == "r1")
        #expect(allow?["response"]?["behavior"] == "allow")
        #expect(allow?["response"]?["updatedInput"] == ["file_path": "/a"])
        #expect(allow?["response"]?["updatedPermissions"] == nil)

        let always = ClaudeProtocol.answer(request, with: .allowAlways)["response"]?["response"]
        #expect(always?["updatedPermissions"]?.arrayValue == request.suggestions)

        let deny = ClaudeProtocol.answer(request, with: .deny(reason: "not now"))["response"]?["response"]
        #expect(deny == ["behavior": "deny", "message": "not now"])
    }

    @Test("a failed turn after an interrupt is 'interrupted'; otherwise it carries the error")
    func interruptOutcome() {
        let failed =
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s","errors":["boom"]}"#

        var wire = ClaudeProtocol()
        #expect(wire.decode(failed) == [.turnFinished(TurnResult(outcome: .failed("boom"), sessionID: "s"))])

        _ = wire.control(.interrupt)
        #expect(wire.decode(failed) == [.turnFinished(TurnResult(outcome: .interrupted, sessionID: "s"))])
        // The flag is per turn: the next failure is a failure again.
        #expect(wire.decode(failed) == [.turnFinished(TurnResult(outcome: .failed("boom"), sessionID: "s"))])
    }

    @Test("control answers resolve their pending request; errors surface")
    func controlResponses() {
        var wire = ClaudeProtocol()
        let id = wire.control(.permissionMode(.plan))["request_id"]?.stringValue ?? ""
        #expect(
            wire.decode(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)"}}"#)
                == [.permissionModeChanged(.plan)])
        #expect(wire.pending.isEmpty)

        let model = wire.control(.model("nope"))["request_id"]?.stringValue ?? ""
        #expect(
            wire.decode(
                #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(model)","error":"bad model"}}"#
            )
                == [.error("bad model")])
        // An answer to a request we never sent is ignored.
        #expect(wire.decode(#"{"type":"control_response","response":{"subtype":"success","request_id":"x"}}"#) == [])
    }

    @Test("unknown message types are skipped; garbage is an error")
    func unknownAndGarbage() {
        var wire = ClaudeProtocol()
        #expect(wire.decode(#"{"type":"rate_limit_event"}"#) == [])
        #expect(wire.decode(#"{"type":"something_new","x":1}"#) == [])
        #expect(wire.decode("not json").count == 1)
    }
}

extension TurnResult {
    fileprivate init(outcome: TurnOutcome, sessionID: String) {
        self.init(outcome: outcome, sessionID: sessionID, costUSD: nil, text: nil)
    }
}
