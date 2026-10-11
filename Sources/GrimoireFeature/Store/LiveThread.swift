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
    /// The CLI's id for this session; set once the agent has started.
    private(set) var sessionID: String?
    private(set) var model: String?
    private(set) var mode: PermissionMode = .ask
    private(set) var costUSD: Double = 0
    /// When the running turn started — drives the status line's clock.
    private(set) var turnStartedAt: Date?

    /// Called once the CLI names the session — a new thread's id until then is
    /// a placeholder.
    var onSessionID: ((String) -> Void)?
    /// Called when the agent stops to ask for an approval.
    var onNeedsYou: ((ApprovalRequest) -> Void)?
    /// Called with the CLI's rate-limit windows whenever they're reported.
    var onUsage: (([UsageWindow]) -> Void)?

    private var engine: HarnessEngine?
    private let makeEngine: () -> HarnessEngine
    private let startOptions: EngineStartOptions
    /// The assistant message whose text is streaming into `entries[index]`.
    private var streaming: (messageID: String, index: Int)?
    private var toolIndex: [String: Int] = [:]
    /// Plans by their tool id, so an updated plan replaces its card.
    private var planIndex: [String: Int] = [:]

    init(
        entries: [ThreadEntry], startOptions: EngineStartOptions, model: String? = nil,
        makeEngine: @escaping () -> HarnessEngine
    ) {
        self.entries = entries
        self.startOptions = startOptions
        self.sessionID = startOptions.resume
        self.model = model
        self.mode = startOptions.permissionMode ?? .ask
        self.makeEngine = makeEngine
        for (index, entry) in entries.enumerated() {
            if case .tool(let call) = entry { toolIndex[call.id] = index }
        }
    }

    var isRunning: Bool { engine != nil }

    // MARK: - Actions

    /// Starts the agent if it isn't running. Cheap to call on every keystroke.
    func ensureStarted() {
        guard engine == nil else { return }
        let engine = makeEngine()
        self.engine = engine
        do {
            try engine.start(startOptions)
        } catch {
            self.engine = nil
            status = .failed("Couldn't start the agent: \(error.localizedDescription)")
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
        ensureStarted()
        guard let engine else { return }
        do {
            try engine.send(text, images: images)
            entries.append(.user(text))
            if status != .needsYou { status = .working }
            if turnStartedAt == nil { turnStartedAt = Date() }
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

    func stop() {
        engine?.stop()
    }

    // MARK: - Events

    /// Folds one engine event into the thread. Internal so tests can replay a
    /// recorded session without a process.
    func apply(_ event: EngineEvent) {
        switch event {
        case .sessionStarted(let info):
            if info.sessionID != sessionID, !info.sessionID.isEmpty { onSessionID?(info.sessionID) }
            sessionID = info.sessionID
            if !info.model.isEmpty { model = info.model }
            if let mode = info.permissionMode { self.mode = mode }
        case .commands(let list):
            commands = list
        case .textDelta(let messageID, let text):
            appendStreaming(text, messageID: messageID)
        case .block(let messageID, let block):
            add(block, messageID: messageID)
        case .toolResult(let id, let content, let isError):
            guard let index = toolIndex[id], case .tool(var call) = entries[index] else { return }
            call.result = ToolOutput(content: content, isError: isError)
            entries[index] = .tool(call)
        case .approval(let request):
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
        case .turnFinished(let result):
            streaming = nil
            turnStartedAt = nil
            costUSD += result.costUSD ?? 0
            switch result.outcome {
            case .success, .interrupted: status = pendingApproval == nil ? .idle : .needsYou
            case .failed(let message): status = .failed(message)
            }
        case .error(let message):
            status = .failed(message)
        case .exited:
            engine = nil
            pendingApproval = nil
            turnStartedAt = nil
            if status == .working || status == .needsYou { status = .idle }
        }
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
                entries.append(.tool(ToolCall(id: id, name: name, input: input, result: nil)))
            }
        }
    }
}
