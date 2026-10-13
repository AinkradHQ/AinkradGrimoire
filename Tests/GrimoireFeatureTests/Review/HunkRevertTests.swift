import AinkradAppKit
import Foundation
import Testing

@testable import GrimoireFeature

@MainActor
@Suite("Revert selected hunks (real git)")
struct HunkRevertTests {
    /// A scratch repository with `a.txt` (twenty numbered lines) committed.
    private func repository() async throws -> (URL, Git) {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-hunks-\(UUID())")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = Git(directory: repo.path, environment: CLILocator.loginEnvironment())
        _ = try await git.run(["init", "-q"])
        try Self.original.write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "a.txt"])
        _ = try await git.run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "a"])
        return (repo, git)
    }

    static let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"

    private func review(_ repo: URL, entries: [ThreadEntry] = []) -> ReviewModel {
        let live = LiveThread(
            entries: entries, startOptions: EngineStartOptions(workingDirectory: repo), makeEngine: { FakeEngine() })
        return ReviewModel(live: live, workingDirectory: repo.path, environment: CLILocator.loginEnvironment())
    }

    @Test("uncommitted: only the ticked hunk is reverted; the other stays")
    func uncommitted() async throws {
        let (repo, _) = try await repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("a.txt")
        let edited = Self.original.replacingOccurrences(of: "line 2\n", with: "line two\n")
            .replacingOccurrences(of: "line 18\n", with: "line eighteen\nline 18b\n")
        try edited.write(to: file, atomically: true, encoding: .utf8)
        let review = review(repo)
        review.scope = .uncommitted
        await review.load()
        let hunks = try #require(review.files.first?.diff?.hunks)
        #expect(hunks.count == 2)
        review.selectedHunks = [HunkKey(path: "a.txt", hunk: hunks[1].id)]
        await review.revertSelected()
        #expect(review.error == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == Self.original.replacingOccurrences(of: "line 2\n", with: "line two\n"))
        #expect(review.files.first?.diff?.hunks.count == 1, "reloaded: one hunk left")
        #expect(review.selectedHunks.isEmpty)
    }

    @Test("GD33: a CRLF file parses line by line, keeps the file after it, and its hunk reverts")
    func crlf() async throws {
        let (repo, git) = try await repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await git.run(["config", "core.autocrlf", "false"])
        let crlf = repo.appendingPathComponent("0-windows.txt")
        let original = (1...6).map { "row \($0)" }.joined(separator: "\r\n") + "\r\n"
        try original.write(to: crlf, atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "0-windows.txt"])
        _ = try await git.run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "w"])
        try original.replacingOccurrences(of: "row 3\r\n", with: "row three\r\n").write(
            to: crlf, atomically: true, encoding: .utf8)
        try Self.original.replacingOccurrences(of: "line 2\n", with: "line two\n").write(
            to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let review = review(repo)
        review.scope = .uncommitted
        await review.load()
        #expect(review.files.map(\.path) == ["0-windows.txt", "a.txt"], "the file after the CRLF one is kept")
        let hunk = try #require(review.files.first?.diff?.hunks.first)
        #expect(hunk.lines.filter { $0.kind == .insertion }.map(\.text) == ["row three\r"])
        #expect(hunk.lines.count == 7, "one line per line, not merged")
        review.selectedHunks = [HunkKey(path: "0-windows.txt", hunk: hunk.id)]
        await review.revertSelected()
        #expect(review.error == nil)
        #expect(try String(contentsOf: crlf, encoding: .utf8) == original)
    }

    @Test("a file that changed since is refused and left untouched")
    func conflict() async throws {
        let (repo, _) = try await repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("a.txt")
        try Self.original.replacingOccurrences(of: "line 5\n", with: "line five\n").write(
            to: file, atomically: true, encoding: .utf8)
        let review = review(repo)
        review.scope = .uncommitted
        await review.load()
        let hunk = try #require(review.files.first?.diff?.hunks.first)
        // Someone edits the hunk's lines after the pane loaded.
        let changed = Self.original.replacingOccurrences(of: "line 5\n", with: "line FIVE\n")
        try changed.write(to: file, atomically: true, encoding: .utf8)
        review.selectedHunks = [HunkKey(path: "a.txt", hunk: hunk.id)]
        await review.revertSelected()
        #expect(review.error?.contains("a.txt") == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == changed)
    }

    @Test("this turn: the agent's edit is undone by its text, then drops out of the list")
    func agentEdit() async throws {
        let (repo, _) = try await repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("a.txt")
        try Self.original.replacingOccurrences(of: "line 9\n", with: "line nine\n").write(
            to: file, atomically: true, encoding: .utf8)
        let edit = ThreadEntry.tool(
            ToolCall(
                id: "e1", name: "Edit",
                input: ["file_path": .string(file.path), "old_string": "line 9", "new_string": "line nine"],
                result: ToolOutput(content: "ok", isError: false)))
        let review = review(repo, entries: [.user("rename it"), edit])
        await review.load()
        let hunk = try #require(review.files.first?.diff?.hunks.first)
        review.selectedHunks = [HunkKey(path: "a.txt", hunk: hunk.id)]
        await review.revertSelected()
        #expect(review.error == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == Self.original)
        #expect(review.files.isEmpty)
    }

    @Test("text patching: placed by the lines, refused when they appear twice without numbers to settle it")
    func patching() {
        let hunk = AinkradDiffHunk(
            id: 0, oldStart: 2, oldCount: 1, newStart: 2, newCount: 1,
            lines: [AinkradDiffLine(kind: .deletion, oldNumber: 2, newNumber: nil, text: "a"),
                    AinkradDiffLine(kind: .insertion, oldNumber: nil, newNumber: 2, text: "}")])
        #expect(HunkRevert.reverting([hunk], in: "x\n}\ny", trustLineNumbers: false) == "x\na\ny")
        #expect(HunkRevert.reverting([hunk], in: "}\n}\ny", trustLineNumbers: false) == nil)
        #expect(HunkRevert.reverting([hunk], in: "}\n}\ny", trustLineNumbers: true) == "}\na\ny")
    }
}
