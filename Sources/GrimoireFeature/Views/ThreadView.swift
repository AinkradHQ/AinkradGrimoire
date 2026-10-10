import AinkradAppKit
import SwiftUI

/// The selected thread: its header, then the conversation, opened at the
/// newest message.
struct ThreadView: View {
    let model: GrimoireModel
    let thread: ClaudeSessionSummary
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThreadHeader(thread: thread)
            if model.isLoadingThread && model.entries.isEmpty {
                AinkradLoadingState(label: "Opening the thread…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: skin.size.s14) {
                    ForEach(Array(model.entries.enumerated()), id: \.offset) { index, entry in
                        EntryRow(entry: entry, workingDirectory: thread.workingDirectory).id(index)
                    }
                }
                .padding(.horizontal, skin.size.s20)
                .padding(.top, skin.size.s8)
                .padding(.bottom, skin.size.s20)
            }
            .scrollIndicators(.automatic)
            .onAppear { scrollToNewest(proxy) }
            .onChange(of: model.entries.count) { scrollToNewest(proxy) }
        }
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard !model.entries.isEmpty else { return }
        proxy.scrollTo(model.entries.count - 1, anchor: .bottom)
    }
}

private struct EntryRow: View {
    let entry: ThreadEntry
    let workingDirectory: String
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
            ToolCard(call: call, workingDirectory: workingDirectory)
        case .plan(let steps):
            PlanCard(steps: steps)
        }
    }
}

/// The person's message: a tinted card on the right.
private struct UserBubble: View {
    let text: String
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        HStack {
            Spacer(minLength: skin.size.s120)
            Text(text)
                .font(skin.font(AinkradFontToken(sizeKey: "t13")))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o95))
                .textSelection(.enabled)
                .padding(.horizontal, skin.size.s14)
                .padding(.vertical, skin.size.s10)
                .background(skin.shape(cut: AinkradRadius.md).fill(theme.accentPrimary.opacity(skin.opacity.o22)))
                .overlay(
                    skin.shape(cut: AinkradRadius.md).stroke(
                        theme.accentPrimary.opacity(skin.opacity.o55), lineWidth: 1))
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
            HStack(spacing: skin.size.s6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(skin.font(AinkradFontToken(sizeKey: "t9", weight: "semibold")))
                Text("Thinking")
            }
            .font(skin.font(AinkradFontToken(sizeKey: "t12")))
            .foregroundStyle(skin.color(skin.text.faint))
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
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
    @State private var isExpanded: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography

    init(call: ToolCall, workingDirectory: String) {
        self.call = call
        self.workingDirectory = workingDirectory
        _isExpanded = State(initialValue: ["Edit", "MultiEdit", "Write", "Bash"].contains(call.name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            header
            if isExpanded, let body = detail {
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
            Text(ToolSummary.result(name: call.name, input: call.input, output: call.result))
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .foregroundStyle(call.result?.isError == true ? statusColors.danger : skin.color(skin.text.faint))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
    }

    private var detail: AnyView? {
        switch call.name {
        case "Edit", "MultiEdit":
            return AnyView(DiffBlock(diff: ToolSummary.editDiff(call.input)))
        case "Write":
            return AnyView(OutputBlock(text: call.input["content"]?.stringValue ?? "", maxLines: 12))
        default:
            guard let result = call.result, !result.content.isEmpty else { return nil }
            return AnyView(OutputBlock(text: result.content, maxLines: call.name == "Bash" ? 8 : 20))
        }
    }

    private var dotColor: Color {
        guard let result = call.result else { return theme.accentSecondary }
        return result.isError ? statusColors.danger : statusColors.success
    }

    /// Glass frames controls with a neutral hairline, Neon with its accent rim.
    private var stroke: Color {
        skin.material.kind == "glass"
            ? theme.foreground.opacity(skin.opacity.o12) : theme.accentSecondary.opacity(skin.opacity.o25)
    }
}

/// A command's output or a file's content: monospaced, the first lines only.
private struct OutputBlock: View {
    let text: String
    let maxLines: Int
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTypography) private var typography

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(maxLines).joined(separator: "\n")
        VStack(alignment: .leading, spacing: skin.size.s4) {
            Text(shown)
                .font(AinkradFontResolver.font(size: 11.5, mono: true, typography: typography))
                .foregroundStyle(skin.color(skin.text.muted))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if lines.count > maxLines {
                Text("\(lines.count - maxLines) more lines")
                    .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                    .foregroundStyle(skin.color(skin.text.faint))
            }
        }
        .padding(skin.size.s8)
        .background(skin.shape(cut: AinkradRadius.sm).fill(theme.background.opacity(skin.opacity.o70)))
    }
}

/// An edit's hunks: removed lines red, added green, context muted.
private struct DiffBlock: View {
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
        return Text("\(sign) \(line.text)")
            .foregroundStyle(color)
            .lineLimit(1)
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
