import AinkradAppKit
import SwiftUI

/// Beside the conversation: what changed (this turn, the whole thread, or
/// everything uncommitted), comments for the agent, and the commit.
struct ReviewPane: View {
    @Bindable var review: ReviewModel
    /// Standing in for the thread in a narrow window (GD26): the pane takes the whole width.
    var fills = false
    /// "Review in Forge": Forge's review of these changes, grouped by turn, with Keep / Undo there.
    var reviewInForge: (() -> Void)?
    let close: () -> Void
    @State private var reverting: FileChange?
    @State private var isRevertingHunks = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s10) {
            header
            FittingPicker(items: ReviewScope.allCases, selection: $review.scope) { $0.rawValue }
            if let error = review.error {
                Text(error)
                    .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                    .foregroundStyle(statusColors.danger)
                    .lineLimit(3)
            }
            if review.isLoading {
                AinkradLoadingState(label: "Reading changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if review.files.isEmpty {
                AinkradEmptyState(
                    icon: "checkmark.circle", title: "No changes",
                    message: review.scope == .uncommitted
                        ? "The working tree is clean."
                        : "The agent hasn't edited files in this \(review.scope == .turn ? "turn" : "thread")."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: skin.size.s10) {
                        ForEach(review.files) { file in
                            FileCard(
                                file: file, comments: review.comments.filter { $0.path == file.path }.map(\.text),
                                canRevert: review.scope == .uncommitted && file.status != .untracked,
                                startsExpanded: review.files.count <= 3, selection: selection(in: file),
                                onRevert: { reverting = file },
                                onComment: { review.addComment($0, on: file.path, line: $1, quote: $2) })
                        }
                    }
                }
            }
            footer
        }
        .padding(skin.size.s14)
        .frame(
            minWidth: fills ? nil : skin.size.s320, idealWidth: skin.size.s440, maxWidth: fills ? .infinity : skin.size.s440)
        .frame(maxHeight: .infinity, alignment: .top)
        // Fill, not a rule.
        .background(theme.surface.opacity(skin.opacity.o35))
        .task { await review.load() }
        .ainkradConfirmDialog(
            isPresented: Binding(get: { reverting != nil }, set: { if !$0 { reverting = nil } }),
            title: "Revert \(reverting?.path ?? "")?",
            message: "Its uncommitted changes are discarded. This can't be undone.",
            confirmTitle: "Revert", isDestructive: true
        ) {
            if let file = reverting { Task { await review.revert(file) } }
        }
        .ainkradConfirmDialog(
            isPresented: $isRevertingHunks,
            title: review.selectedHunks.count == 1 ? "Revert 1 hunk?" : "Revert \(review.selectedHunks.count) hunks?",
            message: "They are undone in the working tree. A file that changed since is left as it is.",
            confirmTitle: "Revert", isDestructive: true
        ) {
            Task { await review.revertSelected() }
        }
    }

    /// The tick box of each of `file`'s hunks, bound to the pane's selection.
    private func selection(in file: FileChange) -> (AinkradDiffHunk) -> Binding<Bool> {
        { hunk in
            let key = HunkKey(path: file.path, hunk: hunk.id)
            return Binding(
                get: { review.selectedHunks.contains(key) },
                set: { if $0 { review.selectedHunks.insert(key) } else { review.selectedHunks.remove(key) } })
        }
    }

    /// "CHANGES [THIS THREAD]   3 files · +18 −7" (mockup 5). The thread header's ± closes the pane; ✕ only when the
    /// pane stands in for the thread (GD26), whose header is then gone.
    private var header: some View {
        HStack(spacing: skin.size.s8) {
            Text(skin.labelCased("Changes"))
                .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
                .foregroundStyle(skin.color(skin.text.muted))
            AinkradBadge(text: Self.scopeBadge(review.scope), tint: theme.accentSecondary).fixedSize()
            Spacer(minLength: 0)
            let totals = review.totals
            HStack(spacing: skin.size.s4) {
                Text("\(review.files.count == 1 ? "1 file" : "\(review.files.count) files") ·")
                    .foregroundStyle(skin.color(skin.text.faint))
                Text("+\(totals.added)").foregroundStyle(statusColors.success)
                Text("−\(totals.removed)").foregroundStyle(statusColors.danger)
            }
            .font(AinkradFontResolver.font(size: 11, mono: true, typography: typography))
            .lineLimit(1)
            if fills {
                AinkradIconButton(systemName: "xmark", size: skin.size.s24, tooltip: "Close", action: close)
            }
        }
    }

    static func scopeBadge(_ scope: ReviewScope) -> String {
        switch scope {
        case .turn: "this turn"
        case .thread: "this thread"
        case .uncommitted: "uncommitted"
        }
    }

    /// Mockup 5's footer: Revert selected | Send N comments, the commit message, then Commit | Commit & open PR.
    /// Until there are comments, Review in Forge takes the second half, as mockup 11 pairs it.
    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            let forge = reviewInForge.flatMap { review.files.isEmpty ? nil : $0 }
            if !review.files.isEmpty {
                HStack(spacing: skin.size.s8) {
                    AinkradButton(title: "Revert selected", style: .secondary) { isRevertingHunks = true }
                        .secondaryAccent().fullWidth()
                        .disabled(review.selectedHunks.isEmpty || !review.canRevertHunks)
                        .help(
                            review.canRevertHunks
                                ? "Tick hunks to revert them" : "Waits for the agent's turn to end — it may be editing these files")
                    if let forge, review.comments.isEmpty {
                        AinkradButton(title: "Review in Forge ↗", style: .secondary, action: forge)
                            .secondaryAccent().fullWidth()
                    }
                    if !review.comments.isEmpty {
                        AinkradButton(
                            title: review.comments.count == 1 ? "Send 1 comment" : "Send \(review.comments.count) comments",
                            style: .secondary
                        ) { review.sendComments() }
                        .secondaryAccent().fullWidth()
                    }
                }
            }
            AinkradTextField(text: $review.commitMessage, placeholder: "Commit message")
            HStack(spacing: skin.size.s8) {
                AinkradButton(title: "Commit", style: .primary) { Task { await review.commit() } }.fullWidth()
                AinkradButton(title: "Commit & open PR", style: .secondary) {
                    Task { await review.commitAndOpenPullRequest() }
                }
                .secondaryAccent().fullWidth()
            }
            .disabled(review.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct FileCard: View {
    let file: FileChange
    /// Comments queued on this file, not sent yet.
    let comments: [String]
    let canRevert: Bool
    let selection: (AinkradDiffHunk) -> Binding<Bool>
    let onRevert: () -> Void
    /// A comment's text, its line (nil when the file's numbers aren't known) and the line quoted.
    let onComment: (String, Int?, String) -> Void
    @State private var isExpanded: Bool
    @State private var comment = ""
    /// The line whose comment field is open: (hunk id, line index).
    @State private var commenting: LineRef?
    @FocusState private var commentFocused: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography
    @Environment(\.forgeOpener) private var opener
    @State private var hovering = false

    init(
        file: FileChange, comments: [String], canRevert: Bool, startsExpanded: Bool,
        selection: @escaping (AinkradDiffHunk) -> Binding<Bool>, onRevert: @escaping () -> Void,
        onComment: @escaping (String, Int?, String) -> Void
    ) {
        self.selection = selection
        self.file = file
        self.comments = comments
        self.canRevert = canRevert
        self.onRevert = onRevert
        self.onComment = onComment
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            HStack(spacing: skin.size.s8) {
                Text(file.status.rawValue)
                    .font(AinkradFontResolver.font(size: 11, weight: .bold, mono: true, typography: typography))
                    .foregroundStyle(statusColor)
                Text(file.path)
                    .font(AinkradFontResolver.font(size: 11, mono: true, typography: typography))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: skin.size.s4)
                if file.diff == nil {
                    Text(file.status == .untracked ? "new" : "binary")
                        .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                        .foregroundStyle(skin.color(skin.text.faint))
                } else {
                    HStack(spacing: skin.size.s4) {
                        Text("+\(file.added)").foregroundStyle(statusColors.success)
                        Text("−\(file.removed)").foregroundStyle(statusColors.danger)
                    }
                    .font(AinkradFontResolver.font(size: 10, mono: true, typography: typography))
                }
                ForgeHeaderPill(isHovered: hovering, action: openInForge)
                if canRevert {
                    AinkradIconButton(
                        systemName: "arrow.uturn.backward", size: skin.size.s22, tooltip: "Revert this file",
                        action: onRevert)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
            .onHover { hovering = $0 }
            // The keyboard's fold (GD35): Tab reaches the header with keyboard navigation on; Space or ↵ folds.
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.space, .return]) { _ in
                isExpanded.toggle()
                return .handled
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isExpanded.toggle() }
            .accessibilityHint(isExpanded ? "Folds the file" : "Unfolds the file")

            if isExpanded {
                if let diff = file.diff, !diff.hunks.isEmpty {
                    DiffBlock(
                        diff: diff, hasFileLines: file.hasFileLines, selection: selection,
                        onLineTap: { hunk, index in
                            comment = ""
                            commenting = LineRef(hunk: hunk.id, index: index)
                        },
                        lineAccessory: { hunk, index in
                            commenting == LineRef(hunk: hunk.id, index: index) ? AnyView(commentField(hunk, index)) : nil
                        })
                }
                ForEach(Array(comments.enumerated()), id: \.offset) { _, text in
                    VStack(alignment: .leading, spacing: skin.size.s2) {
                        Label(text, systemImage: "text.bubble")
                            .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                            .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                        Text("Will be sent with your next message")
                            .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                            .foregroundStyle(skin.color(skin.text.faint))
                    }
                    .padding(skin.size.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(skin.shape(cut: AinkradRadius.sm).fill(statusColors.warning.opacity(skin.opacity.o08)))
                    .overlay(
                        skin.shape(cut: AinkradRadius.sm).stroke(
                            statusColors.warning.opacity(skin.opacity.o50), lineWidth: 1))
                }
            }
        }
        .padding(skin.size.s10)
        .cardSurface(theme.surface.opacity(skin.opacity.o85))
    }

    /// Under a clicked line: what you want the agent to know about it. Return queues it; Esc or ✕ closes.
    private func commentField(_ hunk: AinkradDiffHunk, _ index: Int) -> some View {
        let line = DiffBlock.fileLine(hunk, at: index)
        let add = {
            onComment(comment, file.hasFileLines ? line : nil, hunk.lines[index].text)
            comment = ""
            commenting = nil
        }
        return HStack(spacing: skin.size.s6) {
            AinkradTextField(
                text: $comment, placeholder: file.hasFileLines ? "Comment on line \(line) — ↵ adds it" : "Comment — ↵ adds it",
                focus: $commentFocused
            )
            .onSubmit(add)
            .onExitCommand { commenting = nil }
            // A turn later: focus set in the same update as the click doesn't stick. Reset first, so moving
            // to another line's field (the one focus flag, still true) still moves the caret there.
            .onAppear {
                commentFocused = false
                DispatchQueue.main.async { commentFocused = true }
            }
            AinkradIconButton(systemName: "xmark", size: skin.size.s22, tooltip: "Cancel") { commenting = nil }
        }
        .padding(.vertical, skin.size.s4)
    }

    /// The file in Forge at its first change.
    private var openInForge: (() -> Void)? {
        guard let opener, file.status != .deleted else { return nil }
        let file = file
        return {
            if let hunk = file.diff?.hunks.first {
                DiffBlock.open(file.path, hunk: hunk, at: hunk.lines.firstIndex { $0.kind != .context } ?? 0, with: opener)
            } else {
                opener.open(file.path, nil)
            }
        }
    }

    private var statusColor: Color {
        switch file.status {
        case .modified, .added, .untracked: statusColors.success
        case .deleted: statusColors.danger
        }
    }
}

/// A line in a file card's diff: its hunk's id and its index in the hunk.
private struct LineRef: Equatable {
    var hunk: Int
    var index: Int
}
