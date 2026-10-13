import Foundation
import Testing

@testable import GrimoireFeature

@Suite("ReviewChanges")
struct ReviewChangesTests {
    @Test("git diff output parses into files, statuses and hunks")
    func unifiedDiff() {
        let diff = """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1,3 +1,4 @@
             let a = 1
            -let b = 2
            +let b = 3
            +let c = 4
             print(a)
            \\ No newline at end of file
            diff --git a/New.md b/New.md
            new file mode 100644
            --- /dev/null
            +++ b/New.md
            @@ -0,0 +1 @@
            +hello
            diff --git a/Gone.txt b/Gone.txt
            deleted file mode 100644
            --- a/Gone.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -bye
            diff --git a/logo.png b/logo.png
            Binary files a/logo.png and b/logo.png differ

            """
        let files = ReviewChanges.parseUnifiedDiff(diff)
        #expect(files.map(\.path) == ["Sources/A.swift", "New.md", "Gone.txt", "logo.png"])
        #expect(files.map(\.status) == [.modified, .added, .deleted, .modified])
        #expect(files[0].added == 2 && files[0].removed == 1)
        #expect(files[0].diff?.hunks.first?.lines.count == 5)
        #expect(files[0].diff?.hunks.first?.lines.last?.newNumber == 4)
        #expect(files[1].added == 1 && files[2].removed == 1)
        #expect(files[3].diff == nil)
    }

    @Test("hunk headers, with and without counts")
    func hunkHeaders() {
        #expect(ReviewChanges.hunkHeader("@@ -12,3 +12,5 @@ func x()")! == (12, 3, 12, 5))
        #expect(ReviewChanges.hunkHeader("@@ -1 +1 @@")! == (1, 1, 1, 1))
        #expect(ReviewChanges.hunkHeader("not a header") == nil)
    }

    @Test("untracked paths come from porcelain status")
    func untracked() {
        #expect(
            ReviewChanges.untracked(fromPorcelain: " M a.swift\n?? new.txt\n?? dir/b.md\n") == ["new.txt", "dir/b.md"])
    }

    @Test("this turn: edits since your last message; whole thread: all of them, merged per file")
    func fromEntries() {
        func edit(_ id: String, _ path: String, _ old: String, _ new: String) -> ThreadEntry {
            .tool(
                ToolCall(
                    id: id, name: "Edit",
                    input: ["file_path": .string(path), "old_string": .string(old), "new_string": .string(new)],
                    result: ToolOutput(content: "ok", isError: false)))
        }
        let entries: [ThreadEntry] = [
            .user("first"), edit("1", "/r/A.swift", "a", "b"),
            .tool(
                ToolCall(
                    id: "2", name: "Write", input: ["file_path": "/r/New.md", "content": "x\ny"],
                    result: ToolOutput(content: "ok", isError: false))),
            .user("second"), edit("3", "/r/A.swift", "c", "d"),
            .tool(
                ToolCall(
                    id: "4", name: "Edit",
                    input: ["file_path": "/r/Failed.swift", "old_string": "a", "new_string": "b"],
                    result: ToolOutput(content: "no match", isError: true))),
        ]
        let turn = ReviewChanges.fromEntries(entries, scope: .turn, workingDirectory: "/r")
        #expect(turn.map(\.path) == ["A.swift"])
        let thread = ReviewChanges.fromEntries(entries, scope: .thread, workingDirectory: "/r")
        #expect(thread.map(\.path) == ["A.swift", "New.md"])
        #expect(thread[0].diff?.hunks.map(\.id) == [0, 1], "two edits, two hunks, distinct ids")
        #expect(thread[1].status == .added && thread[1].added == 2)
    }

    @Test("queued comments become one message: file:line, the line quoted, the comment, then your message")
    func message() {
        let comments = [
            ReviewComment(path: "A.swift", line: 58, quote: "    .overlay { Rectangle() }", text: "use the kit"),
            ReviewComment(path: "B.swift", line: nil, quote: "", text: "rename"),
        ]
        #expect(
            ReviewChanges.message(for: comments)
                == "Review comments on your changes:\n- A.swift:58\n  > .overlay { Rectangle() }\n  use the kit\n- B.swift\n  rename")
        #expect(ReviewChanges.message(for: comments, then: "Then push.").hasSuffix("  rename\n\nThen push."))
    }

    @MainActor
    @Test("GD35: the keyboard's line starts on the first change and ↑↓ walk every line across hunks, kept in range")
    func keyboardLines() {
        let diff = ReviewChanges.parseUnifiedDiff(
            "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n@@ -9 +9 @@\n-x\n+y\n")[0].diff!
        let places = DiffBlock.places(diff)
        #expect(places.map { $0.hunk.lines[$0.index].text } == ["keep", "old", "new", "x", "y"])
        #expect(DiffBlock.firstChange(places) == 1)
        #expect(DiffBlock.move(2, .down, count: places.count) == 3, "into the next hunk")
        #expect(DiffBlock.move(4, .down, count: places.count) == 4)
        #expect(DiffBlock.move(0, .up, count: places.count) == 0)
        #expect(DiffBlock.move(3, .left, count: places.count) == 3)
    }

    @MainActor
    @Test("comments wait on the thread and go ahead of the next message, or alone with Send")
    func commentsGoWithTheNextMessage() async {
        let engine = FakeEngine()
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/nowhere")),
            makeEngine: { engine })
        let review = ReviewModel(live: live, workingDirectory: "/nowhere", environment: [:])
        review.addComment("  ", on: "A.swift", line: 3, quote: "x")
        review.addComment("use the kit", on: "A.swift", line: 3, quote: "let x = 1")
        #expect(review.comments.count == 1)
        live.send("Also run the tests.")
        #expect(engine.sent == ["Review comments on your changes:\n- A.swift:3\n  > let x = 1\n  use the kit\n\nAlso run the tests."])
        #expect(review.comments.isEmpty)
        review.addComment("rename", on: "B.swift")
        review.sendComments()
        #expect(engine.sent.last == "Review comments on your changes:\n- B.swift\n  rename")
        // A CRLF file's line is quoted without its "\r".
        review.addComment("why?", on: "C.txt", line: 2, quote: "row two\r")
        #expect(review.comments.first?.quote == "row two")
        review.sendComments()
        #expect(engine.sent.last == "Review comments on your changes:\n- C.txt:2\n  > row two\n  why?")
    }
}

@MainActor
@Suite("ReviewModel (real git)")
struct ReviewModelGitTests {
    @Test("uncommitted changes list, revert, and commit in a scratch repository")
    func uncommitted() async throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-review-\(UUID())")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let environment = CLILocator.loginEnvironment()
        let git = Git(directory: repo.path, environment: environment)
        _ = try await git.run(["init", "-q"])
        _ = try await git.run([
            "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "root",
        ])
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "a.txt"])
        _ = try await git.run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "a"])

        try "two\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: repo), makeEngine: { FakeEngine() })
        let review = ReviewModel(live: live, workingDirectory: repo.path, environment: environment)
        review.scope = .uncommitted
        await review.load()
        #expect(review.error == nil)
        #expect(review.files.map(\.path) == ["a.txt", "b.txt"])
        #expect(review.files.map(\.status) == [.modified, .untracked])

        await review.revert(review.files[0])
        #expect(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")
        #expect(review.files.map(\.path) == ["b.txt"])

        _ = try await git.run(["config", "user.email", "t@t"])
        _ = try await git.run(["config", "user.name", "t"])
        review.commitMessage = "add b"
        await review.commit()
        #expect(review.error == nil)
        #expect(review.files.isEmpty)
        #expect(review.commitMessage.isEmpty)
        #expect(
            try await git.run(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines) == "add b")
    }
}

@MainActor
@Suite("ReviewModel commit scope (real git)")
struct ReviewCommitScopeTests {
    private func repo() async throws -> (URL, Git, [String: String]) {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-scope-\(UUID())")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let environment = CLILocator.loginEnvironment()
        let git = Git(directory: repo.path, environment: environment)
        _ = try await git.run(["init", "-q", "-b", "development"])
        _ = try await git.run(["config", "user.email", "t@t"])
        _ = try await git.run(["config", "user.name", "t"])
        for name in ["a.txt", "b.txt"] {
            try "one\n".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        _ = try await git.run(["add", "."])
        _ = try await git.run(["commit", "-q", "-m", "root"])
        return (repo, git, environment)
    }

    @Test("committing this turn leaves the repository's other changes alone")
    func commitsOnlyTheShownFiles() async throws {
        let (repo, git, environment) = try await repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "two\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: repo.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)
        let edit = ThreadEntry.tool(
            ToolCall(
                id: "1", name: "Edit",
                input: ["file_path": .string(repo.appendingPathComponent("a.txt").path), "old_string": "one",
                    "new_string": "two"],
                result: ToolOutput(content: "ok", isError: false)))
        let live = LiveThread(
            entries: [.user("go"), edit], startOptions: EngineStartOptions(workingDirectory: repo),
            makeEngine: { FakeEngine() })
        let review = ReviewModel(live: live, workingDirectory: repo.path, environment: environment)
        await review.load()
        #expect(review.files.map(\.path) == ["a.txt"])

        review.commitMessage = "turn"
        await review.commit()
        #expect(review.error == nil)
        #expect(try await git.run(["show", "--name-only", "--format=", "HEAD"]).split(separator: "\n") == ["a.txt"])
        let left = try await git.run(["status", "--porcelain"])
        #expect(left.contains("b.txt") && left.contains("stray.txt"))
    }

    /// GD24: agy's `Update` names only its file; the pane shows that file's diff from git.
    @Test("an edit with no strings gets its diff from git")
    func updateDiffFromGit() async throws {
        let (repo, _, environment) = try await repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "two\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let update = ThreadEntry.tool(
            ToolCall(
                id: "1", name: "Update", input: ["file_path": .string(repo.appendingPathComponent("a.txt").path)],
                result: ToolOutput(content: "", isError: false)))
        let live = LiveThread(
            entries: [.user("go"), update], startOptions: EngineStartOptions(workingDirectory: repo),
            makeEngine: { FakeEngine() })
        let review = ReviewModel(live: live, workingDirectory: repo.path, environment: environment)
        await review.load()
        #expect(review.files.map(\.path) == ["a.txt"])
        #expect(review.files.first.map { ($0.added, $0.removed) } ?? (0, 0) == (1, 1))
    }

    @Test("a pull request is never opened from a protected branch")
    func refusesProtectedBranch() async throws {
        let (repo, git, environment) = try await repo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "two\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: repo), makeEngine: { FakeEngine() })
        let review = ReviewModel(live: live, workingDirectory: repo.path, environment: environment)
        review.scope = .uncommitted
        await review.load()
        review.commitMessage = "nope"
        await review.commitAndOpenPullRequest()
        #expect(review.error?.contains("development") == true)
        #expect(try await git.run(["log", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines) == "root")
    }
}
