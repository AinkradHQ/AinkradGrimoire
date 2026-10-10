import Foundation

/// OpenCode as a `HarnessEngine`: one session on the shared `opencode serve`,
/// driven over HTTP and its event stream with `OpenCodeProtocol`.
@MainActor
public final class OpenCodeEngine: HarnessEngine {
    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let server: OpenCodeServer
    private var wire = OpenCodeProtocol()
    private var directory: String?
    private var listening: Task<Void, Never>?
    /// Messages sent before the session exists; sent once it does.
    private var queued: [(String, [EngineImage])] = []

    public enum Failure: Error, Equatable {
        case notStarted
        case alreadyStarted
    }

    init(server: OpenCodeServer) {
        self.server = server
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
    }

    public func start(_ options: EngineStartOptions) throws {
        guard directory == nil else { throw Failure.alreadyStarted }
        let directory = options.workingDirectory.path
        self.directory = directory
        wire.mode = options.permissionMode ?? wire.mode
        wire.model = options.model
        listening = Task { [weak self] in await self?.run(options, directory: directory) }
    }

    private func run(_ options: EngineStartOptions, directory: String) async {
        do {
            let stream = try await server.events(directory: directory)
            let permission = OpenCodeProtocol.permission(for: wire.mode)
            let session: JSONValue
            switch (options.resume, options.fork) {
            case (let id?, true):
                session = try await server.call("POST", "/session/\(id)/fork", directory: directory, body: [:])
                _ = try await server.call(
                    "PATCH", "/session/\(session["id"]?.stringValue ?? id)", directory: directory,
                    body: ["permission": permission])
            case (let id?, false):
                session = try await server.call(
                    "PATCH", "/session/\(id)", directory: directory, body: ["permission": permission])
            case (nil, _):
                session = try await server.call("POST", "/session", directory: directory, body: ["permission": permission])
            }
            guard let id = session["id"]?.stringValue else { throw OpenCodeServer.Failure.http(200, "no session id") }
            wire.sessionID = id
            continuation.yield(
                .sessionStarted(
                    SessionInfo(
                        sessionID: id, model: wire.model ?? OpenCodeProtocol.summary(session)?.model ?? "",
                        permissionMode: wire.mode, workingDirectory: directory, tools: [])))
            flushQueued()
            for try await event in stream {
                for decoded in wire.decode(event) { continuation.yield(decoded) }
            }
            finish(code: 0)
        } catch is CancellationError {
            finish(code: 0)
        } catch {
            if !Task.isCancelled { continuation.yield(.error(String(describing: error))) }
            finish(code: Task.isCancelled ? 0 : 1)
        }
    }

    public func send(_ text: String, images: [EngineImage]) throws {
        guard directory != nil else { throw Failure.notStarted }
        guard let id = wire.sessionID else {
            queued.append((text, images))
            return
        }
        post("/session/\(id)/prompt_async", wire.prompt(text, images: images))
    }

    public func interrupt() throws {
        guard let id = wire.sessionID else { return }
        post("/session/\(id)/abort", nil)
    }

    public func answer(_ request: ApprovalRequest, with decision: ApprovalDecision) throws {
        post("/permission/\(request.id)/reply", OpenCodeProtocol.answer(decision))
    }

    /// The session's rules change now; the agent (plan or build) with the next prompt.
    public func setPermissionMode(_ mode: PermissionMode) throws {
        wire.mode = mode
        if let id = wire.sessionID {
            post("/session/\(id)", ["permission": OpenCodeProtocol.permission(for: mode)], method: "PATCH")
        }
        continuation.yield(.permissionModeChanged(mode))
    }

    public func setModel(_ model: String) throws {
        wire.model = model
        continuation.yield(.modelChanged(model))
    }

    /// Leaves the session to OpenCode; only this thread's event stream closes.
    public func stop() {
        listening?.cancel()
        listening = nil
    }

    private func post(_ path: String, _ body: JSONValue?, method: String = "POST") {
        let directory = directory
        Task { [weak self, server] in
            do {
                _ = try await server.call(method, path, directory: directory, body: body)
            } catch {
                self?.continuation.yield(.error(String(describing: error)))
            }
        }
    }

    private func finish(code: Int32) {
        continuation.yield(.exited(code: code))
        continuation.finish()
    }

    private func flushQueued() {
        let pending = queued
        queued = []
        for (text, images) in pending { try? send(text, images: images) }
    }
}
