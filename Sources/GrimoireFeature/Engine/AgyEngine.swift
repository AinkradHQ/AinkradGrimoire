import Foundation

/// agy as a `HarnessEngine`: one `agy … -p=` process per conversation, one
/// line in per turn. agy can't change mode or stop a turn mid-process, so
/// interrupting and switching mode or model end the process; the next message
/// restarts it on the same conversation (`--conversation`).
@MainActor
public final class AgyEngine: HarnessEngine {
    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let executable: URL
    private let environment: [String: String]
    private var workingDirectory: URL?
    private var process: HarnessProcess?
    /// Bumped per spawn, so a replaced process's last lines are ignored.
    private var generation = 0
    private var wire = AgyProtocol()
    private var isBusy = false

    public enum Failure: Error, Equatable {
        case notStarted
        case alreadyStarted
        case cannotFork
    }

    public init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
    }

    public func start(_ options: EngineStartOptions) throws {
        guard workingDirectory == nil else { throw Failure.alreadyStarted }
        guard !options.fork else { throw Failure.cannotFork }
        workingDirectory = options.workingDirectory
        wire.conversationID = options.resume
        wire.mode = options.permissionMode ?? .ask
        wire.model = options.model
        try spawn()
        // agy has no handshake: it is ready once spawned, so the thread stops showing its startup steps.
        continuation.yield(.status("started"))
    }

    public func send(_ text: String, images: [EngineImage]) throws {
        guard workingDirectory != nil else { throw Failure.notStarted }
        if process == nil { try spawn() }
        try process?.write(AgyProtocol.message(text).line())
        isBusy = true
    }

    public func interrupt() throws {
        guard isBusy else { return }
        end()
        continuation.yield(
            .turnFinished(
                TurnResult(outcome: .interrupted, sessionID: wire.conversationID ?? "", costUSD: nil, text: nil)))
    }

    /// agy never asks; nothing to answer.
    public func answer(_ request: ApprovalRequest, with decision: ApprovalDecision) throws {}

    public func setPermissionMode(_ mode: PermissionMode) throws {
        wire.mode = mode
        if !isBusy { end() }
        continuation.yield(.permissionModeChanged(mode))
    }

    public func setModel(_ model: String) throws {
        wire.model = model
        if !isBusy { end() }
        continuation.yield(.modelChanged(model))
    }

    public func stop() {
        end()
        continuation.yield(.exited(code: 0))
        continuation.finish()
    }

    private func spawn() throws {
        guard let workingDirectory else { throw Failure.notStarted }
        let process = HarnessProcess(
            executable: executable, arguments: wire.arguments(), workingDirectory: workingDirectory,
            environment: environment)
        try process.run()
        generation += 1
        let generation = generation
        self.process = process
        Task { [weak self] in
            for await output in process.output {
                self?.handle(output, generation: generation)
            }
        }
    }

    /// Ends the current process; the conversation lives on in agy.
    private func end() {
        generation += 1
        process?.stop(grace: .zero)
        process = nil
        isBusy = false
    }

    private func handle(_ output: HarnessProcess.Output, generation: Int) {
        guard generation == self.generation else { return }
        switch output {
        case .line(let line):
            for event in wire.decode(line) {
                if case .turnFinished = event { isBusy = false }
                continuation.yield(event)
            }
        case .exited(let code, let stderr):
            process = nil
            guard isBusy else { return }
            isBusy = false
            let reason = stderr.isEmpty ? "agy exited with code \(code)" : stderr
            continuation.yield(
                .turnFinished(TurnResult(outcome: .failed(reason), sessionID: wire.conversationID ?? "", costUSD: nil, text: nil)))
        }
    }
}
