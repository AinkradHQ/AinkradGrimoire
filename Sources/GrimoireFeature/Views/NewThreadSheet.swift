import AinkradAppKit
import SwiftUI

/// Starts an agent session in a project. The thread also lands in the CLI's
/// own history, so `claude --resume` sees it too.
struct NewThreadSheet: View {
    static let width: CGFloat = 560
    let model: GrimoireModel
    let dismiss: () -> Void
    @State private var project: String
    @State private var agentModel = "opus"
    @State private var mode: PermissionMode = .ask
    @State private var worktree = false
    @State private var prompt = ""
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    init(model: GrimoireModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        _project = State(initialValue: model.selectedThread?.projectPath ?? model.mostRecentProject ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s16) {
            VStack(alignment: .leading, spacing: skin.size.s4) {
                Text("New thread")
                    .font(skin.font(AinkradFontToken(sizeKey: "t16", weight: "semibold")))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o95))
                Text("Starts an agent session in a project. It shows up in that CLI's own history too.")
                    .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                    .foregroundStyle(skin.color(skin.text.muted))
            }

            row("Agent") {
                HStack(spacing: skin.size.s8) {
                    AinkradBadge(text: "Claude Code", tint: theme.accentPrimary)
                    Text("Codex, OpenCode and agy are coming")
                        .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                        .foregroundStyle(skin.color(skin.text.faint))
                }
            }
            row("Project") { projectMenu }
            row("Worktree") {
                HStack(spacing: skin.size.s10) {
                    AinkradToggle(isOn: $worktree).disabled(!isGitRepository)
                    Text(isGitRepository ? "Work in a separate git worktree" : "Not a git repository")
                        .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                        .foregroundStyle(skin.color(skin.text.muted))
                }
            }
            row("Model") {
                AinkradSegmentedPicker(items: ["opus", "sonnet", "haiku"], selection: $agentModel) { $0.capitalized }
                    .fixedSize()
            }
            row("Mode") {
                AinkradSegmentedPicker(items: PermissionMode.allCases, selection: $mode) { $0.title }
                    .fixedSize()
            }

            AinkradTextArea(
                text: $prompt, placeholder: "What should it do?", minHeight: skin.size.s70, maxHeight: skin.size.s200,
                autoFocus: true, onSubmit: start)

            HStack(spacing: skin.size.s8) {
                Spacer(minLength: 0)
                AinkradButton(title: "Cancel", style: .ghost, action: dismiss).fixedSize()
                AinkradButton(title: "Start", style: .primary, icon: "arrow.up", action: start)
                    .fixedSize()
                    .disabled(!canStart)
            }
        }
        .onChange(of: project) { if !isGitRepository { worktree = false } }
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: skin.size.s14) {
            Text(skin.labelCased(label))
                .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
                .foregroundStyle(skin.color(skin.text.muted))
                .frame(width: skin.size.s104, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private var projectMenu: some View {
        AinkradMenuButton(
            items: model.projects.prefix(GrimoireModel.recentLimit).map { candidate in
                AinkradMenuItem(title: candidate.name, systemName: candidate.path == project ? "checkmark" : "folder") {
                    project = candidate.path
                }
            }
        ) {
            PullDownLabel {
                Text(project.isEmpty ? "Choose a project" : (project as NSString).lastPathComponent)
                    .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
            }
        }
        .fixedSize()
        .help(project)
    }

    private var isGitRepository: Bool {
        FileManager.default.fileExists(atPath: (project as NSString).appendingPathComponent(".git"))
    }

    private var canStart: Bool {
        !project.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func start() {
        guard canStart else { return }
        model.startThread(
            project: project, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), model: agentModel,
            mode: mode, worktree: worktree)
        dismiss()
    }
}
