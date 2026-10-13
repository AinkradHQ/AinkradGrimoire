import Foundation
import Observation

/// One thread you can talk to: its stored history plus everything a running
/// agent adds to it. The agent starts on the first send (or on demand) and
/// resumes the stored session, so the conversation continues in the CLI's own
/// file — `claude --resume <id>` in a terminal picks up where this left off.
@MainActor
@Observable
final class LiveThread {
    enum Status: Equatable {
        case idle
        case working
        /// An approval is waiting.
        case needsYou
        case failed(String)
    }

    private(set) var entries: [ThreadEntry]
    private(set) var status: Status = .idle
    private(set) var pendingApproval: ApprovalRequest?
    private(set) var commands: [SlashCommandInfo] = []
    /// Which of `commands` are skills, when the CLI says (Claude's init does).
    private(set) var skills: Set<String> = []
    /// The CLI's id for this session; set once the agent has started.
    private(set) var sessionID: String?
    private(set) var model: String?
    private(set) var mode: PermissionMode = .ask
    /// Reasoning effort for this thread (`Harness.efforts`); nil is the CLI's default.
    private(set) var effort: String?
    private(set) var costUSD: Double = 0
    /// When the running turn started — drives the status line's clock.
    private(set) var turnStartedAt: Date?
    /// The running turn's output tokens by assistant message, as the CLI reports them.
    private var turnTokens: [String: Int] = [:]
    /// The last finished turn this run: how long it took and the tokens it wrote (nil when not reported).
    private(set) var lastTurn: (duration: TimeInterval, tokens: Int?)?
    /// The agent's name for Grimoire's own notes ("Claude did not answer…").
    var agentName = "The agent"
    /// The composer's text. Kept here so a message the agent never answered can go back into it.
    var draft = ""
    /// Set from spawning the agent until it first answers (E6 B): the transcript lists the startup steps.
    private(set) var startingSince: Date?
    /// Messages in the stored history this thread opened with.
    let loadedMessages: Int
    /// Why the agent stopped, for the in-transcript failure card (E6 C).
    private(set) var failure: EngineFailure?
    /// The last turn failed on the agent's usage limit (E6 D); cleared by the next send.
    private(set) var hitLimit = false
    /// "Send at reset": the composer's message goes out at this time.
    private(set) var sendAt: Date?

    /// Called once the CLI names the session — a new thread's id until then is
    /// a placeholder.
    var onSessionID: ((String) -> Void)?
    /// Called when the agent stops to ask for an approval.
    var onNeedsYou: ((ApprovalRequest) -> Void)?
    /// Called with the CLI's rate-limit windows whenever they're reported.
    var onUsage: (([UsageWindow]) -> Void)?
    /// Called when a turn fails on the usage limit, with the reset the CLI named if it named one.
    var onUsageLimit: ((Date?) -> Void)?
    /// Called as each turn ends, with when it started: Grimoire tells Forge which files it wrote (E5).
    var onTurnFinished: ((Date?) -> Void)?

    private var engine: HarnessEngine?
    /// Set by `stop()`, so the exit it causes isn't reported as a crash.
    private var stopping = false
    private let makeEngine: () -> HarnessEngine
    private let startOptions: EngineStartOptions
    /// The assistant message whose text is streaming into `entries[index]`.
    private var streaming: (messageID: String, index: Int)?
    private var toolIndex: [String: Int] = [:]
    /// Plans by their tool id, so an updated plan replaces its card.
    private var planIndex: [String: Int] = [:]
    /// When each running tool started, for its card's duration.
    private var toolStarted: [String: Date] = [:]
    private let clock: () -> Date
    /// When the running engine was spawned, and what it printed to stderr since.
    private var launchedAt: Date?
    private var errorOutput = ""
    private var sendTask: Task<Void, Never>?

    init(
        entries: [ThreadEntry], startOptions: EngineStartOptions, model: String? = nil,
        clock: @escaping () -> Date = Date.init, makeEngine: @escaping () -> HarnessEngine
    ) {
        self.entries = entries
        self.clock = clock
        self.loadedMessages =
            startOptions.resume == nil
            ? 0 : entries.filter { if case .tool = $0 { false } else if case .plan = $0 { false } else { true } }.count
        self.startOptions = startOptions
        self.sessionID = startOptions.resume
        self.model = model
        self.mode = startOptions.permissionMode ?? .ask
        self.effort = startOptions.effort
        self.makeEngine = makeEngine
        for (index, entry) in entries.enumerated() {
            if case .tool(let call) = entry { toolIndex[call.id] = index }
        }
    }

    var isRunning: Bool { engine != nil }
    /// The folder the agent works in.
    var workingDirectory: String { startOptions.workingDirectory.path }
    /// Stop is offered (button and ⌘.) while a turn runs or waits on an approval.
    var canInterrupt: Bool { status == .working || status == .needsYou }
    /// "Always allow" is offered (button and ⌘⌥↩) only when the agent suggested a standing rule.
    var canAllowAlways: Bool { pendingApproval?.suggestions.isEmpty == false }
    /// The running turn's tokens so far; nil before the CLI reports any.
    var turnOutputTokens: Int? { turnTokens.isEmpty ? nil : turnTokens.values.reduce(0, +) }
    /// How long the running turn has taken, by this thread's clock.
    var turnElapsed: TimeInterval? { turnStartedAt.map { max(clock().timeIntervalSince($0), 0) } }
    /// What the running turn is doing: the description of the command running now (Claude's Bash carries one).
    var activity: String? {
        for entry in entries.reversed() {
            guard case .tool(let call) = entry else { continue }
            guard call.result == nil, let text = call.input["description"]?.stringValue, !text.isEmpty else { return nil }
            return text
        }
        return nil
    }

    // MARK: - Actions

    /// Starts the agent if it isn't running. Cheap to call on every keystroke.
    func ensureStarted() {
        guard engine == nil else { return }
        let engine = makeEngine()
        self.engine = engine
        stopping = false
        failure = nil
        errorOutput = ""
        launchedAt = clock()
        startingSince = launchedAt
        var options = startOptions
        options.effort = effort
        do {
            try engine.start(options)
        } catch {
            self.engine = nil
            startingSince = nil
            status = .failed("Couldn't start the agent: \(error.localizedDescription)")
            fail(EngineFailure(code: nil, after: 0, output: error.localizedDescription, beforeStart: true))
            return
        }
        Task { [weak self] in
            for await event in engine.events {
                self?.apply(event)
            }
        }
    }

    /// Sends a message. While a turn runs the CLI queues it and answers after.
    func send(_ text: String, images: [EngineImage] = []) {
        hitLimit = false
        cancelSendAtReset()
        ensureStarted()
        guard let engine else { return }
        do {
            try engine.send(text, images: images)
            entries.append(.user(text))
            if status != .needsYou { status = .working }
            if turnStartedAt == nil {
                turnStartedAt = clock()
                turnTokens = [:]
            }
        } catch {
            status = .failed("Couldn't send: \(error.localizedDescription)")
        }
    }

    func interrupt() {
        try? engine?.interrupt()
    }

    func answer(_ decision: ApprovalDecision) {
        guard let request = pendingApproval, let engine else { return }
        try? engine.answer(request, with: decision)
        pendingApproval = nil
        status = .working
    }

    func setMode(_ mode: PermissionMode) {
        self.mode = mode
        try? engine?.setPermissionMode(mode)
    }

    func setModel(_ model: String) {
        self.model = model
        try? engine?.setModel(model)
    }

    func setEffort(_ effort: String) {
        self.effort = effort
        try? engine?.setEffort(effort)
    }

    func stop() {
        stopping = true
        engine?.stop()
    }

    /// The failure card's Retry: start the agent again and send what is in the composer.
    func retry() {
        failure = nil
        status = .idle
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ensureStarted() }
        draft = ""
        send(text)
    }

    /// Sends the composer's message at `date` — the usage limit's reset.
    func sendAtReset(_ date: Date) {
        sendAt = date
        sendTask?.cancel()
        let delay = max(date.timeIntervalSince(clock()), 0)
        sendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.sendQueued()
        }
    }

    func cancelSendAtReset() {
        sendTask?.cancel()
        sendTask = nil
        sendAt = nil
    }

    /// Internal so tests can fire the queue without waiting for the reset.
    func sendQueued() {
        guard sendAt != nil else { return }
        sendAt = nil
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        send(text)
    }

    /// Shows a failure: a usage limit docks the limit bar, anything else gets the card. Either way the
    /// message the agent never answered goes back into the composer.
    private func fail(_ failure: EngineFailure) {
        var failure = failure
        if failure.kind == .usageLimit {
            hitLimit = true
            _ = restoreUnanswered(removing: false)
            entries.append(.note(Self.limitNote(agentName)))
            onUsageLimit?(UsageLimit.resetHint(in: failure.output))
            return
        }
        failure.restoredDraft = restoreUnanswered(removing: true)
        self.failure = failure
    }

    static func limitNote(_ agent: String) -> String { "\(agent) did not answer — the plan’s usage limit was reached." }

    /// Puts the last message back in the composer when nothing answered it. `removing` takes it out of the
    /// transcript too (it never got anywhere). True when the composer now holds a message.
    private func restoreUnanswered(removing: Bool) -> Bool {
        if case .user(let text) = entries.last, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
            if removing { entries.removeLast() }
        }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Events

    /// Folds one engine event into the thread. Internal so tests can replay a
    /// recorded session without a process.
    func apply(_ event: EngineEvent) {
        // Anything the agent says besides an error means it is up.
        switch event {
        case .error, .exited: break
        default: startingSince = nil
        }
        switch event {
        case .sessionStarted(let info):
            if info.sessionID != sessionID, !info.sessionID.isEmpty { onSessionID?(info.sessionID) }
            sessionID = info.sessionID
            if !info.model.isEmpty { model = info.model }
            if let mode = info.permissionMode { self.mode = mode }
            skills = Set(info.skills)
        case .commands(let list):
            commands = list
        case .textDelta(let messageID, let text):
            appendStreaming(text, messageID: messageID)
        case .block(let messageID, let block):
            add(block, messageID: messageID)
        case .toolResult(let id, let content, let isError):
            guard let index = toolIndex[id], case .tool(var call) = entries[index] else { return }
            call.result = ToolOutput(content: content, isError: isError)
            call.duration = toolStarted.removeValue(forKey: id).map { clock().timeIntervalSince($0) }
            entries[index] = .tool(call)
        case .approval(let request):
            adoptRewrite(request)
            pendingApproval = request
            status = .needsYou
            onNeedsYou?(request)
        case .usage(let windows):
            onUsage?(windows)
        case .permissionModeChanged(let mode):
            self.mode = mode
        case .modelChanged(let model):
            self.model = model
        case .status:
            break
        case .tokens(let messageID, let output):
            turnTokens[messageID] = max(turnTokens[messageID] ?? 0, output)
        case .turnFinished(let result):
            streaming = nil
            let started = turnStartedAt
            defer { onTurnFinished?(started) }
            turnStartedAt = nil
            if let started { lastTurn = (clock().timeIntervalSince(started), result.outputTokens ?? turnOutputTokens) }
            turnTokens = [:]
            costUSD += result.costUSD ?? 0
            switch result.outcome {
            case .success, .interrupted: status = pendingApproval == nil ? .idle : .needsYou
            case .failed(let message):
                status = .failed(message)
                // A recognised failure gets the card's fix-it or the limit bar; others keep the status line.
                if EngineFailure.classify(message) != .other {
                    fail(EngineFailure(code: nil, after: elapsed, output: message, beforeStart: false))
                }
            }
        case .error(let message):
            status = .failed(message)
            errorOutput += (errorOutput.isEmpty ? "" : "\n") + message
        case .exited(let code):
            let wasStarting = startingSince != nil
            let wasBusy = turnStartedAt != nil || status == .needsYou
            startingSince = nil
            engine = nil
            pendingApproval = nil
            turnStartedAt = nil
            streaming = nil
            // Nothing runs once the CLI is gone, so no card may stay "running…".
            for (_, index) in toolIndex {
                guard case .tool(var call) = entries[index], call.result == nil else { continue }
                call.result = ToolOutput(content: "Interrupted — the agent exited", isError: true)
                entries[index] = .tool(call)
            }
            // A CLI that dies mid-turn often leaves no stderr (crash, kill, OOM);
            // say so rather than going quietly idle.
            if status == .working || status == .needsYou {
                status = stopping ? .idle : .failed("The agent exited mid-turn (code \(code))")
            }
            guard code != 0, !stopping, wasStarting || wasBusy else { return }
            if case .failed = status {} else { status = .failed("The agent exited (code \(code))") }
            let output = errorOutput.isEmpty ? failure?.output ?? "" : errorOutput
            fail(EngineFailure(code: code, after: elapsed, output: output, beforeStart: wasStarting))
        }
    }

    private var elapsed: TimeInterval { launchedAt.map { clock().timeIntervalSince($0) } ?? 0 }

    /// A PreToolUse hook may rewrite a command (`cat` → `rtk read`) before the approval is asked; the card
    /// then shows what will run, like the approval does, and keeps what the agent wrote (GD3).
    private func adoptRewrite(_ request: ApprovalRequest) {
        guard let index = toolIndex[request.toolUseID], case .tool(var call) = entries[index],
            case .object(var input) = call.input, let original = input["command"]?.stringValue,
            let actual = request.input["command"]?.stringValue, actual != original
        else { return }
        input["command"] = .string(actual)
        call.input = .object(input)
        call.rewrittenFrom = call.rewrittenFrom ?? original
        entries[index] = .tool(call)
    }

    private func appendStreaming(_ text: String, messageID: String) {
        if let streaming, streaming.messageID == messageID, case .text(let sofar) = entries[streaming.index] {
            entries[streaming.index] = .text(sofar + text)
        } else {
            entries.append(.text(text))
            streaming = (messageID, entries.count - 1)
        }
    }

    private func add(_ block: AssistantBlock, messageID: String) {
        switch block {
        case .text(let text):
            // The finished block replaces what streamed in for it.
            if let streaming, streaming.messageID == messageID, case .text = entries[streaming.index] {
                entries[streaming.index] = .text(text)
                self.streaming = nil
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append(.text(text))
            }
        case .thinking(let text):
            if !text.isEmpty { entries.append(.thinking(text)) }
        case .toolUse(let id, let name, let input):
            streaming = nil
            if name == "TodoWrite", let steps = ThreadEntries.plan(from: input) {
                if let index = planIndex[id] {
                    entries[index] = .plan(steps)
                } else {
                    planIndex[id] = entries.count
                    entries.append(.plan(steps))
                }
            } else {
                toolIndex[id] = entries.count
                toolStarted[id] = clock()
                entries.append(.tool(ToolCall(id: id, name: name, input: input, result: nil)))
            }
        }
    }
}
