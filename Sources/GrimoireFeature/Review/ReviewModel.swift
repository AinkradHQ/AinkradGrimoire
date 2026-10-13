import AinkradAppKit
import Foundation
import Observation

/// The review pane's state for one thread: which changes, queued comments,
/// and the commit message.
@MainActor
@Observable
final class ReviewModel {
    var scope: ReviewScope = .turn {
        didSet {
            guard scope != oldValue else { return }
            selectedHunks = []
            Task { await load() }
        }
    }
    /// Hunks ticked for "Revert selected".
    var selectedHunks: Set<HunkKey> = []
    /// Hunks reverted from the agent's own edits, which the transcript still lists: kept out of this turn and the
    /// thread (`HunkRevert.signature`).
    private var reverted: Set<String> = []
    private(set) var files: [FileChange] = []
    private(set) var isLoading = false
    /// The last git failure, shown in the pane until the next action.
    private(set) var error: String?
    /// Comments queued on lines; they live on the thread, which sends them with its next message.
    var comments: [ReviewComment] { live.reviewComments }
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
            let edits = withoutReverted(
                ReviewChanges.fromEntries(live.entries, scope: scope, workingDirectory: workingDirectory))
            let unknown = edits.filter { $0.diff == nil }.map(\.path)
            let located = await ReviewChanges.located(edits, in: workingDirectory)
            guard !unknown.isEmpty else {
                files = located
                return
            }
            let diff = try? await git.run(["diff", "HEAD", "--relative", "--no-color", "--no-ext-diff", "--"] + unknown)
            files = ReviewChanges.filledFromGit(located, diff: diff ?? "")
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

    /// Queues a comment on `path` (at `line`, quoting it) for the agent.
    func addComment(_ text: String, on path: String, line: Int? = nil, quote: String = "") {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        live.reviewComments.append(ReviewComment(path: path, line: line, quote: quote, text: text))
    }

    /// Sends the queued comments now, as one message.
    func sendComments() {
        guard !comments.isEmpty else { return }
        live.send("")
    }

    /// Hunks and files can be reverted only between turns: mid-turn the agent may be editing those very files (GD36).
    var canRevertNow: Bool { !live.canInterrupt }

    /// Reverts the ticked hunks in the working tree. A file whose hunks can't be placed exactly (it changed since)
    /// is left untouched and named in the error.
    func revertSelected() async {
        guard canRevertNow else { return }
        let chosen = files.compactMap { file -> (path: String, hunks: [AinkradDiffHunk])? in
            let hunks = file.diff?.hunks.filter { selectedHunks.contains(HunkKey(path: file.path, hunk: $0.id)) } ?? []
            return hunks.isEmpty ? nil : (file.path, hunks)
        }
        guard !chosen.isEmpty else { return }
        let refused = await HunkRevert.revert(
            chosen, in: workingDirectory, trustLineNumbers: scope == .uncommitted)
        for file in chosen where !refused.contains(file.path) {
            reverted.formUnion(file.hunks.map { HunkRevert.signature(file.path, $0) })
        }
        selectedHunks = []
        await load()
        if !refused.isEmpty {
            error = "Not reverted: \(refused.joined(separator: ", ")) changed since, so nothing was written to "
                + (refused.count == 1 ? "it." : "them.")
        }
    }

    private func withoutReverted(_ files: [FileChange]) -> [FileChange] {
        guard !reverted.isEmpty else { return files }
        return files.compactMap { file in
            guard let diff = file.diff else { return file }
            let hunks = diff.hunks.filter { !reverted.contains(HunkRevert.signature(file.path, $0)) }
            if hunks.isEmpty, !diff.hunks.isEmpty { return nil }
            return FileChange(
                path: file.path, status: file.status,
                diff: AinkradFileDiff(path: diff.path, original: diff.original, hunks: hunks))
        }
    }

    /// Discards a file's uncommitted changes (tracked files only).
    func revert(_ file: FileChange) async {
        guard canRevertNow else { return }
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
