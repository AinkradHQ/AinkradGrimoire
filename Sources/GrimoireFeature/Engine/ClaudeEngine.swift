import Foundation

/// Claude Code as a `HarnessEngine`: one `claude -p` process per session,
/// driven over stdin/stdout with `ClaudeProtocol`.
@MainActor
public final class ClaudeEngine: HarnessEngine {
    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let executable: URL
    private let environment: [String: String]
    /// Appended to the CLI's arguments. Tests use it to isolate settings.
    private let extraArguments: [String]
    private var process: HarnessProcess?
    private var wire = ClaudeProtocol()
    /// After `stop()` the exit is expected: `claude` exits 1 when the last turn
    /// was interrupted, which is not an error worth showing.
    private var stopping = false

    public enum Failure: Error, Equatable {
        case notStarted
        case alreadyStarted
    }

    /// `environment` is what the child runs with — normally the login shell's
    /// (`CLILocator.loginEnvironment()`), so `claude` finds `node` and `git`.
    public convenience init(executable: URL, environment: [String: String]) {
        self.init(executable: executable, environment: environment, extraArguments: [])
    }

    init(executable: URL, environment: [String: String], extraArguments: [String]) {
        self.executable = executable
        self.environment = environment
        self.extraArguments = extraArguments
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
    }

    public func start(_ options: EngineStartOptions) throws {
        guard process == nil else { throw Failure.alreadyStarted }
        let process = HarnessProcess(
            executable: executable, arguments: ClaudeProtocol.arguments(for: options) + extraArguments,
            workingDirectory: options.workingDirectory, environment: environment)
        try process.run()
        self.process = process
        Task { [weak self] in
            for await output in process.output {
                self?.handle(output)
            }
        }
        try write(wire.control(.initialize))
    }

    public func send(_ text: String, images: [EngineImage]) throws {
        try write(ClaudeProtocol.userMessage(text, images: images))
    }

    public func interrupt() throws {
        try write(wire.control(.interrupt))
    }

    public func answer(_ request: ApprovalRequest, with decision: ApprovalDecision) throws {
        try write(ClaudeProtocol.answer(request, with: decision))
    }

    public func setPermissionMode(_ mode: PermissionMode) throws {
        try write(wire.control(.permissionMode(mode)))
    }

    public func setModel(_ model: String) throws {
        try write(wire.control(.model(model)))
    }

    public func setEffort(_ effort: String) throws {
        try write(wire.control(.effort(effort)))
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
            for event in wire.decode(line) { continuation.yield(event) }
        case .exited(let code, let stderr):
            if code != 0, !stopping, !stderr.isEmpty { continuation.yield(.error(stderr)) }
            continuation.yield(.exited(code: code))
            continuation.finish()
        }
    }
}
