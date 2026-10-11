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

    /// Each connected provider's default model, then models recent sessions
    /// used — the full catalogue runs to a thousand, too many for a menu.
    static func models(server: OpenCodeServer, recent: [ClaudeSessionSummary]) async -> [ModelChoice] {
        let providers = (try? await server.call("GET", "/config/providers", directory: nil)) ?? .null
        var names: [String: String] = [:]
        for provider in providers["providers"]?.arrayValue ?? [] {
            guard let providerID = provider["id"]?.stringValue, case .object(let models)? = provider["models"] else { continue }
            for (id, model) in models { names["\(providerID)/\(id)"] = model["name"]?.stringValue ?? id }
        }
        var ids: [String] = []
        if case .object(let defaults)? = providers["default"] {
            ids = defaults.keys.sorted().compactMap { provider in defaults[provider]?.stringValue.map { "\(provider)/\($0)" } }
        }
        ids += recent.compactMap(\.model)
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }.map { ModelChoice(id: $0, name: names[$0] ?? $0) }
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
