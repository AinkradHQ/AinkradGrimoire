import Foundation
import Testing

@testable import GrimoireFeature

/// Synthetic session files in Claude Code's on-disk shape (one JSON object per
/// line). No real transcripts: this repo is public.
private enum Line {
    static func human(_ text: String, cwd: String = "/repo", branch: String = "main") -> String {
        #"{"type":"user","cwd":"\#(cwd)","gitBranch":"\#(branch)","origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"}}"#
    }
    static func meta(_ text: String) -> String {
        #"{"type":"user","cwd":"/repo","isMeta":true,"message":{"role":"user","content":"\#(text)"}}"#
    }
    static func assistant(_ text: String, model: String = "claude-opus-5-5", sidechain: Bool = false) -> String {
        #"{"type":"assistant","cwd":"/repo","isSidechain":\#(sidechain),"message":{"id":"m","model":"\#(model)","content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    static func toolUse(_ name: String) -> String {
        #"{"type":"assistant","cwd":"/repo","message":{"id":"m","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"\#(name)","input":{"command":"ls"}}]}}"#
    }
    static func toolResult(_ text: String) -> String {
        #"{"type":"user","cwd":"/repo","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"\#(text)"}],"is_error":true}]}}"#
    }
    static func aiTitle(_ title: String) -> String { #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"s"}"# }
    static func customTitle(_ title: String) -> String {
        #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"s"}"#
    }
    static let bookkeeping = #"{"type":"permission-mode","permissionMode":"default","sessionId":"s"}"#
}

@Suite("ClaudeSessions")
struct ClaudeSessionsTests {
    private func summarize(_ lines: [String], tail: [String]? = nil) -> ClaudeSessionSummary? {
        ClaudeSessions.summarize(
            id: "s", fileURL: URL(fileURLWithPath: "/x/s.jsonl"), head: Data(lines.joined(separator: "\n").utf8),
            tail: Data((tail ?? []).joined(separator: "\n").utf8), lastActivity: .distantPast)
    }

    @Test("title prefers a custom title, then the AI title, then the first typed prompt")
    func titles() {
        let base = [Line.meta("<context>"), Line.human("fix the login bug"), Line.assistant("ok")]
        #expect(summarize(base)?.title == "fix the login bug")
        #expect(summarize(base + [Line.aiTitle("Old"), Line.aiTitle("Login bug fix")])?.title == "Login bug fix")
        #expect(summarize(base + [Line.customTitle("Mine"), Line.aiTitle("Later AI title")])?.title == "Mine")
        #expect(summarize([Line.bookkeeping, Line.assistant("hi")])?.title == "Untitled")
    }

    @Test("working directory, branch and the latest model come from the file")
    func fields() {
        let summary = summarize([
            Line.human("go", cwd: "/work/app", branch: "feat/x"), Line.assistant("a", model: "claude-haiku-5-5"),
            Line.assistant("b", model: "claude-sonnet-5-5"),
        ])
        #expect(summary?.workingDirectory == "/work/app")
        #expect(summary?.projectPath == "/work/app")
        #expect(summary?.worktree == nil)
        #expect(summary?.gitBranch == "feat/x")
        #expect(summary?.model == "claude-sonnet-5-5")
        #expect(summarize([Line.bookkeeping]) == nil, "no working directory: not a session we can resume")
    }

    @Test("lines cut at the head/tail window edges are dropped, not misread")
    func windows() {
        let head = [Line.human("start"), Line.assistant("x")].joined(separator: "\n") + "\n" + #"{"type":"assist"#
        let tail =
            #"ant","message":{}}"# + "\n" + Line.aiTitle("Tail title") + "\n" + Line.assistant("y", model: "late")
        let summary = ClaudeSessions.summarize(
            id: "s", fileURL: URL(fileURLWithPath: "/x/s.jsonl"), head: Data(head.utf8), tail: Data(tail.utf8),
            lastActivity: .distantPast)
        #expect(summary?.title == "Tail title")
        #expect(summary?.model == "late")
    }

    @Test("a session in the CLI's worktree belongs to the main checkout")
    func worktrees() {
        #expect(ClaudeSessions.splitWorktree("/repo/.claude/worktrees/fix-ci") == ("/repo", "fix-ci"))
        #expect(ClaudeSessions.splitWorktree("/repo/.claude/worktrees/fix-ci/sub") == ("/repo", "fix-ci"))
        #expect(ClaudeSessions.splitWorktree("/repo") == ("/repo", nil))
        let summary = summarize([Line.human("go", cwd: "/repo/.claude/worktrees/w1")])
        #expect(summary?.projectPath == "/repo")
        #expect(summary?.worktree == "w1")
    }

    @Test("a projects directory groups sessions by repository, newest first")
    func scan() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-sessions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ slug: String, _ id: String, _ lines: [String], age: TimeInterval) throws {
            let directory = root.appendingPathComponent(slug)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(id).jsonl")
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
        }
        try write("-a", "old", [Line.human("old one", cwd: "/a")], age: 300)
        try write("-a", "new", [Line.human("new one", cwd: "/a")], age: 10)
        try write("-a-claude-worktrees-w", "wt", [Line.human("in a worktree", cwd: "/a/.claude/worktrees/w")], age: 5)
        try write("-b", "b1", [Line.human("other", cwd: "/b")], age: 100)
        try write("-b", "empty", [Line.bookkeeping], age: 1)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("-b/b1/subagents"), withIntermediateDirectories: true)
        try "not a session".write(to: root.appendingPathComponent("-b/notes.txt"), atomically: true, encoding: .utf8)

        let projects = ClaudeSessions.projects(root: root)
        #expect(projects.map(\.path) == ["/a", "/b"])
        #expect(projects.first?.sessions.map(\.id) == ["wt", "new", "old"])
        #expect(projects.first?.sessions.first?.worktree == "w")
        #expect(projects.last?.sessions.map(\.id) == ["b1"])
        #expect(projects.first?.name == "a")
    }

    @Test("history keeps prompts, assistant blocks and tool results; drops context, subagents and bookkeeping")
    func history() {
        let data = Data(
            [
                Line.meta("<system-reminder>"), Line.human("list files"), Line.toolUse("Bash"),
                Line.toolResult("permission denied"), Line.assistant("subagent noise", sidechain: true),
                Line.assistant("Done."), Line.bookkeeping, "garbage line",
            ]
            .joined(separator: "\n").utf8)
        let items = ClaudeSessions.history(data)
        #expect(
            items == [
                .user("list files"),
                .assistant(.toolUse(id: "t1", name: "Bash", input: ["command": "ls"])),
                .toolResult(toolUseID: "t1", content: "permission denied", isError: true),
                .assistant(.text("Done.")),
            ])
    }

    @Test("a worktree is requested only for a new session")
    func worktreeArgument() {
        let fresh = ClaudeProtocol.arguments(
            for: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo"), worktree: "fix-ci"))
        #expect(fresh.suffix(2) == ["--worktree", "fix-ci"])
        let resumed = ClaudeProtocol.arguments(
            for: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo"), resume: "s", worktree: "fix-ci"))
        #expect(!resumed.contains("--worktree"))
    }

    /// Reads the real `~/.claude/projects`. Opt-in: it depends on this machine.
    @Test(
        "the real session store lists and every summary's history parses",
        .enabled(if: ProcessInfo.processInfo.environment["GRIMOIRE_LIVE"] == "1"))
    func realStore() throws {
        let started = ContinuousClock.now
        let projects = ClaudeSessions.projects()
        let elapsed = ContinuousClock.now - started
        #expect(!projects.isEmpty)
        #expect(elapsed < .milliseconds(1500), "listing took \(elapsed)")
        let newest = try #require(projects.first?.sessions.first)
        #expect(!newest.title.isEmpty)
        #expect(try !ClaudeSessions.history(of: newest.fileURL).isEmpty)
    }
}
