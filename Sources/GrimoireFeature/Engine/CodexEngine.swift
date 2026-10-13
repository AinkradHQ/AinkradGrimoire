import Foundation

/// Codex as a `HarnessEngine`: one `codex app-server` per session, driven over
/// JSON-RPC with `CodexProtocol`.
@MainActor
public final class CodexEngine: HarnessEngine {
    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let executable: URL
    private let environment: [String: String]
    private var process: HarnessProcess?
    private var wire = CodexProtocol()
    /// Messages sent before Codex answered with the thread; sent once it has.
    private var queued: [(String, [EngineImage])] = []
    private var stopping = false

    public enum Failure: Error, Equatable {
        case notStarted
        case alreadyStarted
    }

    public init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
    }

    public func start(_ options: EngineStartOptions) throws {
        guard process == nil else { throw Failure.alreadyStarted }
        let process = HarnessProcess(
            executable: executable, arguments: ["app-server"], workingDirectory: options.workingDirectory,
            environment: environment)
        try process.run()
        self.process = process
        Task { [weak self] in
            for await output in process.output {
                self?.handle(output)
            }
        }
        try write(wire.initialize())
        try write(CodexProtocol.initialized)
        try write(wire.startThread(options))
    }

    public func send(_ text: String, images: [EngineImage]) throws {
        guard process != nil else { throw Failure.notStarted }
        guard let turn = wire.turn(text, images: images) else {
            queued.append((text, images))
            return
        }
        try write(turn)
    }

    public func interrupt() throws {
        if let request = wire.interrupt() { try write(request) }
    }

    public func answer(_ request: ApprovalRequest, with decision: ApprovalDecision) throws {
        try write(wire.answer(request, with: decision))
        // `decline` has no message: the reason goes into the running turn instead.
        if case .deny(let reason) = decision, reason != ApprovalBarRule.denial(""), let steer = wire.steer(reason) {
            try write(steer)
        }
    }

    /// Codex takes the mode with each turn; it applies from the next one.
    public func setPermissionMode(_ mode: PermissionMode) throws {
        wire.mode = mode
        continuation.yield(.permissionModeChanged(mode))
    }

    public func setModel(_ model: String) throws {
        wire.model = model
        continuation.yield(.modelChanged(model))
    }

    /// Like the model: rides along with the next `turn/start`.
    public func setEffort(_ effort: String) throws {
        wire.effort = effort
    }

    public func stop() {
        stopping = true
        process?.stop()
    }

    private func write(_ message: JSONValue) throws {
        guard let process else { throw Failure.notStarted }
        try process.write(message.line())
    }

    private func handle(_ output: HarnessProcess.Output) {
        switch output {
        case .line(let line):
            let (events, reply) = wire.decode(line)
            if let reply { try? write(reply) }
            for event in events {
                continuation.yield(event)
                if case .sessionStarted = event { flushQueued() }
            }
        case .exited(let code, let stderr):
            if code != 0, !stopping, !stderr.isEmpty { continuation.yield(.error(stderr)) }
            continuation.yield(.exited(code: code))
            continuation.finish()
        }
    }

    private func flushQueued() {
        let pending = queued
        queued = []
        for (text, images) in pending { try? send(text, images: images) }
    }
}
