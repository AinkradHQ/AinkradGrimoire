import Foundation
import Testing

@testable import GrimoireFeature

/// Messages shaped exactly as `codex app-server` 0.154.0 sends them — taken
/// from a recorded session and from real stored threads, paths sanitised.
@Suite("CodexProtocol")
struct CodexProtocolTests {
    private func started() -> CodexProtocol {
        var wire = CodexProtocol()
        _ = wire.initialize()
        _ = wire.startThread(EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo"), permissionMode: .ask))
        _ = wire.decode(#"{"id":2,"result":{"thread":{"id":"t1","cwd":"/repo"},"model":"gpt-5.6-luna","cwd":"/repo","approvalPolicy":"untrusted","sandbox":{"type":"workspaceWrite"}}}"#)
        return wire
    }

    @Test("start: initialize, then thread/start with Ask's policy and sandbox; the response starts the session")
    func start() {
        var wire = CodexProtocol()
        #expect(wire.initialize()["method"] == "initialize")
        let request = wire.startThread(
            EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo"), model: "gpt-5", permissionMode: .ask))
        #expect(request["method"] == "thread/start")
        #expect(request["params"]?["approvalPolicy"] == "untrusted")
        #expect(request["params"]?["sandbox"] == "workspace-write")
        #expect(request["params"]?["model"] == "gpt-5")
        let (events, reply) = wire.decode(
            #"{"id":2,"result":{"thread":{"id":"t1","cwd":"/repo"},"model":"gpt-5","cwd":"/repo","approvalPolicy":"untrusted","sandbox":{"type":"workspaceWrite"}}}"#)
        #expect(reply == nil)
        #expect(
            events == [
                .sessionStarted(
                    SessionInfo(sessionID: "t1", model: "gpt-5", permissionMode: .ask, workingDirectory: "/repo", tools: []))
            ])
        #expect(wire.threadID == "t1")
    }

    @Test("resume and fork name the stored thread")
    func resumeAndFork() {
        var wire = CodexProtocol()
        let resume = wire.startThread(EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/r"), resume: "old"))
        #expect(resume["method"] == "thread/resume" && resume["params"]?["threadId"] == "old")
        let fork = wire.startThread(EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/r"), resume: "old", fork: true))
        #expect(fork["method"] == "thread/fork")
    }

    @Test("a turn needs a thread; it carries text, images, mode and model")
    func turn() {
        var empty = CodexProtocol()
        #expect(empty.turn("hi", images: []) == nil)
        var wire = started()
        wire.mode = .plan
        wire.model = "gpt-5"
        let turn = wire.turn("look", images: [EngineImage(mediaType: "image/png", base64: "AAA")])
        let input = turn?["params"]?["input"]?.arrayValue
        #expect(turn?["method"] == "turn/start")
        #expect(input?.first?["url"] == "data:image/png;base64,AAA")
        #expect(input?.last?["text"] == "look")
        #expect(turn?["params"]?["approvalPolicy"] == "on-request")
        #expect(turn?["params"]?["sandboxPolicy"]?["type"] == "readOnly")
        #expect(turn?["params"]?["model"] == "gpt-5")
    }

    @Test("items stream into text, tool cards with results, thinking and a plan")
    func items() {
        var wire = started()
        func events(_ line: String) -> [EngineEvent] { wire.decode(line).events }

        #expect(events(#"{"method":"turn/started","params":{"threadId":"t1","turn":{"id":"u1","items":[],"status":"inProgress"}}}"#) == [.status("working")])
        #expect(wire.turnID == "u1")
        #expect(
            events(#"{"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"u1","itemId":"m1","delta":"Hel"}}"#)
                == [.textDelta(messageID: "m1", text: "Hel")])
        #expect(
            events(#"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m1","text":"Hello","phase":"final_answer"},"threadId":"t1","turnId":"u1"}}"#)
                == [.block(messageID: "m1", .text("Hello"))])
        #expect(
            events(#"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"c1","command":"/bin/zsh -lc 'make test'","cwd":"/repo","status":"inProgress","aggregatedOutput":null,"exitCode":null},"threadId":"t1","turnId":"u1"}}"#)
                == [.block(messageID: "c1", .toolUse(id: "c1", name: "Bash", input: ["command": "/bin/zsh -lc 'make test'"]))])
        #expect(
            events(#"{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"c1","command":"make test","status":"completed","aggregatedOutput":"ok\n","exitCode":1},"threadId":"t1","turnId":"u1"}}"#)
                == [.toolResult(toolUseID: "c1", content: "ok\n", isError: true)])
        let patch = events(#"{"method":"item/started","params":{"item":{"type":"fileChange","id":"f1","changes":[{"path":"/repo/A.md","kind":{"type":"update","move_path":null},"diff":"@@ -1 +1 @@\n-a\n+b"}],"status":"inProgress"},"threadId":"t1","turnId":"u1"}}"#)
        guard case .block(_, .toolUse(_, "Patch", let input)) = patch.first else {
            Issue.record("a file change is a Patch card")
            return
        }
        #expect(input["changes"]?.arrayValue?.first?["path"] == "/repo/A.md")
        #expect(
            events(#"{"method":"item/completed","params":{"item":{"type":"reasoning","id":"r1","summary":["Checking the tests"],"content":[]},"threadId":"t1","turnId":"u1"}}"#)
                == [.block(messageID: "r1", .thinking("Checking the tests"))])
        #expect(events(#"{"method":"item/completed","params":{"item":{"type":"reasoning","id":"r2","summary":[],"content":[]},"threadId":"t1","turnId":"u1"}}"#) == [])
        let plan = events(#"{"method":"turn/plan/updated","params":{"threadId":"t1","turnId":"u1","explanation":null,"plan":[{"step":"Read","status":"completed"},{"step":"Fix","status":"inProgress"}]}}"#)
        guard case .block(_, .toolUse("plan-u1", "TodoWrite", let todos)) = plan.first else {
            Issue.record("a plan update is a TodoWrite with a per-turn id")
            return
        }
        #expect(ThreadEntries.plan(from: todos) == [PlanStep(title: "Read", status: .completed), PlanStep(title: "Fix", status: .inProgress)])
    }

    @Test("approvals become requests; answers echo the JSON-RPC id with Codex's decisions")
    func approvals() {
        var wire = started()
        let (events, reply) = wire.decode(
            #"{"method":"item/commandExecution/requestApproval","id":7,"params":{"kind":"command","threadId":"t1","turnId":"u1","itemId":"c9","startedAtMs":1,"environmentId":null,"reason":"needs network","command":"git push","cwd":"/repo"}}"#)
        #expect(reply == nil)
        guard case .approval(let request) = events.first else {
            Issue.record("expected an approval")
            return
        }
        #expect(request.id == "7" && request.toolName == "Bash" && request.toolUseID == "c9")
        #expect(request.input["command"] == "git push")
        #expect(request.summary == "needs network")
        #expect(!request.suggestions.isEmpty, "Codex can always accept for the session")
        #expect(wire.answer(request, with: .allow) == ["jsonrpc": "2.0", "id": .number(7), "result": ["decision": "accept"]])
        #expect(wire.answer(request, with: .allowAlways)["result"]?["decision"] == "acceptForSession")
        #expect(wire.answer(request, with: .deny(reason: "no"))["result"]?["decision"] == "decline")

        let file = wire.decode(#"{"method":"item/fileChange/requestApproval","id":"abc","params":{"threadId":"t1","turnId":"u1","itemId":"f9","startedAtMs":1}}"#)
        guard case .approval(let fileRequest) = file.events.first else {
            Issue.record("expected a file approval")
            return
        }
        #expect(fileRequest.toolName == "Patch")
        #expect(wire.answer(fileRequest, with: .allow)["id"] == "abc")
    }

    @Test("a server request Grimoire can't answer is refused, so the turn doesn't hang")
    func unsupportedRequest() {
        var wire = started()
        let (events, reply) = wire.decode(#"{"method":"item/tool/requestUserInput","id":9,"params":{}}"#)
        #expect(events.isEmpty)
        #expect(reply?["id"] == .number(9))
        #expect(reply?["error"]?["code"] == .number(-32601))
    }

    @Test("turn outcomes: completed, interrupted, and the real usage-limit failure")
    func outcomes() {
        var wire = started()
        func outcome(_ status: String, error: String = "null") -> TurnOutcome? {
            let line = #"{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"u1","items":[],"status":"\#(status)","error":\#(error)}}}"#
            guard case .turnFinished(let result) = wire.decode(line).events.first else { return nil }
            return result.outcome
        }
        #expect(outcome("completed") == .success)
        #expect(outcome("interrupted") == .interrupted)
        #expect(
            outcome("failed", error: #"{"message":"You've hit your usage limit. Upgrade to Plus to continue using Codex.","codexErrorInfo":"usageLimitExceeded"}"#)
                == .failed("You've hit your usage limit. Upgrade to Plus to continue using Codex."))
        #expect(wire.decode(#"{"method":"error","params":{"error":{"message":"retrying"},"willRetry":true,"threadId":"t1","turnId":"u1"}}"#).events == [])
    }

    @Test("interrupt needs the running turn")
    func interrupt() {
        var wire = started()
        #expect(wire.interrupt() == nil)
        _ = wire.decode(#"{"method":"turn/started","params":{"threadId":"t1","turn":{"id":"u1"}}}"#)
        #expect(wire.interrupt()?["params"] == ["threadId": "t1", "turnId": "u1"])
    }

    @Test("rate limits become usage windows")
    func usage() {
        var wire = started()
        let events = wire.decode(
            #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1791700000},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":null}}}}"#
        ).events
        #expect(
            events == [
                .usage([
                    UsageWindow(name: "5-hour", utilization: 0.4, resetsAt: Date(timeIntervalSince1970: 1_791_700_000)),
                    UsageWindow(name: "7-day", utilization: 0.1, resetsAt: nil),
                ])
            ])
    }

    @Test("a stored thread reads back as prompts, text, tool calls and results")
    func transcript() throws {
        let thread = try JSONValue.parse(
            #"{"turns":[{"items":[{"type":"userMessage","id":"u","content":[{"type":"text","text":"review the folder","text_elements":[]}]},{"type":"reasoning","id":"r","summary":[],"content":[]},{"type":"commandExecution","id":"c","command":"ls","status":"completed","aggregatedOutput":"a\nb","exitCode":0},{"type":"agentMessage","id":"m","text":"Two files."}]}]}"#)
        #expect(
            CodexProtocol.transcript(thread) == [
                .user("review the folder"),
                .assistant(.toolUse(id: "c", name: "Bash", input: ["command": "ls"])),
                .toolResult(toolUseID: "c", content: "a\nb", isError: false),
                .assistant(.text("Two files.")),
            ])
    }

    @Test("a listed thread becomes a Codex summary")
    func summary() throws {
        let thread = try JSONValue.parse(
            #"{"id":"t1","cwd":"/work/app","preview":"review all the project folder content","name":"Review project","model":"gpt-5.6-luna","updatedAt":1789483319,"path":"/x/rollout.jsonl","gitInfo":{"branch":"main"}}"#)
        let summary = try #require(CodexSessions.summary(thread))
        #expect(summary.harness == .codex)
        #expect(summary.title == "Review project")
        #expect(summary.projectPath == "/work/app")
        #expect(summary.gitBranch == "main")
        #expect(summary.lastActivity == Date(timeIntervalSince1970: 1_789_483_319))
    }

    @Test("a Patch is one change per file: hunks for an update, the whole file for an add or delete")
    func patch() {
        let input: JSONValue = [
            "changes": [
                ["path": "/repo/A.md", "kind": ["type": "update"], "diff": "@@ -1,2 +1,2 @@\n keep\n-old\n+new"],
                ["path": "/repo/B.md", "kind": ["type": "add"], "diff": "one\ntwo"],
                ["path": "/repo/C.md", "kind": ["type": "delete"], "diff": "gone"],
            ]
        ]
        let changes = ReviewChanges.patchChanges(input)
        #expect(changes.map(\.status) == [.modified, .added, .deleted])
        #expect(changes[0].diff?.hunks.first?.lines.map(\.kind) == [.context, .deletion, .insertion])
        #expect(ToolSummary.argument(name: "Patch", input: input, workingDirectory: "/repo") == "A.md +2 more")
        #expect(ToolSummary.result(name: "Patch", input: input, output: ToolOutput(content: "", isError: false)) == "+3 −2")

        let call = ToolCall(id: "f1", name: "Patch", input: input, result: ToolOutput(content: "", isError: false))
        let review = ReviewChanges.fromEntries([.tool(call)], scope: .thread, workingDirectory: "/repo")
        #expect(review.map(\.path) == ["A.md", "B.md", "C.md"])
        #expect(review.map(\.status) == [.modified, .added, .deleted])
    }
}
