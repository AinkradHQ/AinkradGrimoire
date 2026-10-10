import Foundation

/// OpenCode's sessions, read through its server (`GET /session`,
/// `GET /session/{id}/message`) rather than its SQLite store.
enum OpenCodeSessions {
    /// Top-level sessions across every project, newest first.
    static func summaries(server: OpenCodeServer, limit: Int = 200) async -> [ClaudeSessionSummary] {
        guard let sessions = try? await server.call("GET", "/session?roots=true&limit=\(limit)", directory: nil) else {
            return []
        }
        return (sessions.arrayValue ?? []).compactMap(OpenCodeProtocol.summary)
    }

    static func history(of thread: ClaudeSessionSummary, server: OpenCodeServer) async -> [TranscriptItem] {
        guard
            let messages = try? await server.call(
                "GET", "/session/\(thread.id)/message", directory: thread.workingDirectory)
        else { return [] }
        return OpenCodeProtocol.transcript(messages)
    }
}

/// The app's one `OpenCodeServer`, made when `opencode` is first found.
final class OpenCodeServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var server: OpenCodeServer?

    func server(executable: URL, environment: [String: String]) -> OpenCodeServer {
        lock.withLock {
            if let server { return server }
            let made = OpenCodeServer(executable: executable, environment: environment)
            server = made
            return made
        }
    }

    var current: OpenCodeServer? { lock.withLock { server } }
}
