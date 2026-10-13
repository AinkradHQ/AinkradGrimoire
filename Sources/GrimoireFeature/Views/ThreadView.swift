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

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ThreadHeader(thread: thread, model: model.current?.model) {
                    actions
                }
                if let live = model.current {
                    ConversationView(live: live, workingDirectory: thread.workingDirectory)
                    ThreadFooter(
                        live: live, model: model, workingDirectory: thread.workingDirectory, harness: thread.harness)
                } else {
                    AinkradLoadingState(label: "Opening the thread…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if model.isReviewOpen, let review = model.review(for: thread) {
                ReviewPane(review: review) { model.isReviewOpen = false }
            }
        }
        .onChange(of: model.terminalProblem) { _, problem in
            if let problem { toasts.show(problem, status: .warning) }
        }
    }

    @ViewBuilder
    private var actions: some View {
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
        AinkradMenuButton(items: moreItems) {
            Image(systemName: "ellipsis")
                .frame(width: skin.size.s30, height: skin.size.s30)
                .contentShape(Rectangle())
        }
        .fixedSize()
        .help("More")
    }

    /// Resume and reveal only where they lead somewhere: a draft has no session yet, and only Claude and
    /// Codex keep a session file (GD21).
    private var moreItems: [AinkradMenuItem] {
        var items: [AinkradMenuItem] = []
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

private struct ConversationView: View {
    let live: LiveThread
    let workingDirectory: String
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: skin.size.s14) {
                    ForEach(Array(live.entries.enumerated()), id: \.offset) { index, entry in
                        EntryRow(
                            entry: entry, workingDirectory: workingDirectory,
                            waitingToolID: live.pendingApproval?.toolUseID
                        ).id(index)
                    }
                }
                .padding(.horizontal, skin.size.s20)
                .padding(.top, skin.size.s8)
                .padding(.bottom, skin.size.s20)
            }
            // Opens at the newest message without jumping there before the rows
            // above are laid out (which left a blank gap at the top).
            .defaultScrollAnchor(.bottom)
            .onChange(of: live.entries.count) { scrollToNewest(proxy) }
            .onChange(of: live.entries.last) { scrollToNewest(proxy) }
        }
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard !live.entries.isEmpty else { return }
        proxy.scrollTo(live.entries.count - 1, anchor: .bottom)
    }
}

private struct EntryRow: View {
    let entry: ThreadEntry
    let workingDirectory: String
    let waitingToolID: String?
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        switch entry {
        case .user(let text):
            UserBubble(text: text)
        case .text(let text):
            AinkradMarkdownText(text: text)
                .textSelection(.enabled)
                .frame(maxWidth: skin.size.s860, alignment: .leading)
        case .thinking(let text):
            ThinkingRow(text: text)
        case .tool(let call):
            ToolCard(call: call, workingDirectory: workingDirectory, isWaiting: call.id == waitingToolID)
        case .plan(let steps):
            PlanCard(steps: steps)
        }
    }
}

/// The person's message: a tinted card on the right, markdown rendered as replies are (GD1).
private struct UserBubble: View {
    let text: String
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        HStack {
            Spacer(minLength: skin.size.s120)
            message
                .textSelection(.enabled)
                .padding(.horizontal, skin.size.s14)
                .padding(.vertical, skin.size.s10)
                .background(skin.shape(cut: AinkradRadius.md).fill(theme.accentPrimary.opacity(skin.opacity.o22)))
                .overlay(
                    skin.shape(cut: AinkradRadius.md).stroke(
                        theme.accentPrimary.opacity(skin.opacity.o55), lineWidth: 1))
        }
    }

    /// Prose stays one hugging `Text` (inline markdown only); a code block, list or table takes the kit's renderer.
    @ViewBuilder
    private var message: some View {
        let blocks = AinkradMarkdownBlocks.parse(text)
        if blocks.allSatisfy({ if case .paragraph = $0 { true } else { false } }) {
            Text(
                (try? AttributedString(
                    markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(text)
            )
            .font(skin.font(AinkradFontToken(sizeKey: "t13")))
            .foregroundStyle(theme.foreground.opacity(skin.opacity.o95))
        } else {
            AinkradMarkdownText(blocks: blocks)
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
                HStack(spacing: skin.size.s6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(skin.font(AinkradFontToken(sizeKey: "t9", weight: "semibold")))
                    Text("Thinking")
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

/// One tool call and its result. Edits show their diff and commands their
/// output; reads and searches stay one line until clicked.
private struct ToolCard: View {
    let call: ToolCall
    let workingDirectory: String
    /// An approval for this call is pending: amber, "waiting for you", open.
    let isWaiting: Bool
    @State private var isExpanded: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography

    init(call: ToolCall, workingDirectory: String, isWaiting: Bool) {
        self.call = call
        self.workingDirectory = workingDirectory
        self.isWaiting = isWaiting
        _isExpanded = State(initialValue: ["Edit", "MultiEdit", "Write", "Patch", "Bash"].contains(call.name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            header
            if let original = call.rewrittenFrom {
                // The header shows what runs (as the approval does); this is what the agent wrote (GD3).
                Text("Rewritten by a hook from: \(original)")
                    .font(AinkradFontResolver.font(size: 11, mono: true, typography: typography))
                    .foregroundStyle(skin.color(skin.text.faint))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isExpanded || isWaiting, let body = detail {
                body
            }
        }
        .padding(.horizontal, skin.size.s12)
        .padding(.vertical, skin.size.s8)
        .frame(maxWidth: skin.size.s860, alignment: .leading)
        .background(skin.shape(cut: AinkradRadius.md).fill(theme.surface.opacity(skin.opacity.o60)))
        .overlay(skin.shape(cut: AinkradRadius.md).stroke(stroke, lineWidth: 1))
    }

    private var header: some View {
        Button {  // design-lint: allow raw-control keyboard-reachable expander (kit has no disclosure row)
            isExpanded.toggle()
        } label: {
            headerLabel
        }
        .buttonStyle(.plain)
    }

    private var headerLabel: some View {
        HStack(spacing: skin.size.s8) {
            Circle().fill(dotColor).frame(width: skin.size.s7, height: skin.size.s7)
            Text(call.name)
                .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "semibold")))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
            Text(ToolSummary.argument(name: call.name, input: call.input, workingDirectory: workingDirectory))
                .font(AinkradFontResolver.font(size: 11, mono: true, typography: typography))
                .foregroundStyle(skin.color(skin.text.muted))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: skin.size.s8)
            Text(
                isWaiting
                    ? "waiting for you" : ToolSummary.result(name: call.name, input: call.input, output: call.result)
            )
            .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
            .foregroundStyle(
                isWaiting
                    ? statusColors.warning
                    : call.result?.isError == true ? statusColors.danger : skin.color(skin.text.faint)
            )
            .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var detail: AnyView? {
        switch call.name {
        case "Edit", "MultiEdit":
            return AnyView(DiffBlock(diff: ToolSummary.editDiff(call.input)))
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
        default:
            guard let result = call.result, !result.content.isEmpty else { return nil }
            return AnyView(OutputBlock(text: result.content, maxLines: call.name == "Bash" ? 8 : 20))
        }
    }

    private var dotColor: Color {
        if isWaiting { return statusColors.warning }
        guard let result = call.result else { return theme.accentSecondary }
        return result.isError ? statusColors.danger : statusColors.success
    }

    /// Glass frames controls with a neutral hairline, Neon with its accent rim.
    private var stroke: Color {
        if isWaiting { return statusColors.warning.opacity(skin.opacity.o60) }
        return skin.material.kind == "glass"
            ? theme.foreground.opacity(skin.opacity.o12) : theme.accentSecondary.opacity(skin.opacity.o25)
    }
}

/// A command's output or a file's content: monospaced, the first lines until "N more lines" opens the rest.
private struct OutputBlock: View {
    let text: String
    let maxLines: Int
    @State private var showsAll = false
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTypography) private var typography

    var body: some View {
        let lines = ToolSummary.lines(text)
        let shown = lines.prefix(showsAll ? lines.count : maxLines)
        let numbered = shown.compactMap(ToolSummary.gutter)
        VStack(alignment: .leading, spacing: skin.size.s4) {
            Group {
                if !numbered.isEmpty, numbered.count == shown.count {
                    // Numbered lines wrap under their text, not the number (GD5).
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(numbered.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: skin.size.s8) {
                                Text(line.number).foregroundStyle(skin.color(skin.text.faint))
                                Text(line.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else {
                    // ponytail: one Text for the whole output; virtualize if multi-thousand-line outputs get slow.
                    Text(shown.joined(separator: "\n"))
                }
            }
            .font(AinkradFontResolver.font(size: 11.5, mono: true, typography: typography))
            .foregroundStyle(skin.color(skin.text.muted))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if lines.count > maxLines {
                // A plain button, so Full Keyboard Access can focus it and Space opens the rest (GD19).
                Button {  // design-lint: allow raw-control keyboard-reachable expander (kit has no disclosure row)
                    showsAll.toggle()
                } label: {
                    HStack(spacing: skin.size.s4) {
                        Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                        Text(showsAll ? "Show less" : "\(lines.count - maxLines) more lines")
                    }
                    .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                    .foregroundStyle(skin.color(skin.text.faint))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(skin.size.s8)
        .background(skin.shape(cut: AinkradRadius.sm).fill(theme.background.opacity(skin.opacity.o70)))
    }
}

/// An edit's hunks: removed lines red, added green, context muted.
struct DiffBlock: View {
    let diff: AinkradFileDiff
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff.hunks) { hunk in
                Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                    .foregroundStyle(skin.color(skin.text.faint))
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
        }
        .font(AinkradFontResolver.font(size: 11.5, mono: true, typography: typography))
        .textSelection(.enabled)
        .padding(.vertical, skin.size.s6)
        .padding(.horizontal, skin.size.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.shape(cut: AinkradRadius.sm).fill(theme.background.opacity(skin.opacity.o70)))
    }

    private func row(_ line: AinkradDiffLine) -> some View {
        let (sign, color): (String, Color) =
            switch line.kind {
            case .insertion: ("+", statusColors.success)
            case .deletion: ("-", statusColors.danger)
            case .context: (" ", skin.color(skin.text.muted))
            }
        // Long lines wrap under the text, not the sign, so the changed end stays readable.
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(sign) ")
            Text(line.text).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .context ? .clear : color.opacity(skin.opacity.o08))
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
        .background(skin.shape(cut: AinkradRadius.md).fill(theme.surface.opacity(skin.opacity.o60)))
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
