import Foundation

/// OpenCode's server protocol (`opencode serve`: HTTP for requests, one
/// server-sent `/event` stream for everything that happens) — what to send,
/// and what each event means. Pure, like `CodexProtocol`, so recorded events
/// replay through it in tests.
///
/// A turn is a prompt; the reply arrives as message parts (`text`,
/// `reasoning`, `tool`) that update in place until they end. Approvals are
/// `permission.asked` events answered over HTTP; `session.idle` ends the turn.
struct OpenCodeProtocol {
    /// The session the engine is on; events for other sessions are ignored.
    var sessionID: String?
    /// Mode applies to the session (its permission rules) and the next prompt (its agent).
    var mode: PermissionMode = .ask
    /// `provider/model`; nil uses OpenCode's configured default.
    var model: String?
    /// What each streaming part is, so a delta knows whether it's text.
    private var partKinds: [String: String] = [:]
    /// Messages the user sent: their parts echo the prompt and are not shown again.
    private var userMessages: Set<String> = []
    /// Tool calls already shown as cards, so later updates only add results.
    private var shownTools: Set<String> = []
    /// Why the turn is ending, reported when `session.idle` arrives.
    private var ending: TurnOutcome?

    // MARK: - Outbound

    /// The session's permission rules for `mode`, layered over the user's own config.
    static func permission(for mode: PermissionMode) -> JSONValue {
        func rule(_ permission: String, _ action: String) -> JSONValue {
            ["permission": .string(permission), "pattern": "*", "action": .string(action)]
        }
        switch mode {
        case .ask: return [rule("edit", "ask"), rule("bash", "ask"), rule("webfetch", "ask")]
        case .acceptEdits, .plan: return [rule("edit", "allow"), rule("bash", "ask"), rule("webfetch", "ask")]
        case .bypassPermissions: return [rule("*", "allow")]
        }
    }

    /// Plan mode is OpenCode's read-only `plan` agent; everything else `build`.
    static func agent(for mode: PermissionMode) -> String { mode == .plan ? "plan" : "build" }

    func prompt(_ text: String, images: [EngineImage]) -> JSONValue {
        var parts: [JSONValue] = images.map { image in
            ["type": "file", "mime": .string(image.mediaType), "url": .string("data:\(image.mediaType);base64,\(image.base64)")]
        }
        parts.append(["type": "text", "text": .string(text)])
        var body: [String: JSONValue] = ["parts": .array(parts), "agent": .string(Self.agent(for: mode))]
        if let model, let slash = model.firstIndex(of: "/") {
            body["model"] = [
                "providerID": .string(String(model[..<slash])), "modelID": .string(String(model[model.index(after: slash)...])),
            ]
        }
        return .object(body)
    }

    /// OpenCode's error, plus what to do when it is one the user can fix here. "Default" is the model in the
    /// user's own OpenCode config, which may name one OpenCode can't reach (E0 GD7).
    static func explain(_ message: String) -> String {
        guard message.contains("ModelNotFound") || message.localizedCaseInsensitiveContains("model not found") else { return message }
        return "\(message)\nPick another model in the Model menu below — Default is the one in your OpenCode config."
    }

    static func answer(_ decision: ApprovalDecision) -> JSONValue {
        switch decision {
        case .allow: ["reply": "once"]
        case .allowAlways: ["reply": "always"]
        case .deny(let reason): ["reply": "reject", "message": .string(reason)]
        }
    }

    // MARK: - Inbound

    /// One `/event` message (`{type, properties}`) as engine events.
    mutating func decode(_ event: JSONValue) -> [EngineEvent] {
        let properties = event["properties"] ?? .null
        guard let sessionID, properties["sessionID"]?.stringValue == sessionID else { return [] }
        switch event["type"]?.stringValue {
        case "message.updated":
            let info = properties["info"] ?? .null
            if info["role"] == "user", let id = info["id"]?.stringValue { userMessages.insert(id) }
            return []
        case "message.part.updated":
            return part(properties["part"] ?? .null)
        case "message.part.delta":
            guard let id = properties["partID"]?.stringValue, partKinds[id] == "text",
                properties["field"] == "text", let delta = properties["delta"]?.stringValue
            else { return [] }
            return [.textDelta(messageID: id, text: delta)]
        case "permission.asked":
            return [.approval(Self.approval(properties))]
        case "session.status":
            if properties["status"]?["type"] == "retry" {
                return [.status("retrying: \(properties["status"]?["message"]?.stringValue ?? "")")]
            }
            guard properties["status"]?["type"] == "busy" else { return [] }
            // A turn starts. OpenCode repeats a failed turn's error after its `session.idle`; left set, that
            // stale error would fail the next turn too (GD8).
            ending = nil
            return [.status("working")]
        case "session.error":
            let error = properties["error"] ?? .null
            ending =
                error["name"] == "MessageAbortedError"
                ? .interrupted
                : .failed(Self.explain(error["data"]?["message"]?.stringValue ?? error["name"]?.stringValue ?? "OpenCode failed"))
            return []
        case "session.idle":
            defer { ending = nil }
            return [.turnFinished(TurnResult(outcome: ending ?? .success, sessionID: sessionID, costUSD: nil, text: nil))]
        default:
            return []
        }
    }

    private mutating func part(_ part: JSONValue) -> [EngineEvent] {
        guard let id = part["id"]?.stringValue, let type = part["type"]?.stringValue,
            !userMessages.contains(part["messageID"]?.stringValue ?? "")
        else { return [] }
        partKinds[id] = type
        let ended = part["time"]?["end"] != nil
        switch type {
        case "text" where ended:
            return [.block(messageID: id, .text(part["text"]?.stringValue ?? ""))]
        case "reasoning" where ended:
            let text = part["text"]?.stringValue ?? ""
            return text.isEmpty ? [] : [.block(messageID: id, .thinking(text))]
        case "tool":
            let state = part["state"] ?? .null
            let status = state["status"]?.stringValue
            guard status != "pending", let callID = part["callID"]?.stringValue else { return [] }
            var events: [EngineEvent] = []
            let (name, input) = Self.tool(part)
            // A todo list is the plan: every update replaces it.
            if name == "TodoWrite" || !shownTools.contains(callID) {
                shownTools.insert(callID)
                events.append(.block(messageID: callID, .toolUse(id: callID, name: name, input: input)))
            }
            if status == "completed" {
                events.append(.toolResult(toolUseID: callID, content: state["output"]?.stringValue ?? "", isError: false))
            } else if status == "error" {
                events.append(.toolResult(toolUseID: callID, content: state["error"]?.stringValue ?? "", isError: true))
            }
            return events
        default:
            return []
        }
    }

    /// OpenCode's tools under the names (and input keys) the cards know.
    static func tool(_ part: JSONValue) -> (name: String, input: JSONValue) {
        let input = part["state"]?["input"] ?? [:]
        let path = input["filePath"] ?? .null
        switch part["tool"]?.stringValue ?? "" {
        case "bash": return ("Bash", ["command": input["command"] ?? ""])
        case "read": return ("Read", ["file_path": path])
        case "write": return ("Write", ["file_path": path, "content": input["content"] ?? ""])
        case "edit":
            return ("Edit", ["file_path": path, "old_string": input["oldString"] ?? "", "new_string": input["newString"] ?? ""])
        case "grep": return ("Grep", ["pattern": input["pattern"] ?? "", "path": input["path"] ?? .null])
        case "glob": return ("Glob", ["pattern": input["pattern"] ?? ""])
        case "webfetch": return ("WebFetch", ["url": input["url"] ?? ""])
        case "todowrite": return ("TodoWrite", ["todos": input["todos"] ?? []])
        case "task": return ("Task", ["description": input["description"] ?? ""])
        case let other: return (other, input)
        }
    }

    /// `bash` → a Bash approval showing the command; `edit` → an Edit showing the diff.
    static func approval(_ properties: JSONValue) -> ApprovalRequest {
        let metadata = properties["metadata"] ?? .null
        let patterns = (properties["patterns"]?.arrayValue ?? []).compactMap(\.stringValue)
        let (name, input): (String, JSONValue) =
            switch properties["permission"]?.stringValue ?? "" {
            case "bash": ("Bash", ["command": metadata["command"] ?? .string(patterns.joined(separator: " "))])
            case "edit": ("Edit", ["file_path": metadata["filepath"] ?? .null, "diff": metadata["diff"] ?? .null])
            case "webfetch": ("WebFetch", ["url": metadata["url"] ?? .string(patterns.first ?? "")])
            // A tool reaching outside the project folder.
            case "external_directory": ("Outside folder", ["path": metadata["filepath"] ?? .string(patterns.first ?? "")])
            case let other: (other, metadata)
            }
        let always = properties["always"]?.arrayValue ?? []
        return ApprovalRequest(
            id: properties["id"]?.stringValue ?? "", toolUseID: properties["tool"]?["callID"]?.stringValue ?? "",
            toolName: name, input: input, summary: patterns.joined(separator: ", "),
            suggestions: always.isEmpty ? [] : [["always": .array(always)]])
    }

    // MARK: - Stored sessions

    /// `GET /session/{id}/message` (`[{info, parts}]`) as transcript rows.
    static func transcript(_ messages: JSONValue) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        for message in messages.arrayValue ?? [] {
            let parts = message["parts"]?.arrayValue ?? []
            if message["info"]?["role"] == "user" {
                let text = parts.filter { $0["type"] == "text" && $0["synthetic"] != true }
                    .compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                if !text.isEmpty { items.append(.user(text)) }
                continue
            }
            for part in parts {
                switch part["type"]?.stringValue {
                case "text":
                    if let text = part["text"]?.stringValue, !text.isEmpty { items.append(.assistant(.text(text))) }
                case "tool":
                    guard let callID = part["callID"]?.stringValue else { continue }
                    let (name, input) = tool(part)
                    items.append(.assistant(.toolUse(id: callID, name: name, input: input)))
                    let state = part["state"] ?? .null
                    if state["status"] == "completed" {
                        items.append(.toolResult(toolUseID: callID, content: state["output"]?.stringValue ?? "", isError: false))
                    } else if state["status"] == "error" {
                        items.append(.toolResult(toolUseID: callID, content: state["error"]?.stringValue ?? "", isError: true))
                    }
                default:
                    continue
                }
            }
        }
        return items
    }

    /// One `GET /session` entry as a sidebar summary.
    static func summary(_ session: JSONValue) -> ClaudeSessionSummary? {
        guard let id = session["id"]?.stringValue, let directory = session["directory"]?.stringValue,
            session["parentID"] == nil
        else { return nil }
        let (project, worktree) = ClaudeSessions.splitWorktree(directory)
        let model = session["model"].flatMap { model -> String? in
            guard let provider = model["providerID"]?.stringValue, let id = model["id"]?.stringValue else { return nil }
            return "\(provider)/\(id)"
        }
        let title = session["title"]?.stringValue ?? ""
        return ClaudeSessionSummary(
            id: id, harness: .opencode, fileURL: URL(fileURLWithPath: "/dev/null"), workingDirectory: directory,
            projectPath: project, worktree: worktree, title: title.isEmpty ? "Untitled" : ClaudeSessionSummary.title(title),
            model: model,
            lastActivity: Date(timeIntervalSince1970: (session["time"]?["updated"]?.doubleValue ?? 0) / 1000))
    }
}
