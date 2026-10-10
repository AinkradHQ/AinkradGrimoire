import Foundation
import Observation

/// The review pane's state for one thread: which changes, queued comments,
/// and the commit message.
@MainActor
@Observable
final class ReviewModel {
    var scope: ReviewScope = .turn {
        didSet { if scope != oldValue { Task { await load() } } }
    }
    private(set) var files: [FileChange] = []
    private(set) var isLoading = false
    /// The last git failure, shown in the pane until the next action.
    private(set) var error: String?
    private(set) var comments: [(path: String, text: String)] = []
    var commitMessage = ""

    private let live: LiveThread
    private let git: Git
    private let workingDirectory: String

    init(live: LiveThread, workingDirectory: String, environment: [String: String]) {
        self.live = live
        self.workingDirectory = workingDirectory
        self.git = Git(directory: workingDirectory, environment: environment)
    }

    var totals: (added: Int, removed: Int) {
        (files.map(\.added).reduce(0, +), files.map(\.removed).reduce(0, +))
    }

    func load() async {
        error = nil
        switch scope {
        case .turn, .thread:
            files = ReviewChanges.fromEntries(live.entries, scope: scope, workingDirectory: workingDirectory)
        case .uncommitted:
            isLoading = true
            defer { isLoading = false }
            do {
                let diff = try await git.run(["diff", "HEAD", "--no-color", "--no-ext-diff"])
                let status = try await git.run(["status", "--porcelain"])
                files =
                    ReviewChanges.parseUnifiedDiff(diff)
                    + ReviewChanges.untracked(fromPorcelain: status).map {
                        FileChange(path: $0, status: .untracked, diff: nil)
                    }
            } catch {
                files = []
                self.error = error.localizedDescription
            }
        }
    }

    func addComment(_ text: String, on path: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        comments.append((path, text))
    }

    /// Sends every queued comment to the agent as one message.
    func sendComments() {
        guard !comments.isEmpty else { return }
        live.send(ReviewChanges.message(for: comments))
        comments = []
    }

    /// Discards a file's uncommitted changes (tracked files only).
    func revert(_ file: FileChange) async {
        await perform(["restore", "--staged", "--worktree", "--", file.path])
    }

    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard await perform(["add", "-A"]), await perform(["commit", "-m", message]) else { return }
        commitMessage = ""
    }

    /// Commits, pushes the branch and opens a pull request with `gh`.
    func commitAndOpenPullRequest() async {
        await commit()
        guard error == nil else { return }
        guard await perform(["push", "-u", "origin", "HEAD"]) else { return }
        do {
            _ = try await git.gh(["pr", "create", "--fill"])
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    private func perform(_ arguments: [String]) async -> Bool {
        do {
            _ = try await git.run(arguments)
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
