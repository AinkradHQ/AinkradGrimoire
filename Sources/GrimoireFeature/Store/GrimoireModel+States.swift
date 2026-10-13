import Foundation

/// The engine states around a thread (E6): starting, limited, carried over to another agent.
extension GrimoireModel {
    /// A turn failed on `harness`'s usage limit: its windows say so until the reset.
    func markLimited(_ harness: Harness, resetHint: Date?) {
        usage[harness] = UsageLimit.exhausting(usage[harness] ?? [], resetHint: resetHint, now: now())
    }

    func limit(for harness: Harness) -> UsageLimit? {
        UsageLimit.current(harness, windows: usage[harness] ?? [], now: now())
    }

    /// The agent "New thread with …" offers instead of a limited `harness`.
    func alternative(to harness: Harness) -> Harness? {
        let limited = Set(Harness.allCases.filter { limit(for: $0) != nil })
        let statuses = Dictionary(uniqueKeysWithValues: Harness.allCases.map { ($0, status(of: $0)) })
        return UsageLimit.alternative(to: harness, statuses: statuses, limited: limited)
    }

    /// Starts a new thread on `harness` in `thread`'s project with the composer's message — or, when it is
    /// empty, the last message sent.
    func carryOver(_ thread: ClaudeSessionSummary, to harness: Harness) {
        guard let live = liveThreads[thread.id] else { return }
        var text = live.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = live.entries.reversed().lazy.compactMap { if case .user(let text) = $0 { text } else { nil } }.first ?? ""
        }
        guard !text.isEmpty else { return }
        live.cancelSendAtReset()
        live.draft = ""
        startThread(
            project: thread.projectPath, prompt: text, model: nil, mode: live.mode, worktree: false, harness: harness)
    }

    /// What the transcript lists while `live` starts.
    func startupSteps(for thread: ClaudeSessionSummary, live: LiveThread) -> [StartupStep] {
        StartupStep.steps(
            harness: thread.harness, cli: status(of: thread.harness),
            // agy's history is a note, not messages.
            loadedMessages: thread.harness == .agy ? 0 : live.loadedMessages,
            location: thread.gitBranch ?? URL(fileURLWithPath: thread.workingDirectory).lastPathComponent)
    }
}
