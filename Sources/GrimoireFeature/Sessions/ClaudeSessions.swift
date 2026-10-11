import Foundation

/// The coding-agent CLIs Grimoire can drive.
public enum Harness: String, Sendable, CaseIterable {
    case claude
    case codex
    case opencode
    case agy

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .agy: "agy"
        }
    }

    /// The executable's name on the PATH.
    var command: String { rawValue }
}

/// A model an agent offers: `id` goes on the wire, `name` in menus.
public struct ModelChoice: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
}

/// What a non-Claude CLI's lister found: whether it's installed, its stored
/// threads, the models it offers, and its rate-limit windows if it reports them.
struct AgentListing: Sendable, Equatable {
    var status: CLIStatus
    var threads: [ClaudeSessionSummary] = []
    var models: [ModelChoice] = []
    var usage: [UsageWindow] = []
}

/// One agent session (Claude Code or Codex), as listed in a project: enough to show the row and
/// to `--resume` it. Read from the CLI's own file, so a thread started in the
/// terminal shows up here and vice versa.
public struct ClaudeSessionSummary: Sendable, Equatable, Identifiable {
    public var id: String
    /// Which CLI owns the session.
    public var harness: Harness = .claude
    public var fileURL: URL
    /// The directory the session ran in — the worktree's, for a worktree session.
    public var workingDirectory: String
    /// The repository the session belongs to: `workingDirectory`, or the main
    /// checkout when the session ran in one of the CLI's worktrees.
    public var projectPath: String
    /// The worktree's name when the session ran in `<repo>/.claude/worktrees/<name>`.
    public var worktree: String?
    public var title: String
    public var gitBranch: String?
    public var model: String?
    public var lastActivity: Date
}

/// A working directory with its sessions, newest first.
public struct ClaudeProject: Sendable, Equatable, Identifiable {
    public var path: String
    public var sessions: [ClaudeSessionSummary]
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var lastActivity: Date { sessions.first?.lastActivity ?? .distantPast }
}

/// Lists `~/.claude/projects/<slug>/<session>.jsonl`. Session files run to
/// megabytes, so a summary reads only the head (working directory, first
/// prompt) and the tail (latest title, model, branch) of each.
public enum ClaudeSessions {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    static let window = 64 * 1024

    /// Every project with at least one session, most recently active first.
    public static func projects(root: URL = defaultRoot) -> [ClaudeProject] {
        let fileManager = FileManager.default
        let directories = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var sessions: [ClaudeSessionSummary] = []
        for directory in directories {
            let files =
                (try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
            sessions += files.filter { $0.pathExtension == "jsonl" }.compactMap(summary(of:))
        }
        return grouped(sessions)
    }

    /// Sessions of any harness grouped by project, newest first.
    static func grouped(_ sessions: [ClaudeSessionSummary]) -> [ClaudeProject] {
        Dictionary(grouping: sessions, by: \.projectPath).map { path, sessions in
            ClaudeProject(path: path, sessions: sessions.sorted { $0.lastActivity > $1.lastActivity })
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    // ponytail: re-reads every file's head and tail on each call; cache by (path, mtime, size) if listing gets slow.
    static func summary(of file: URL) -> ClaudeSessionSummary? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: window)) ?? Data()
        var tail = Data()
        if size > UInt64(window) {
            try? handle.seek(toOffset: size - UInt64(window))
            tail = (try? handle.read(upToCount: window)) ?? Data()
        }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return summarize(
            id: file.deletingPathExtension().lastPathComponent, fileURL: file, head: head, tail: tail,
            lastActivity: modified ?? .distantPast)
    }

    /// Pure: builds the summary from the file's first and last bytes. `tail` is
    /// empty when the head already holds the whole file. Lines are decoded
    /// lazily — the head front to back until the working directory and first
    /// prompt turn up, the tail back to front for the latest title, model and
    /// branch — and only when their raw bytes mention what is wanted.
    static func summarize(id: String, fileURL: URL, head: Data, tail: Data, lastActivity: Date)
        -> ClaudeSessionSummary?
    {
        // The head's last line and the tail's first line may be cut mid-way.
        let headChunks = chunks(head, dropFirst: false, dropLast: !tail.isEmpty)
        let tailChunks = tail.isEmpty ? headChunks : chunks(tail, dropFirst: true, dropLast: false)

        var workingDirectory: String?
        var firstPrompt: String?
        for chunk in headChunks where workingDirectory == nil || firstPrompt == nil {
            guard let line = parse(chunk) else { continue }
            if workingDirectory == nil { workingDirectory = line["cwd"]?.stringValue }
            if firstPrompt == nil { firstPrompt = humanPrompt(line) }
        }
        guard let workingDirectory else { return nil }

        var customTitle: String?
        var aiTitle: String?
        var model: String?
        var branch: String?
        // Newest first; a custom title is rare and may sit in the head only.
        for chunk in tailChunks.reversed() + headChunks.reversed() {
            if customTitle == nil, chunk.range(of: Marker.customTitle) != nil {
                customTitle = parse(chunk)?["customTitle"]?.stringValue
            }
            if aiTitle == nil, chunk.range(of: Marker.aiTitle) != nil {
                aiTitle = parse(chunk)?["aiTitle"]?.stringValue
            }
            if model == nil, chunk.range(of: Marker.assistant) != nil {
                model = parse(chunk)?["message"]?["model"]?.stringValue
            }
            if branch == nil, chunk.range(of: Marker.gitBranch) != nil {
                branch = parse(chunk)?["gitBranch"]?.stringValue
            }
        }
        let title = customTitle ?? aiTitle ?? firstPrompt.map { String($0.prefix(80)) } ?? "Untitled"
        let (projectPath, worktree) = splitWorktree(workingDirectory)
        return ClaudeSessionSummary(
            id: id, fileURL: fileURL, workingDirectory: workingDirectory, projectPath: projectPath, worktree: worktree,
            title: title, gitBranch: branch.flatMap { $0.isEmpty ? nil : $0 }, model: model,
            lastActivity: lastActivity)
    }

    private enum Marker {
        static let customTitle = Data(#""type":"custom-title""#.utf8)
        static let aiTitle = Data(#""type":"ai-title""#.utf8)
        static let assistant = Data(#""type":"assistant""#.utf8)
        static let gitBranch = Data(#""gitBranch":"#.utf8)
    }

    /// `<repo>/.claude/worktrees/<name>[/…]` → (`<repo>`, `<name>`); anything else is its own project.
    static func splitWorktree(_ path: String) -> (project: String, worktree: String?) {
        guard let marker = path.range(of: "/.claude/worktrees/") else { return (path, nil) }
        let name = path[marker.upperBound...].split(separator: "/").first.map(String.init)
        return (String(path[..<marker.lowerBound]), name)
    }

    /// A prompt the person typed, as opposed to tool results and injected context.
    static func humanPrompt(_ line: JSONValue) -> String? {
        guard line["type"]?.stringValue == "user", line["isMeta"]?.boolValue != true,
            line["origin"]?["kind"]?.stringValue == "human",
            let text = line["message"]?["content"]?.stringValue,
            !text.isEmpty
        else { return nil }
        return text
    }

    static func chunks(_ data: Data, dropFirst: Bool, dropLast: Bool) -> [Data] {
        var chunks = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        if dropFirst, !chunks.isEmpty { chunks.removeFirst() }
        if dropLast, !chunks.isEmpty { chunks.removeLast() }
        return chunks
    }

    static func parse(_ chunk: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: chunk)
    }

    static func lines(_ data: Data, dropFirst: Bool, dropLast: Bool) -> [JSONValue] {
        chunks(data, dropFirst: dropFirst, dropLast: dropLast).compactMap(parse)
    }
}
