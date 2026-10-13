import AinkradAppKit
import AppKit
import Foundation

/// Grimoire and Forge (E5): each turn is announced to Forge, every file:line opens there, and Forge's requests
/// (⌘I, "Ask about this turn…") arrive here.
extension GrimoireModel {
    /// Tells Forge which files `live`'s turn wrote, so its review groups them by turn. In-process — plugins share the
    /// host — because a launch would bring Forge forward after every turn.
    func announceTurn(_ live: LiveThread, harness: Harness, startedAt: Date?) {
        guard let thread = liveThreads.first(where: { $0.value === live })?.key,
            let notice = ForgeLink.turnNotice(
                entries: live.entries, root: live.workingDirectory, thread: thread, agent: harness.displayName,
                startedAt: startedAt ?? Date(), endedAt: Date())
        else { return }
        NotificationCenter.default.post(name: ForgeLink.turnNotification, object: notice)
    }

    /// Opens `path` (relative to `directory`, or absolute) in Forge at `line`. Without Forge (not installed, or
    /// off), the file opens in the default editor.
    func openInForge(_ path: String, line: Int?, directory: String) {
        let file = ForgeLink.absolute(path, in: directory)
        open(ForgeLink.openPayload(path: file, line: line), fallback: URL(fileURLWithPath: file))
    }

    /// Opens `path` in Forge where `lines` (an edit's new side) now are, `offset` lines in. Edits carry no line
    /// numbers, so the file is read (off the main thread) to find them; `fallback` (a diff's own number) otherwise.
    func openInForge(_ path: String, at lines: [String], offset: Int, fallback: Int?, directory: String) {
        let file = ForgeLink.absolute(path, in: directory)
        Task {
            let text = await Task.detached(priority: .userInitiated) { try? String(contentsOfFile: file, encoding: .utf8) }.value
            let start = text.flatMap { FileLocation.line(of: lines, in: $0) }.map { max(1, $0) + offset } ?? fallback
            openInForge(file, line: start, directory: directory)
        }
    }

    /// "Review in Forge": Forge opens the thread's folder on its review of outside changes, grouped by turn.
    func reviewInForge(_ thread: ClaudeSessionSummary) {
        open(ForgeLink.openPayload(path: thread.workingDirectory, review: true), fallback: nil)
    }

    private func open(_ payload: String?, fallback: URL?) {
        guard let apps, let payload else { return }
        guard let reporting = apps as? PluginAppLauncherResult else {
            return apps.open(appID: ForgeLink.appID, payload: payload)
        }
        switch reporting.openReportingOutcome(appID: ForgeLink.appID, payload: payload) {
        case .opened: break
        default: if let fallback { NSWorkspace.shared.open(fallback) }
        }
    }

    /// A payload another app sent with opening this window. Ask Agent becomes a new thread waiting in the main
    /// pane — its project, request and Forge's selection prefilled, nothing sent unseen. "Ask about this turn…" was
    /// sent in Forge's review, so it continues that thread at once.
    func handleLaunch(_ payload: String?) {
        guard let ask = AskLaunch.decode(payload) else { return }
        if let thread = ask.thread, projects.lazy.flatMap(\.sessions).contains(where: { $0.id == thread }) {
            return followUp(thread, ask.prompt)
        }
        if !projects.contains(where: { $0.path == ask.path }) { openFolder(URL(fileURLWithPath: ask.path)) }
        let context = ask.context
        isComposingNewThread = false
        isShowingSettings = false
        selectedThreadID = nil  // sets aside any earlier ask, so set it first
        setAsideAsk()
        forgeAsk = ForgeAsk(project: ask.path, prompt: context == nil ? ask.prompt : ask.request ?? "", context: context)
    }

    /// Takes the ask out of the main pane. An edited one waits in `setAsideForgeAsk` for the confirm (GD31).
    func setAsideAsk() {
        if forgeAsk?.isEdited == true { setAsideForgeAsk = forgeAsk }
        forgeAsk = nil
    }

    /// The confirm's Cancel: the set-aside ask comes back to the main pane, in place of what replaced it.
    func keepEditingAsk() {
        guard let ask = setAsideForgeAsk else { return }
        setAsideForgeAsk = nil
        isShowingSettings = false
        selectedThreadID = nil
        forgeAsk = ask
    }

    /// Selects `thread` and sends `text` to it once it is open.
    private func followUp(_ thread: String, _ text: String) {
        isShowingSettings = false
        selectedThreadID = thread
        Task {
            // ponytail: polls the thread's load (≤ 10 s); a load callback if this ever needs to be instant.
            for _ in 0..<200 {
                if let live = liveThreads[thread] { return live.send(text) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
