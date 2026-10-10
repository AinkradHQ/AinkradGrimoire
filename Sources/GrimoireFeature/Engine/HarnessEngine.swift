import Foundation

/// The one interface the UI talks to. Each CLI (Claude Code, Codex, OpenCode,
/// agy) gets an adapter that speaks that CLI's own protocol; nothing above this
/// line knows which harness is running.
@MainActor
public protocol HarnessEngine: AnyObject {
    /// Everything the session does, in order. Finishes when the CLI exits.
    var events: AsyncStream<EngineEvent> { get }
    /// Spawns the CLI. `resume` continues a stored session; `fork` gives the
    /// resumed session a new id instead of appending to the old one.
    func start(_ options: EngineStartOptions) throws
    func send(_ text: String, images: [EngineImage]) throws
    /// Stops the running turn. The session stays alive for the next one.
    func interrupt() throws
    func answer(_ request: ApprovalRequest, with decision: ApprovalDecision) throws
    func setPermissionMode(_ mode: PermissionMode) throws
    func setModel(_ model: String) throws
    /// Ends the session: closes stdin, then terminates the process.
    func stop()
}

public struct EngineStartOptions: Sendable, Equatable {
    public var workingDirectory: URL
    public var model: String?
    public var permissionMode: PermissionMode?
    public var resume: String?
    public var fork: Bool
    /// Run the new session in its own git worktree with this name (the CLI
    /// creates `<repo>/.claude/worktrees/<name>`). Ignored when resuming:
    /// a resumed session runs where it ran before.
    public var worktree: String?

    public init(
        workingDirectory: URL, model: String? = nil, permissionMode: PermissionMode? = nil, resume: String? = nil,
        fork: Bool = false, worktree: String? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.permissionMode = permissionMode
        self.resume = resume
        self.fork = fork
        self.worktree = worktree
    }
}

public struct EngineImage: Sendable, Equatable {
    public var mediaType: String
    public var base64: String

    public init(mediaType: String, base64: String) {
        self.mediaType = mediaType
        self.base64 = base64
    }
}

/// How much the agent may do without asking. Raw values are Claude Code's
/// wire names; other adapters map them.
public enum PermissionMode: String, Sendable, CaseIterable {
    case ask = "default"
    case acceptEdits
    case plan
    case bypassPermissions
}

public struct SlashCommandInfo: Sendable, Equatable {
    public var name: String
    public var description: String
    public var argumentHint: String
}

public struct SessionInfo: Sendable, Equatable {
    public var sessionID: String
    public var model: String
    public var permissionMode: PermissionMode?
    public var workingDirectory: String
    public var tools: [String]
}

/// One finished piece of an assistant message.
public enum AssistantBlock: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: JSONValue)
}

public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    /// The CLI's request id; the answer must echo it.
    public var id: String
    public var toolUseID: String
    public var toolName: String
    public var input: JSONValue
    /// The CLI's own one-line summary (often the file name or command).
    public var summary: String
    /// Whether the CLI offered a standing rule ("always allow" / switch mode).
    public var suggestions: [JSONValue]
}

public enum ApprovalDecision: Sendable, Equatable {
    case allow
    /// Allow, and adopt the CLI's suggested standing rules so it stops asking.
    case allowAlways
    case deny(reason: String)
}

public enum TurnOutcome: Sendable, Equatable {
    case success
    case interrupted
    case failed(String)
}

public struct TurnResult: Sendable, Equatable {
    public var outcome: TurnOutcome
    public var sessionID: String
    public var costUSD: Double?
    public var text: String?
}

public enum EngineEvent: Sendable, Equatable {
    case sessionStarted(SessionInfo)
    case commands([SlashCommandInfo])
    /// Streaming text for the assistant message `messageID`; the finished
    /// block follows as `.block`.
    case textDelta(messageID: String, text: String)
    case block(messageID: String, AssistantBlock)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    case approval(ApprovalRequest)
    case permissionModeChanged(PermissionMode)
    case modelChanged(String)
    /// "requesting", "thinking", … — a status line, not content.
    case status(String)
    case turnFinished(TurnResult)
    /// Something the CLI printed that could not be understood, or a crash.
    case error(String)
    case exited(code: Int32)
}

/// Stands in when no CLI was found: starting it fails with a clear reason.
@MainActor
final class UnavailableEngine: HarnessEngine {
    struct NotInstalled: LocalizedError {
        var errorDescription: String? { "Claude Code isn't installed or wasn't found on your PATH." }
    }

    let events = AsyncStream<EngineEvent> { $0.finish() }
    func start(_ options: EngineStartOptions) throws { throw NotInstalled() }
    func send(_ text: String, images: [EngineImage]) throws { throw NotInstalled() }
    func interrupt() throws {}
    func answer(_ request: ApprovalRequest, with decision: ApprovalDecision) throws {}
    func setPermissionMode(_ mode: PermissionMode) throws {}
    func setModel(_ model: String) throws {}
    func stop() {}
}
