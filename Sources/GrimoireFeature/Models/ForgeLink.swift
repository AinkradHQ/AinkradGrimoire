import AinkradAppKit
import Foundation

/// What Grimoire tells Forge (E5), in the encoding Forge reads: a turn notice after each turn, and `openDocument`
/// launches for "Open in Forge" and "Review in Forge".
enum ForgeLink {
    static let appID = "forge"
    /// Forge's `AgentTurn.kind` and `AgentTurn.notification`.
    static let turnKind = "agentTurn"
    static let turnNotification = Notification.Name("com.ainkrad.agentTurn")

    /// The turn notice Forge reads (its `AgentTurn`): the thread, the turn's number (its user messages so far), the
    /// request, and the files its edit tools wrote. Nil when the turn wrote nothing.
    static func turnNotice(
        entries: [ThreadEntry], root: String, thread: String, agent: String, startedAt: Date, endedAt: Date
    ) -> String? {
        let files = ReviewChanges.fromEntries(entries, scope: .turn, workingDirectory: root).map { absolute($0.path, in: root) }
        guard !files.isEmpty else { return nil }
        let prompts = entries.compactMap { if case .user(let text) = $0 { text } else { nil } }
        let body: [String: Any] = [
            "kind": turnKind, "root": root, "thread": thread, "turn": max(prompts.count, 1), "agent": agent,
            "prompt": prompts.last.map { String($0.prefix(240)) } ?? "", "files": files,
            "startedAt": startedAt.timeIntervalSince1970, "endedAt": endedAt.timeIntervalSince1970,
        ]
        return json(body)
    }

    /// Forge's `ForgeLaunch`: open `path` (a file, at `line`), or the folder's review of outside changes.
    static func openPayload(path: String, line: Int? = nil, review: Bool = false) -> String? {
        var body: [String: Any] = ["kind": AinkradLaunchIntent.openDocumentKind, "path": path]
        if let line { body["line"] = max(1, line) }
        if review { body["review"] = true }
        return json(body)
    }

    static func absolute(_ path: String, in directory: String) -> String {
        path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
    }

    private static func json(_ body: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// A place in a file that Grimoire shows: a Grep hit, a Read range, an edit.
struct FileLocation: Equatable {
    let path: String
    var line: Int?

    /// A Grep content line, `path:12:text` (ripgrep with line numbers): its place and its text. Nil for any other line
    /// (a file list, a `--` separator, context lines `path-12-text`).
    static func grepHit(_ line: Substring) -> (location: FileLocation, text: Substring)? {
        var parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, let number = Int(parts[1]), number > 0 else { return nil }
        let text = parts.removeLast()
        return (FileLocation(path: String(parts[0]), line: number), text)
    }

    /// The 1-based line in `file` where `lines` (an edit's new side) start, or nil when they are not there (the file
    /// moved on). Edits name no line numbers, so an edit's place is found by its text.
    static func line(of lines: [String], in file: String) -> Int? {
        let needle = lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = needle.first else { return nil }
        // Any line break, CRLF included: a "\n" split left "\r" on each line of a CRLF file, so nothing matched (GD49).
        let haystack = file.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        for index in haystack.indices where haystack[index] == first {
            if Array(haystack[index...].prefix(needle.count)) == Array(needle) {
                return index + 1 - (lines.count - needle.count)
            }
        }
        return nil
    }
}
