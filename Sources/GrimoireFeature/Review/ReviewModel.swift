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
            let edits = ReviewChanges.fromEntries(live.entries, scope: scope, workingDirectory: workingDirectory)
            let unknown = edits.filter { $0.diff == nil }.map(\.path)
            guard !unknown.isEmpty else {
                files = edits
                return
            }
            let diff = try? await git.run(["diff", "HEAD", "--relative", "--no-color", "--no-ext-diff", "--"] + unknown)
            files = ReviewChanges.filledFromGit(edits, diff: diff ?? "")
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

    /// Commits exactly the files the pane shows (this turn, the thread, or every uncommitted change) — never
    /// whatever else happens to be dirty or staged in the repository.
    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = files.map(\.path)
        guard !message.isEmpty, !paths.isEmpty else { return }
        guard await perform(["add", "-A", "--"] + paths), await perform(["commit", "-m", message, "--"] + paths)
        else { return }
        commitMessage = ""
    }

    /// Branches a pull request never comes from: work on them lands by PR, so pushing there skips review.
    static let protectedBranches: Set = ["main", "master", "development", "develop", "staging"]

    /// Commits, pushes the branch and opens a pull request with `gh` — only from a feature branch.
    func commitAndOpenPullRequest() async {
        let branch = (try? await git.run(["rev-parse", "--abbrev-ref", "HEAD"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
        if branch == "HEAD" || Self.protectedBranches.contains(branch) {
            error = branch == "HEAD"
                ? "Not on a branch. Check out a feature branch before opening a pull request."
                : "On \(branch). Create a feature branch before opening a pull request."
            return
        }
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
