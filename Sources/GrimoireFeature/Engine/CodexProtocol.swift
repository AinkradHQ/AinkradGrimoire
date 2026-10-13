import Foundation

/// Codex's app-server protocol (`codex app-server`: JSON-RPC 2.0, one message
/// per line on stdin/stdout) — what to send, and what each line means. Pure,
/// like `ClaudeProtocol`, so recorded traffic replays through it in tests.
///
/// Codex speaks in threads, turns and items. A turn's items arrive as
/// `item/started` → deltas → `item/completed`; approvals arrive as server
/// *requests* that must be answered; the turn ends with `turn/completed`.
struct CodexProtocol {
    /// Requests we sent and still await a response to, by JSON-RPC id.
    enum Pending: Equatable {
        case initialize
        /// thread/start, thread/resume or thread/fork — answered with the thread.
        case thread
        case turnStart
        case interrupt
        case steer
    }

    private(set) var pending: [Int: Pending] = [:]
    private var nextID = 0
    /// The thread the session is on, once started.
    private(set) var threadID: String?
    /// The running turn — `turn/interrupt` needs it.
    private(set) var turnID: String?
    /// Mode and model apply to the next `turn/start` (Codex sets them per turn).
    var mode: PermissionMode = .ask
    var model: String?
    /// Reasoning effort, likewise per turn.
    var effort: String?
    /// Server-request ids we turned into approvals: answers must echo the id.
    private var approvalKinds: [String: ApprovalKind] = [:]

    enum ApprovalKind: Equatable { case command, fileChange }

    // MARK: - Outbound

    /// A request, recorded as pending under a fresh id.
    mutating func request(_ kind: Pending, method: String, params: JSONValue) -> JSONValue {
        nextID += 1
        pending[nextID] = kind
        return ["jsonrpc": "2.0", "id": .number(Double(nextID)), "method": .string(method), "params": params]
    }

    mutating func initialize() -> JSONValue {
        request(
            .initialize, method: "initialize",
            params: ["clientInfo": ["name": "grimoire", "title": "Grimoire", "version": "0.1.0"], "capabilities": .null])
    }

    static let initialized: JSONValue = ["jsonrpc": "2.0", "method": "initialized"]

    /// thread/start, or thread/resume / thread/fork for a stored thread.
    mutating func startThread(_ options: EngineStartOptions) -> JSONValue {
        mode = options.permissionMode ?? mode
        model = options.model ?? model
        effort = options.effort ?? effort
        var params: [String: JSONValue] = [
            "cwd": .string(options.workingDirectory.path),
            "approvalPolicy": .string(Self.approvalPolicy(for: mode)),
            "sandbox": .string(Self.sandboxMode(for: mode)),
        ]
        if let model { params["model"] = .string(model) }
        guard let resume = options.resume else {
            return request(.thread, method: "thread/start", params: .object(params))
        }
        params["threadId"] = .string(resume)
        return request(.thread, method: options.fork ? "thread/fork" : "thread/resume", params: .object(params))
    }

    /// A user turn. Mode and model ride along, so a change made between turns applies.
    mutating func turn(_ text: String, images: [EngineImage]) -> JSONValue? {
        guard let threadID else { return nil }
        let pictures: [JSONValue] = images.map {
            ["type": "image", "url": .string("data:\($0.mediaType);base64,\($0.base64)")]
        }
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(pictures + [["type": "text", "text": .string(text), "text_elements": []]]),
            "approvalPolicy": .string(Self.approvalPolicy(for: mode)),
            "sandboxPolicy": Self.sandboxPolicy(for: mode),
        ]
        if let model { params["model"] = .string(model) }
        if let effort { params["effort"] = .string(effort) }
        return request(.turnStart, method: "turn/start", params: .object(params))
    }

    mutating func interrupt() -> JSONValue? {
        guard let threadID, let turnID else { return nil }
        return request(.interrupt, method: "turn/interrupt", params: ["threadId": .string(threadID), "turnId": .string(turnID)])
    }

    /// Text added to the running turn (`turn/steer`): a denial's reason, which Codex's `decline` cannot carry.
    mutating func steer(_ text: String) -> JSONValue? {
        guard let threadID, let turnID else { return nil }
        return request(
            .steer, method: "turn/steer",
            params: [
                "threadId": .string(threadID), "expectedTurnId": .string(turnID),
                "input": [["type": "text", "text": .string(text), "text_elements": []]],
            ])
    }

    /// The JSON-RPC response to an approval request.
    func answer(_ request: ApprovalRequest, with decision: ApprovalDecision) -> JSONValue {
        let value: String
        switch decision {
        case .allow: value = "accept"
        case .allowAlways: value = "acceptForSession"
        case .deny: value = "decline"
        }
        return ["jsonrpc": "2.0", "id": Self.rpcID(request.id), "result": ["decision": .string(value)]]
    }

    // MARK: - Permission modes

    /// Grimoire's modes in Codex terms: who asks (approval policy) and what
    /// the sandbox allows. Codex edits inside the workspace without asking
    /// under `workspace-write`, so *Ask* additionally distrusts commands.
    static func approvalPolicy(for mode: PermissionMode) -> String {
        switch mode {
        case .ask: "untrusted"
        case .acceptEdits, .plan: "on-request"
        case .bypassPermissions: "never"
        }
    }

    static func sandboxMode(for mode: PermissionMode) -> String {
        switch mode {
        case .ask, .acceptEdits: "workspace-write"
        case .plan: "read-only"
        case .bypassPermissions: "danger-full-access"
        }
    }

    static func sandboxPolicy(for mode: PermissionMode) -> JSONValue {
        switch mode {
        case .ask, .acceptEdits:
            ["type": "workspaceWrite", "writableRoots": [], "networkAccess": false, "excludeTmpdirEnvVar": false, "excludeSlashTmp": false]
        case .plan: ["type": "readOnly", "networkAccess": false]
        case .bypassPermissions: ["type": "dangerFullAccess"]
        }
    }

    static func mode(approvalPolicy: String?, sandbox: String?) -> PermissionMode? {
        switch (approvalPolicy, sandbox) {
        case ("never", _): .bypassPermissions
        case (_, "readOnly"), (_, "read-only"): .plan
        case ("untrusted", _): .ask
        case ("on-request", _): .acceptEdits
        default: nil
        }
    }

    // MARK: - Inbound

    /// The events one printed line stands for, plus any reply it needs
    /// (unsupported server requests get an error so a turn never hangs).
    mutating func decode(_ line: String) -> (events: [EngineEvent], reply: JSONValue?) {
        guard let message = try? JSONValue.parse(line) else {
            return ([.error("Unreadable output: \(line.prefix(200))")], nil)
        }
        if let method = message["method"]?.stringValue {
            if let id = message["id"] { return serverRequest(method, id: id, params: message["params"] ?? .null) }
            return (notification(method, params: message["params"] ?? .null), nil)
        }
        return (response(message), nil)
    }

    private mutating func response(_ message: JSONValue) -> [EngineEvent] {
        guard let id = message["id"]?.doubleValue.map(Int.init), let kind = pending.removeValue(forKey: id) else {
            return []
        }
        if let error = message["error"] {
            return [.error(error["message"]?.stringValue ?? "Codex refused a request.")]
        }
        let result = message["result"] ?? .null
        switch kind {
        case .thread:
            guard let thread = result["thread"], let id = thread["id"]?.stringValue else { return [] }
            threadID = id
            let mode = Self.mode(
                approvalPolicy: result["approvalPolicy"]?.stringValue, sandbox: result["sandbox"]?["type"]?.stringValue)
            if let mode { self.mode = mode }
            return [
                .sessionStarted(
                    SessionInfo(
                        sessionID: id, model: result["model"]?.stringValue ?? "", permissionMode: mode,
                        workingDirectory: result["cwd"]?.stringValue ?? thread["cwd"]?.stringValue ?? "", tools: []))
            ]
        case .turnStart:
            turnID = result["turn"]?["id"]?.stringValue ?? turnID
            return []
        case .initialize, .interrupt, .steer:
            return []
        }
    }

    private mutating func notification(_ method: String, params: JSONValue) -> [EngineEvent] {
        switch method {
        case "turn/started":
            turnID = params["turn"]?["id"]?.stringValue ?? turnID
            return [.status("working")]
        case "item/agentMessage/delta":
            guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue else { return [] }
            return [.textDelta(messageID: id, text: delta)]
        case "item/started":
            guard let item = params["item"] else { return [] }
            return Self.started(item)
        case "item/completed":
            guard let item = params["item"] else { return [] }
            return Self.completed(item)
        case "turn/plan/updated":
            let steps = (params["plan"]?.arrayValue ?? []).compactMap { step -> PlanStep? in
                guard let title = step["step"]?.stringValue else { return nil }
                let status: PlanStep.Status =
                    switch step["status"]?.stringValue {
                    case "completed": .completed
                    case "inProgress": .inProgress
                    default: .pending
                    }
                return PlanStep(title: title, status: status)
            }
            // One plan per turn, updated in place: the id repeats, so the thread replaces it.
            let id = "plan-\(params["turnId"]?.stringValue ?? "")"
            return steps.isEmpty ? [] : [.block(messageID: id, .toolUse(id: id, name: "TodoWrite", input: Self.todos(steps)))]
        case "turn/completed":
            return [turnCompleted(params)]
        case "error":
            // A retried error isn't the end of the turn; the final one comes with turn/completed.
            guard params["willRetry"]?.boolValue != true else { return [] }
            return [.error(params["error"]?["message"]?.stringValue ?? "Codex reported an error.")]
        case "account/rateLimits/updated":
            return Self.usage(params["rateLimits"]).map { [.usage($0)] } ?? []
        default:
            return []
        }
    }

    private mutating func turnCompleted(_ params: JSONValue) -> EngineEvent {
        let turn = params["turn"]
        let outcome: TurnOutcome =
            switch turn?["status"]?.stringValue {
            case "completed": .success
            case "interrupted": .interrupted
            default: .failed(turn?["error"]?["message"]?.stringValue ?? "The turn failed.")
            }
        turnID = nil
        return .turnFinished(TurnResult(outcome: outcome, sessionID: threadID ?? "", costUSD: nil, text: nil))
    }

    private mutating func serverRequest(_ method: String, id: JSONValue, params: JSONValue) -> (
        events: [EngineEvent], reply: JSONValue?
    ) {
        let requestID = Self.idString(id)
        switch method {
        case "item/commandExecution/requestApproval":
            approvalKinds[requestID] = .command
            var input: [String: JSONValue] = ["command": params["command"] ?? ""]
            if let cwd = params["cwd"] { input["cwd"] = cwd }
            return (
                [
                    .approval(
                        ApprovalRequest(
                            id: requestID, toolUseID: params["itemId"]?.stringValue ?? "", toolName: "Bash",
                            input: .object(input), summary: params["reason"]?.stringValue ?? "",
                            suggestions: [["type": "acceptForSession"]]))
                ], nil
            )
        case "item/fileChange/requestApproval":
            approvalKinds[requestID] = .fileChange
            return (
                [
                    .approval(
                        ApprovalRequest(
                            id: requestID, toolUseID: params["itemId"]?.stringValue ?? "", toolName: "Patch", input: .null,
                            summary: params["reason"]?.stringValue ?? "", suggestions: [["type": "acceptForSession"]]))
                ], nil
            )
        default:
            // Not something Grimoire can answer yet (user-input questions, MCP
            // elicitations, dynamic tools): refuse, so the turn moves on.
            return (
                [],
                [
                    "jsonrpc": "2.0", "id": id,
                    "error": ["code": .number(-32601), "message": .string("Grimoire doesn't handle \(method) yet.")],
                ]
            )
        }
    }

    // MARK: - Items

    /// Items that show as soon as they start: tool calls, so a running command has a card.
    static func started(_ item: JSONValue) -> [EngineEvent] {
        guard let id = item["id"]?.stringValue else { return [] }
        switch item["type"]?.stringValue {
        case "commandExecution":
            return [.block(messageID: id, .toolUse(id: id, name: "Bash", input: ["command": item["command"] ?? ""]))]
        case "fileChange":
            return [.block(messageID: id, .toolUse(id: id, name: "Patch", input: ["changes": item["changes"] ?? []]))]
        case "mcpToolCall":
            let name = "mcp__\(item["server"]?.stringValue ?? "")__\(item["tool"]?.stringValue ?? "")"
            return [.block(messageID: id, .toolUse(id: id, name: name, input: item["arguments"] ?? .null))]
        default:
            return []
        }
    }

    /// Finished items: text and reasoning blocks, and tool results.
    static func completed(_ item: JSONValue) -> [EngineEvent] {
        guard let id = item["id"]?.stringValue else { return [] }
        switch item["type"]?.stringValue {
        case "agentMessage":
            return [.block(messageID: id, .text(item["text"]?.stringValue ?? ""))]
        case "reasoning":
            let parts = (item["summary"]?.arrayValue ?? []) + (item["content"]?.arrayValue ?? [])
            let text = parts.compactMap(\.stringValue).joined(separator: "\n\n")
            return text.isEmpty ? [] : [.block(messageID: id, .thinking(text))]
        case "commandExecution":
            let failed = item["status"]?.stringValue == "failed" || item["status"]?.stringValue == "declined"
                || (item["exitCode"]?.doubleValue).map { $0 != 0 } == true
            return [
                .toolResult(toolUseID: id, content: item["aggregatedOutput"]?.stringValue ?? "", isError: failed)
            ]
        case "fileChange":
            let failed = item["status"]?.stringValue != "completed"
            let paths = (item["changes"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
            return [.toolResult(toolUseID: id, content: paths.joined(separator: "\n"), isError: failed)]
        case "mcpToolCall":
            if let error = item["error"]?["message"]?.stringValue {
                return [.toolResult(toolUseID: id, content: error, isError: true)]
            }
            let text = (item["result"]?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
            return [.toolResult(toolUseID: id, content: text.joined(separator: "\n"), isError: false)]
        case "plan":
            return [.block(messageID: id, .text(item["text"]?.stringValue ?? ""))]
        default:
            return []
        }
    }

    /// A stored thread's turns as transcript rows (for `thread/read` history).
    static func transcript(_ thread: JSONValue) -> [TranscriptItem] {
        (thread["turns"]?.arrayValue ?? []).flatMap { turn in
            (turn["items"]?.arrayValue ?? []).flatMap { item -> [TranscriptItem] in
                if item["type"]?.stringValue == "userMessage" {
                    let text = (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                    return text.isEmpty ? [] : [.user(text)]
                }
                return (started(item) + completed(item)).compactMap { event in
                    switch event {
                    case .block(_, let block): .assistant(block)
                    case .toolResult(let id, let content, let isError): .toolResult(toolUseID: id, content: content, isError: isError)
                    default: nil
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    static func usage(_ snapshot: JSONValue?) -> [UsageWindow]? {
        guard let snapshot else { return nil }
        let windows: [UsageWindow] = [("primary", snapshot["primary"]), ("secondary", snapshot["secondary"])].compactMap {
            _, window in
            guard let window, let used = window["usedPercent"]?.doubleValue else { return nil }
            let minutes = window["windowDurationMins"]?.doubleValue ?? 0
            let name = minutes >= 1_440 ? "\(Int(minutes / 1_440))-day" : minutes > 0 ? "\(Int(minutes / 60))-hour" : "Usage"
            return UsageWindow(
                name: name, utilization: used / 100,
                resetsAt: window["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) })
        }
        return windows.isEmpty ? nil : windows
    }

    static func todos(_ steps: [PlanStep]) -> JSONValue {
        ["todos": .array(steps.map { ["content": .string($0.title), "status": .string($0.status.rawValue)] })]
    }

    /// JSON-RPC ids are numbers or strings; approvals carry them as strings.
    static func idString(_ id: JSONValue) -> String {
        if let number = id.doubleValue { return String(Int(number)) }
        return id.stringValue ?? ""
    }

    static func rpcID(_ id: String) -> JSONValue {
        Int(id).map { .number(Double($0)) } ?? .string(id)
    }
}
