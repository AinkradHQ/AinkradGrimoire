import Foundation

/// agy's print-mode stream (`agy --input-format stream-json --output-format
/// stream-json -p=`): one `{"event": "user", …}` line per turn in, `init`,
/// `step_update` and `result` lines out. Pure, so recorded lines replay in tests.
///
/// agy exposes no approvals here: its own `toolPermission` setting decides
/// what runs, and Grimoire's mode maps to `--mode` / the skip flag at spawn.
struct AgyProtocol {
    var conversationID: String?
    var mode: PermissionMode = .ask
    var model: String?
    var effort: String?
    /// Streamed text per response step, sent whole when the step is done.
    private var text: [Int: String] = [:]
    private var shownTools: Set<Int> = []

    /// The command line for the current conversation, mode and model. `-p=`
    /// goes last: agy's `-p` takes the next argument as its prompt.
    func arguments() -> [String] {
        var arguments = ["--input-format", "stream-json", "--output-format", "stream-json"]
        if let conversationID { arguments += ["--conversation", conversationID] }
        if let model { arguments += ["--model", model] }
        if let effort { arguments += ["--effort", effort] }
        switch mode {
        case .ask: break
        case .acceptEdits: arguments += ["--mode", "accept-edits"]
        case .plan: arguments += ["--mode", "plan"]
        case .bypassPermissions: arguments.append("--dangerously-skip-permissions")
        }
        return arguments + ["-p="]
    }

    static func message(_ text: String) -> JSONValue {
        ["event": "user", "message": ["role": "user", "content": .string(text)]]
    }

    mutating func decode(_ line: String) -> [EngineEvent] {
        guard let message = try? JSONValue.parse(line) else { return [] }
        switch message["event"]?.stringValue {
        case "init":
            conversationID = message["conversation_id"]?.stringValue ?? conversationID
            return [
                .sessionStarted(
                    SessionInfo(
                        sessionID: conversationID ?? "", model: model ?? "", permissionMode: mode,
                        workingDirectory: message["init"]?["cwd"]?.stringValue ?? "", tools: []))
            ]
        case "step_update":
            return step(message["step_update"] ?? .null)
        case "result":
            let result = message["result"] ?? .null
            text = [:]
            let outcome: TurnOutcome =
                switch result["status"]?.stringValue {
                case "SUCCESS": .success
                case "CANCELLED", "CANCELED": .interrupted
                default: .failed(result["error"]?.stringValue ?? "agy failed")
                }
            return [
                .turnFinished(
                    TurnResult(
                        outcome: outcome, sessionID: result["conversation_id"]?.stringValue ?? conversationID ?? "",
                        costUSD: nil, text: result["response"]?.stringValue))
            ]
        default:
            return []
        }
    }

    private mutating func step(_ step: JSONValue) -> [EngineEvent] {
        guard let index = step["step_index"]?.doubleValue.map(Int.init) else { return [] }
        let id = "step-\(index)"
        let done = step["state"] == "DONE"
        switch step["step_type"]?.stringValue {
        case "agent_response":
            var events: [EngineEvent] = []
            if let delta = step["text_delta"]?.stringValue, !delta.isEmpty {
                text[index, default: ""] += delta
                events.append(.textDelta(messageID: id, text: delta))
            }
            if done, let whole = text.removeValue(forKey: index) { events.append(.block(messageID: id, .text(whole))) }
            return events
        case "tool":
            let info = step["tool_info"] ?? .null
            var events: [EngineEvent] = []
            if !shownTools.contains(index) {
                shownTools.insert(index)
                let (name, input) = Self.tool(info["name"]?.stringValue ?? "tool", info["parameters"] ?? [:])
                events.append(.block(messageID: id, .toolUse(id: id, name: name, input: input)))
            }
            if done {
                events.append(.toolResult(toolUseID: id, content: info["output"]?.stringValue ?? "", isError: false))
            } else if step["state"] != "ACTIVE" {
                events.append(.toolResult(toolUseID: id, content: step["error"]?.stringValue ?? "failed", isError: true))
            }
            return events
        default:
            return []
        }
    }

    /// agy's tools under the names (and input keys) the cards know.
    static func tool(_ name: String, _ parameters: JSONValue) -> (name: String, input: JSONValue) {
        switch name {
        case "run_command": ("Bash", ["command": parameters["CommandLine"] ?? ""])
        case "view_file": ("Read", ["file_path": parameters["AbsolutePath"] ?? .null])
        case "write_to_file":
            ("Write", ["file_path": parameters["TargetFile"] ?? .null, "content": parameters["CodeContent"] ?? ""])
        // The stream carries no strings for an edit, only the file.
        case "replace_file_content", "multi_replace_file_content": ("Update", ["file_path": parameters["TargetFile"] ?? .null])
        default: (name, parameters)
        }
    }
}
