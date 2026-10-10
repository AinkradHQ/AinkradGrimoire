import Foundation
import SQLite3

/// agy's conversations, listed from its own `conversation_summaries.db`
/// (opened read-only). A conversation's steps are stored as internal protobuf
/// blobs, so earlier turns aren't read back — only new ones show.
enum AgySessions {
    static var defaultDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")
    }

    /// Top-level conversations, newest first.
    static func summaries(database: URL = defaultDatabase, limit: Int = 200) -> [ClaudeSessionSummary] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let query = """
            SELECT conversation_id, title, last_modified_time, workspace_uris FROM conversation_summaries
            WHERE nesting_depth = 0 ORDER BY last_modified_time DESC LIMIT \(limit)
            """
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var summaries: [ClaudeSessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func column(_ index: Int32) -> String {
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            }
            if let summary = summary(id: column(0), title: column(1), modified: column(2), workspaces: column(3)) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    /// One row: `workspace_uris` is a JSON array of `file://` URIs, the first
    /// being where the conversation ran; times read `2026-10-10 18:41:04.859319+00:00`.
    static func summary(id: String, title: String, modified: String, workspaces: String) -> ClaudeSessionSummary? {
        guard !id.isEmpty, let first = (try? JSONValue.parse(workspaces))?.arrayValue?.first?.stringValue,
            let directory = URL(string: first)?.path, !directory.isEmpty
        else { return nil }
        let (project, worktree) = ClaudeSessions.splitWorktree(directory)
        return ClaudeSessionSummary(
            id: id, harness: .agy, fileURL: URL(fileURLWithPath: "/dev/null"), workingDirectory: directory,
            projectPath: project, worktree: worktree, title: title.isEmpty ? "Untitled" : String(title.prefix(80)),
            model: nil, lastActivity: date(modified) ?? .distantPast)
    }

    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: String(text.prefix(19)))
    }
}
