import Foundation

/// Claude Code's stream-json control protocol (`claude -p --input-format
/// stream-json --output-format stream-json --permission-prompt-tool stdio`):
/// what to send, and what each line it prints means. Pure — no process — so
/// recorded sessions replay through it in tests.
struct ClaudeProtocol {
    /// Control requests we sent and still await an answer to, by request id.
    enum Pending: Equatable {
        case initialize
        case permissionMode(PermissionMode)
        case model(String)
        /// `apply_flag_settings` with `effortLevel` — the session's `/effort`.
        case effort(String)
        case interrupt
    }

    private(set) var pending: [String: Pending] = [:]
    private var nextID = 0
    /// Set when we asked to interrupt, so the turn's error result reads as
    /// "interrupted" rather than a failure.
    private var interruptRequested = false

    static func arguments(for options: EngineStartOptions) -> [String] {
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--permission-prompt-tool", "stdio",
        ]
        if let model = options.model { arguments += ["--model", model] }
        if let mode = options.permissionMode { arguments += ["--permission-mode", mode.rawValue] }
        if let effort = options.effort { arguments += ["--effort", effort] }
        if let resume = options.resume {
            arguments += ["--resume", resume]
            if options.fork { arguments.append("--fork-session") }
        } else if let worktree = options.worktree {
            arguments += ["--worktree", worktree]
        }
        return arguments
    }

    // MARK: - Outbound

    static func userMessage(_ text: String, images: [EngineImage]) -> JSONValue {
        let content: JSONValue
        if images.isEmpty {
            content = .string(text)
        } else {
            let imageBlocks: [JSONValue] = images.map {
                [
                    "type": "image",
                    "source": ["type": "base64", "media_type": .string($0.mediaType), "data": .string($0.base64)],
                ]
            }
            content = .array(imageBlocks + [["type": "text", "text": .string(text)]])
        }
        return ["type": "user", "message": ["role": "user", "content": content]]
    }

    /// A control request, recorded as pending under a fresh id.
    mutating func control(_ kind: Pending) -> JSONValue {
        nextID += 1
        let id = "grimoire-\(nextID)"
        pending[id] = kind
        let request: JSONValue
        switch kind {
        case .initialize: request = ["subtype": "initialize"]
        case .permissionMode(let mode): request = ["subtype": "set_permission_mode", "mode": .string(mode.rawValue)]
        case .model(let model): request = ["subtype": "set_model", "model": .string(model)]
        case .effort(let effort):
            request = ["subtype": "apply_flag_settings", "settings": ["effortLevel": .string(effort)]]
        case .interrupt:
            interruptRequested = true
            request = ["subtype": "interrupt"]
        }
        return ["type": "control_request", "request_id": .string(id), "request": request]
    }

    static func answer(_ request: ApprovalRequest, with decision: ApprovalDecision) -> JSONValue {
        let response: JSONValue
        switch decision {
        case .allow:
            response = ["behavior": "allow", "updatedInput": request.input]
        case .allowAlways:
            response = [
                "behavior": "allow", "updatedInput": request.input, "updatedPermissions": .array(request.suggestions),
            ]
        case .deny(let reason):
            response = ["behavior": "deny", "message": .string(reason)]
        }
        return [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(request.id), "response": response],
        ]
    }

    // MARK: - Inbound

    /// The events one printed line stands for. Unknown message types are
    /// skipped (the CLI adds them over time); unparseable lines are an error.
    mutating func decode(_ line: String) -> [EngineEvent] {
        guard let message = try? JSONValue.parse(line) else {
            return [.error("Unreadable output: \(line.prefix(200))")]
        }
        switch message["type"]?.stringValue {
        case "system": return Self.system(message)
        case "stream_event": return Self.streamEvent(message)
        case "assistant": return Self.assistant(message)
        case "user": return Self.toolResults(message)
        case "control_request": return Self.controlRequest(message)
        case "control_response": return controlResponse(message)
        case "result": return [result(message)]
        case "rate_limit_event": return Self.usage(message).map { [.usage($0)] } ?? []
        default: return []
        }
    }

    private static func system(_ message: JSONValue) -> [EngineEvent] {
        switch message["subtype"]?.stringValue {
        case "init":
            return [
                .sessionStarted(
                    SessionInfo(
                        sessionID: message["session_id"]?.stringValue ?? "",
                        model: message["model"]?.stringValue ?? "",
                        permissionMode: message["permissionMode"]?.stringValue.flatMap(PermissionMode.init(rawValue:)),
                        workingDirectory: message["cwd"]?.stringValue ?? "",
                        tools: message["tools"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                        skills: (message["skills"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["name"]?.stringValue }))
            ]
        case "status":
            return [.status(message["status"]?.stringValue ?? "")]
        case "commands_changed":
            return [.commands(commands(message["commands"]))]
        default:
            return []
        }
    }

    private static func commands(_ value: JSONValue?) -> [SlashCommandInfo] {
        (value?.arrayValue ?? []).compactMap { command in
            guard let name = command["name"]?.stringValue else { return nil }
            return SlashCommandInfo(
                name: name, description: command["description"]?.stringValue ?? "",
                argumentHint: command["argumentHint"]?.stringValue ?? "")
        }
    }

    /// `rate_limit_info.unifiedWindows` → windows, shortest first.
    static func usage(_ message: JSONValue) -> [UsageWindow]? {
        guard case .object(let windows) = message["rate_limit_info"]?["unifiedWindows"] else { return nil }
        let names = ["five_hour": "5-hour", "seven_day": "7-day"]
        let known = ["five_hour", "seven_day"].filter { windows[$0] != nil }
        let others = windows.keys.filter { names[$0] == nil }.sorted()
        return (known + others).compactMap { key in
            guard let utilization = windows[key]?["utilization"]?.doubleValue else { return nil }
            return UsageWindow(
                name: names[key] ?? key.replacingOccurrences(of: "_", with: " "), utilization: utilization,
                resetsAt: windows[key]?["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) })
        }
    }

    private static func streamEvent(_ message: JSONValue) -> [EngineEvent] {
        guard let event = message["event"], event["type"]?.stringValue == "content_block_delta",
            event["delta"]?["type"]?.stringValue == "text_delta",
            let text = event["delta"]?["text"]?.stringValue
        else { return [] }
        return [.textDelta(messageID: message["api_message_id"]?.stringValue ?? "", text: text)]
    }

    private static func assistant(_ message: JSONValue) -> [EngineEvent] {
        let messageID = message["message"]?["id"]?.stringValue ?? ""
        let tokens = message["message"]?["usage"]?["output_tokens"]?.doubleValue.map {
            EngineEvent.tokens(messageID: messageID, output: Int($0))
        }
        return blocks(of: message["message"]).map { .block(messageID: messageID, $0) } + (tokens.map { [$0] } ?? [])
    }

    /// An assistant message's content blocks. Shared with stored sessions,
    /// which hold the same message shape.
    static func blocks(of message: JSONValue?) -> [AssistantBlock] {
        (message?["content"]?.arrayValue ?? []).compactMap { block in
            switch block["type"]?.stringValue {
            case "text":
                return .text(block["text"]?.stringValue ?? "")
            case "thinking":
                return .thinking(block["thinking"]?.stringValue ?? "")
            case "tool_use":
                return .toolUse(
                    id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "",
                    input: block["input"] ?? .null)
            default:
                return nil
            }
        }
    }

    private static func toolResults(_ message: JSONValue) -> [EngineEvent] {
        (message["message"]?["content"]?.arrayValue ?? []).compactMap { block in
            guard block["type"]?.stringValue == "tool_result", let id = block["tool_use_id"]?.stringValue else {
                return nil
            }
            return .toolResult(
                toolUseID: id, content: text(of: block["content"]), isError: block["is_error"]?.boolValue ?? false)
        }
    }

    /// A tool result's content is a string, or a list of blocks whose text parts count.
    static func text(of content: JSONValue?) -> String {
        if let string = content?.stringValue { return string }
        return (content?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    private static func controlRequest(_ message: JSONValue) -> [EngineEvent] {
        guard let request = message["request"], request["subtype"]?.stringValue == "can_use_tool",
            let id = message["request_id"]?.stringValue
        else { return [] }
        return [
            .approval(
                ApprovalRequest(
                    id: id, toolUseID: request["tool_use_id"]?.stringValue ?? "",
                    toolName: request["tool_name"]?.stringValue ?? "", input: request["input"] ?? .null,
                    summary: request["description"]?.stringValue ?? "",
                    suggestions: request["permission_suggestions"]?.arrayValue ?? []))
        ]
    }

    private mutating func controlResponse(_ message: JSONValue) -> [EngineEvent] {
        guard let response = message["response"], let id = response["request_id"]?.stringValue,
            let kind = pending.removeValue(forKey: id)
        else { return [] }
        if response["subtype"]?.stringValue == "error" {
            return [.error(response["error"]?.stringValue ?? "The CLI refused a control request.")]
        }
        switch kind {
        case .initialize: return [.commands(Self.commands(response["response"]?["commands"]))]
        case .permissionMode(let mode): return [.permissionModeChanged(mode)]
        case .model(let model): return [.modelChanged(model)]
        case .interrupt, .effort: return []
        }
    }

    private mutating func result(_ message: JSONValue) -> EngineEvent {
        let success = message["subtype"]?.stringValue == "success" && message["is_error"]?.boolValue != true
        let outcome: TurnOutcome
        if success {
            outcome = .success
        } else if interruptRequested {
            outcome = .interrupted
        } else {
            let errors = message["errors"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n")
            outcome = .failed(
                errors.flatMap { $0.isEmpty ? nil : $0 } ?? message["result"]?.stringValue ?? message["subtype"]?
                    .stringValue ?? "")
        }
        interruptRequested = false
        return .turnFinished(
            TurnResult(
                outcome: outcome, sessionID: message["session_id"]?.stringValue ?? "",
                costUSD: message["total_cost_usd"]?.doubleValue, text: message["result"]?.stringValue,
                outputTokens: message["usage"]?["output_tokens"]?.doubleValue.map { Int($0) }))
    }
}
