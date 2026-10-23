import AinkradAppKit
import AppKit
import SwiftUI

/// The selected thread: its header, the conversation (opened at the newest
/// message), a pending approval, what the agent is doing, and the composer.
struct ThreadView: View {
    let model: GrimoireModel
    let thread: ClaudeSessionSummary
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradToastCenter) private var toasts
    @Environment(\.reviewReplacesThread) private var reviewReplacesThread

    var body: some View {
        let review = model.isReviewOpen ? model.review(for: thread) : nil
        HStack(spacing: 0) {
            // Too narrow for both (GD26): the review pane stands in for the thread until it is closed.
            if review == nil || !reviewReplacesThread { conversation }
            if let review {
                // Without Forge there is nothing to review in (the host says so; an older host doesn't).
                let forge: (() -> Void)? = model.apps?.appAvailability(appID: ForgeLink.appID) == false ? nil : { model.reviewInForge(thread) }
                VStack(spacing: 0) {
                    ReviewPane(review: review, fills: reviewReplacesThread, reviewInForge: forge) {
                        model.isReviewOpen = false
                    }
                    // Standing in for the thread, the pane docks its approval where the thread's footer would (GD34).
                    if reviewReplacesThread, let live = model.current, let request = live.pendingApproval {
                        ApprovalBar(request: request, workingDirectory: thread.workingDirectory, live: live)
                    }
                }
            }
        }
        // Every file:line the thread shows opens in Forge (E5).
        .environment(\.forgeOpener, ForgeOpener(model: model, directory: thread.workingDirectory))
        .onChange(of: model.terminalProblem) { _, problem in
            if let problem { toasts.show(problem, status: .warning) }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThreadHeader(thread: thread, model: model.current?.model, cost: model.current?.costUSD ?? 0) {
                actions
            }
            if let live = model.current {
                ConversationView(live: live, workingDirectory: thread.workingDirectory) {
                    EngineStateRows(model: model, thread: thread, live: live)
                }
                ThreadFooter(
                    live: live, model: model, workingDirectory: thread.workingDirectory, harness: thread.harness)
            } else {
                AinkradLoadingState(label: "Opening the thread…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// In a squeezed thread (GD10) the buttons fold into the More menu rather than push the header off the edge.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: skin.size.s6) { buttons }
            more(moreItems(folding: true))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        AinkradIconButton(systemName: "terminal", size: skin.size.s30, tooltip: "Open a terminal here (Rune)") {
            model.openTerminal(for: thread)
        }
        AinkradIconButton(systemName: "plusminus", size: skin.size.s30, tooltip: "Review changes (⌘⇧R)") {
            model.isReviewOpen.toggle()
        }
        // agy has no fork.
        if thread.harness != .agy {
            AinkradIconButton(systemName: "arrow.triangle.branch", size: skin.size.s30, tooltip: "Fork this thread") {
                model.forkThread(thread)
            }
        }
        more(moreItems(folding: false))
    }

    private func more(_ items: [AinkradMenuItem]) -> some View {
        AinkradMenuButton(items: items) {
            IconMenuLabel(systemName: "ellipsis", size: skin.size.s30)
        }
        .fixedSize()
        .help("More")
    }

    /// Resume and reveal only where they lead somewhere: a draft has no session yet, and only Claude and
    /// Codex keep a session file (GD21). `folding` leads with the header's buttons.
    private func moreItems(folding: Bool) -> [AinkradMenuItem] {
        var items: [AinkradMenuItem] = []
        if folding {
            items.append(
                AinkradMenuItem(title: "Open a terminal here", systemName: "terminal") { model.openTerminal(for: thread) })
            items.append(AinkradMenuItem(title: "Review changes", systemName: "plusminus") { model.isReviewOpen.toggle() })
            if thread.harness != .agy {
                items.append(
                    AinkradMenuItem(title: "Fork this thread", systemName: "arrow.triangle.branch") {
                        model.forkThread(thread)
                    })
            }
        }
        if let command = Self.resumeCommand(for: thread) {
            items.append(
                AinkradMenuItem(title: "Copy resume command", systemName: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                })
        }
        if thread.fileURL.path != "/dev/null" {
            items.append(
                AinkradMenuItem(title: "Reveal session file", systemName: "doc.text.magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([thread.fileURL])
                })
        }
        items.append(
            AinkradMenuItem(title: "Open project in Finder", systemName: "folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: thread.workingDirectory))
            })
        return items
    }

    /// The shell command that continues `thread` in its own CLI; `nil` for a draft the CLI hasn't named.
    static func resumeCommand(for thread: ClaudeSessionSummary) -> String? {
        guard !thread.id.hasPrefix("new-") else { return nil }
        let resume =
            switch thread.harness {
            case .claude: "claude --resume"
            case .codex: "codex resume"
            case .opencode: "opencode --session"
            case .agy: "agy --conversation"
            }
        return "cd \(shellQuoted(thread.workingDirectory)) && \(resume) \(thread.id)"
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct EntryRow: View {
    let entry: ThreadEntry
    /// The images sent with a message, by name.
    let images: [String]
    let workingDirectory: String
    let waitingToolID: String?
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        switch entry {
        case .user(let text):
            AinkradChatBubble(text: text, attachments: images)
        case .text(let text):
            // Inline code as cyan chips, fenced code quiet and syntax-coloured (mockup 10, GP21/GP46).
            AinkradMarkdownText(text: text)
                .replyStyle()
                .textSelection(.enabled)
                .frame(maxWidth: skin.size.s860, alignment: .leading)
        case .note(let text):
            Text(text)
                .font(skin.font(AinkradFontToken(sizeKey: "t13")))
                .foregroundStyle(skin.color(skin.text.faint))
        case .thinking(let text):
            ThinkingRow(text: text)
        case .tool(let call):
            ToolCallCard(call: call, workingDirectory: workingDirectory, isWaiting: call.id == waitingToolID)
        case .plan(let steps):
            PlanCard(steps: steps)
        }
    }
}

/// Collapsed to one line; click to read the reasoning.
private struct ThinkingRow: View {
    let text: String
    @State private var isExpanded = false
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s6) {
            // A plain button, so Full Keyboard Access can focus it and Space expands it.
            Button {  // design-lint: allow raw-control keyboard-reachable expander (kit has no disclosure row)
                isExpanded.toggle()
            } label: {
                // "▸ Thought" (mockup 2 adds "for 6s": no engine reports how long it thought).
                HStack(spacing: skin.size.s6) {
                    Text(isExpanded ? "▾" : "▸")
                    Text("Thought")
                }
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .foregroundStyle(skin.color(skin.text.faint))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(text)
                    .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                    .foregroundStyle(skin.color(skin.text.muted))
                    .textSelection(.enabled)
                    .frame(maxWidth: skin.size.s860, alignment: .leading)
            }
        }
    }
}

/// One tool call on the kit's card. Edits show their diff and commands their
/// output; reads and searches stay one line until clicked.
private struct ToolCallCard: View {
    let call: ToolCall
    let workingDirectory: String
    /// An approval for this call is pending: amber, "waiting for you", open.
    let isWaiting: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.forgeOpener) private var opener

    var body: some View {
        // Grep's hits show at rest (mockup 11); reads and other searches stay one line.
        let hits = call.name == "Grep" && call.result.flatMap { GrepHits.parse($0.content) } != nil
        AinkradToolCard(
            name: call.name,
            argument: ToolSummary.argument(name: call.name, input: call.input, workingDirectory: workingDirectory),
            status: status, result: result,
            // The header shows what runs (as the approval does); this is what the agent wrote (GD3).
            note: call.rewrittenFrom.map { "Rewritten by a hook from: \($0)" },
            // Why it asks (mockup 4): where it runs, and that no allow rule covers it.
            footnote: isWaiting
                ? "Runs in \((workingDirectory as NSString).abbreviatingWithTildeInPath) · not covered by your allow rules"
                : nil,
            isInitiallyExpanded: hits || ["Edit", "MultiEdit", "Write", "Patch", "Bash"].contains(call.name)
        ) {
            if let detail { detail }
        } accessory: { state in
            // "↗ Forge" beside the expander, its own keyboard stop (GD28); the full "↗ Open in Forge at 40" where
            // the card is wide, so a narrow card keeps its argument readable.
            ForgeHeaderPill(
                isHovered: state.isHovered, label: state.isWide ? ForgeTarget.label(for: call) : "↗ Forge",
                action: ForgeTarget.action(for: call, opener: opener))
        }
    }

    private var status: AinkradToolCardStatus {
        if isWaiting { return .waiting }
        guard let result = call.result else { return .running }
        return result.isError ? .failed : .succeeded
    }

    /// An edit's +4 / −2, a command's "exit 0 · 48s", else the summary.
    private var result: AinkradToolCardResult {
        if let output = call.result, !output.isError,
            let counts = ToolSummary.counts(name: call.name, input: call.input)
        {
            return .counts(added: counts.added, removed: counts.removed)
        }
        if call.name == "Bash", let output = call.result, !output.isError {
            return .success(["exit 0", call.duration.map(StatusTime.short)].compactMap { $0 }.joined(separator: " · "))
        }
        return .summary(ToolSummary.result(name: call.name, input: call.input, output: call.result))
    }

    private var detail: AnyView? {
        switch call.name {
        case "Edit", "MultiEdit":
            let path = ForgeLink.absolute(call.input["file_path"]?.stringValue ?? "", in: workingDirectory)
            return AnyView(EditDiffBlock(diff: ToolSummary.editDiff(call.input), path: path))
        case "Patch":
            return AnyView(
                VStack(alignment: .leading, spacing: skin.size.s6) {
                    ForEach(ReviewChanges.patchChanges(call.input).compactMap(\.diff), id: \.path) { diff in
                        DiffBlock(diff: diff)
                    }
                })
        case "Bash" where call.result == nil:
            return AnyView(OutputBlock(text: "$ " + (call.input["command"]?.stringValue ?? ""), maxLines: 8))
        case "Write":
            return AnyView(OutputBlock(text: call.input["content"]?.stringValue ?? "", maxLines: 12))
        case "Grep" where call.result.flatMap { GrepHits.parse($0.content) } != nil:
            return AnyView(GrepHits(hits: GrepHits.parse(call.result?.content ?? "") ?? [], maxLines: 20))
        default:
            guard let result = call.result, !result.content.isEmpty else { return nil }
            return AnyView(OutputBlock(text: result.content, maxLines: call.name == "Bash" ? 8 : 20))
        }
    }
}

/// The agent's todo list, updated in place.
private struct PlanCard: View {
    let steps: [PlanStep]
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s4) {
            Text(skin.labelCased("Plan · \(steps.filter { $0.status == .completed }.count) of \(steps.count)"))
                .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
                .foregroundStyle(skin.color(skin.text.muted))
                .padding(.bottom, skin.size.s2)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: skin.size.s8) {
                    marker(step.status)
                    Text(step.title)
                        .font(skin.font(AinkradFontToken(sizeKey: "t13")))
                        .foregroundStyle(
                            step.status == .pending
                                ? skin.color(skin.text.faint) : theme.foreground.opacity(skin.opacity.o90))
                }
            }
        }
        .padding(.horizontal, skin.size.s12)
        .padding(.vertical, skin.size.s10)
        .frame(maxWidth: skin.size.s860, alignment: .leading)
        // `.todo.cut`: the strong fill under Neon, the white 6 % one under Glass.
        .cardSurface(theme.surfaceElevated.opacity(skin.opacity.o95), glass: skin.color(skin.palette.white).opacity(skin.opacity.o06))
    }

    @ViewBuilder
    private func marker(_ status: PlanStep.Status) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark").foregroundStyle(statusColors.success)
                .font(skin.font(AinkradFontToken(sizeKey: "t11", weight: "bold")))
                .frame(width: skin.size.s12)
        case .inProgress:
            Circle().fill(theme.accentSecondary).frame(width: skin.size.s7, height: skin.size.s7)
                .frame(width: skin.size.s12)
        case .pending:
            Circle().stroke(skin.color(skin.text.faint), lineWidth: 1).frame(width: skin.size.s8, height: skin.size.s8)
                .frame(width: skin.size.s12)
        }
    }
}
