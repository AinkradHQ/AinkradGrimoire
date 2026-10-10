import Foundation

/// Codex's threads, read through its own app-server (`thread/list`,
/// `thread/read`) rather than its rollout files, whose format is internal.
/// Each call runs a short-lived `codex app-server`; call off the main thread.
enum CodexSessions {
    /// Every stored thread as a summary, newest first (at most `limit`).
    static func summaries(executable: URL, environment: [String: String], limit: Int = 200) -> [ClaudeSessionSummary] {
        guard let server = try? OneShotServer(executable: executable, environment: environment) else { return [] }
        defer { server.close() }
        var summaries: [ClaudeSessionSummary] = []
        var cursor: JSONValue = .null
        repeat {
            guard let page = server.call("thread/list", ["limit": .number(100), "cursor": cursor]) else { break }
            summaries += (page["data"]?.arrayValue ?? []).compactMap(summary)
            cursor = page["nextCursor"] ?? .null
        } while cursor != .null && summaries.count < limit
        return summaries
    }

    /// A stored thread's history as transcript rows.
    static func history(threadID: String, executable: URL, environment: [String: String]) -> [TranscriptItem] {
        guard let server = try? OneShotServer(executable: executable, environment: environment) else { return [] }
        defer { server.close() }
        guard let result = server.call("thread/read", ["threadId": .string(threadID), "includeTurns": true]),
            let thread = result["thread"]
        else { return [] }
        return CodexProtocol.transcript(thread)
    }

    static func summary(_ thread: JSONValue) -> ClaudeSessionSummary? {
        guard let id = thread["id"]?.stringValue, let cwd = thread["cwd"]?.stringValue else { return nil }
        let (project, worktree) = ClaudeSessions.splitWorktree(cwd)
        let title = thread["name"]?.stringValue ?? thread["preview"]?.stringValue.map { String($0.prefix(80)) } ?? "Untitled"
        return ClaudeSessionSummary(
            id: id, harness: .codex, fileURL: URL(fileURLWithPath: thread["path"]?.stringValue ?? "/dev/null"),
            workingDirectory: cwd, projectPath: project, worktree: worktree,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title,
            gitBranch: thread["gitInfo"]?["branch"]?.stringValue, model: thread["model"]?.stringValue,
            lastActivity: Date(timeIntervalSince1970: thread["updatedAt"]?.doubleValue ?? 0))
    }
}

/// A blocking JSON-RPC client over one `codex app-server` process: initialize,
/// a few calls, close.
private final class OneShotServer {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = LineBuffer()
    private var lines: [String] = []
    private var nextID = 0

    init(executable: URL, environment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment.isEmpty ? nil : environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = call("initialize", ["clientInfo": ["name": "grimoire", "title": "Grimoire", "version": "0.1.0"], "capabilities": .null])
        send(["jsonrpc": "2.0", "method": "initialized"])
    }

    /// The `result` of a call, or nil on an error or a closed pipe.
    func call(_ method: String, _ params: JSONValue) -> JSONValue? {
        nextID += 1
        let id = nextID
        send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        while let line = nextLine() {
            guard let message = try? JSONValue.parse(line), message["method"] == nil,
                message["id"]?.doubleValue == Double(id)
            else { continue }
            return message["result"]
        }
        return nil
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private func send(_ message: JSONValue) {
        guard let line = try? message.line() else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    private func nextLine() -> String? {
        while lines.isEmpty {
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { return nil }
            lines += buffer.append(data)
        }
        return lines.removeFirst()
    }
}
