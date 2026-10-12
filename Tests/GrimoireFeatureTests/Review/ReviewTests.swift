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

    @Test("queued comments become one message")
    func message() {
        #expect(
            ReviewChanges.message(for: [("A.swift", "use the kit"), ("B.swift", "rename")])
                == "Review comments on your changes:\n- A.swift: use the kit\n- B.swift: rename")
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
