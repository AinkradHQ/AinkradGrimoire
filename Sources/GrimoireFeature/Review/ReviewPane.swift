import AinkradAppKit
import SwiftUI

/// Beside the conversation: what changed (this turn, the whole thread, or
/// everything uncommitted), comments for the agent, and the commit.
struct ReviewPane: View {
    @Bindable var review: ReviewModel
    let close: () -> Void
    @State private var reverting: FileChange?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s10) {
            header
            AinkradSegmentedPicker(items: ReviewScope.allCases, selection: $review.scope) { $0.rawValue }
                .fixedSize()
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
                                startsExpanded: review.files.count <= 3,
                                onRevert: { reverting = file },
                                onComment: { review.addComment($0, on: file.path) })
                        }
                    }
                }
            }
            footer
        }
        .padding(skin.size.s14)
        .frame(minWidth: skin.size.s320, idealWidth: skin.size.s440, maxWidth: skin.size.s440)
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
    }

    private var header: some View {
        HStack(spacing: skin.size.s8) {
            Text(skin.labelCased("Changes"))
                .font(skin.font(AinkradFontToken(sizeKey: "t11", weight: "semibold")))
                .foregroundStyle(skin.color(skin.text.muted))
            Spacer(minLength: 0)
            let totals = review.totals
            Text(
                "\(review.files.count == 1 ? "1 file" : "\(review.files.count) files") · +\(totals.added) −\(totals.removed)"
            )
            .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
            .foregroundStyle(skin.color(skin.text.faint))
            AinkradIconButton(systemName: "xmark", size: skin.size.s24, tooltip: "Close", action: close)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            if !review.comments.isEmpty {
                AinkradButton(
                    title: review.comments.count == 1 ? "Send 1 comment" : "Send \(review.comments.count) comments",
                    style: .secondary, icon: "text.bubble"
                ) { review.sendComments() }
                .frame(maxWidth: .infinity)
            }
            AinkradTextField(text: $review.commitMessage, placeholder: "Commit message")
            HStack(spacing: skin.size.s8) {
                AinkradButton(title: "Commit", style: .primary) { Task { await review.commit() } }
                    .fixedSize()
                AinkradButton(title: "Commit & open PR", style: .secondary) {
                    Task { await review.commitAndOpenPullRequest() }
                }
                .fixedSize()
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
    let onRevert: () -> Void
    let onComment: (String) -> Void
    @State private var isExpanded: Bool
    @State private var comment = ""
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography

    init(
        file: FileChange, comments: [String], canRevert: Bool, startsExpanded: Bool, onRevert: @escaping () -> Void,
        onComment: @escaping (String) -> Void
    ) {
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
                    Text("+\(file.added) −\(file.removed)")
                        .font(skin.font(AinkradFontToken(sizeKey: "t10", monospacedDigits: true)))
                        .foregroundStyle(skin.color(skin.text.faint))
                }
                if canRevert {
                    AinkradIconButton(
                        systemName: "arrow.uturn.backward", size: skin.size.s22, tooltip: "Revert this file",
                        action: onRevert)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            if isExpanded {
                if let diff = file.diff, !diff.hunks.isEmpty {
                    DiffBlock(diff: diff)
                }
                ForEach(Array(comments.enumerated()), id: \.offset) { _, text in
                    VStack(alignment: .leading, spacing: skin.size.s2) {
                        Label(text, systemImage: "text.bubble")
                            .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                            .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                        Text("Sent with your next message")
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
                HStack(spacing: skin.size.s6) {
                    AinkradTextField(text: $comment, placeholder: "Comment for the agent…")
                    AinkradIconButton(systemName: "plus.bubble", size: skin.size.s26, tooltip: "Add comment") {
                        onComment(comment)
                        comment = ""
                    }
                    .disabled(comment.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(skin.size.s10)
        .background(skin.shape(cut: AinkradRadius.md).fill(theme.surface.opacity(skin.opacity.o60)))
    }

    private var statusColor: Color {
        switch file.status {
        case .modified: statusColors.warning
        case .added, .untracked: statusColors.success
        case .deleted: statusColors.danger
        }
    }
}
