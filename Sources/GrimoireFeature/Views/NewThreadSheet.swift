import AinkradAppKit
import SwiftUI

/// Starts an agent session in a project. The thread also lands in the CLI's
/// own history, so `claude --resume` sees it too.
struct NewThreadSheet: View {
    static let width: CGFloat = 560
    let model: GrimoireModel
    let dismiss: () -> Void
    @State private var project: String
    @State private var agentModel: String
    /// The non-Claude agent's model; nil is its configured default.
    @State private var otherModel: String?
    @State private var mode: PermissionMode
    @State private var worktree: Bool
    @State private var harness: Harness
    @State private var prompt = ""
    /// Forge's selection (⌘I), sent with the words unless removed.
    @State private var context: AskContext?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    init(model: GrimoireModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        let preset = model.newThreadPreset
        let project = preset?.project ?? model.selectedThread?.projectPath ?? model.mostRecentProject ?? ""
        _project = State(initialValue: project)
        _prompt = State(initialValue: preset?.prompt ?? "")
        _context = State(initialValue: preset?.context)
        _agentModel = State(initialValue: model.settings.defaultModel)
        _harness = State(initialValue: Self.installed(model).first ?? .claude)
        _mode = State(initialValue: model.settings.defaultMode)
        _worktree = State(
            initialValue: model.settings.worktreeByDefault
                && FileManager.default.fileExists(atPath: (project as NSString).appendingPathComponent(".git")))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s16) {
            VStack(alignment: .leading, spacing: skin.size.s4) {
                Text("New thread")
                    .font(skin.font(AinkradFontToken(sizeKey: "t16", weight: "semibold")))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o95))
                Text(
                    model.newThreadPreset?.context != nil
                        ? "From Forge ⌘I: it sent a selection. Edit the request, then Start — nothing runs until you do."
                        : "Starts an agent session in a project. It shows up in that CLI's own history too."
                )
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .foregroundStyle(skin.color(skin.text.muted))
            }

            row("Agent") {
                HStack(spacing: skin.size.s8) {
                    AinkradSegmentedPicker(items: Self.installed(model), selection: $harness) { $0.displayName }
                        .fixedSize()
                    Text(harness == .agy ? "agy runs tools per its own permission setting" : "")
                        .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                        .foregroundStyle(skin.color(skin.text.faint))
                }
            }
            row("Project") { projectMenu }
            row("Worktree") {
                HStack(spacing: skin.size.s10) {
                    AinkradToggle(isOn: $worktree).disabled(!canUseWorktree)
                    Text(worktreeNote)
                        .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                        .foregroundStyle(skin.color(skin.text.muted))
                }
            }
            row("Model") {
                if harness == .claude {
                    AinkradSegmentedPicker(items: ["opus", "sonnet", "haiku"], selection: $agentModel) { $0.capitalized }
                        .fixedSize()
                } else {
                    otherModelMenu
                }
            }
            row("Mode") {
                AinkradSegmentedPicker(items: PermissionMode.allCases, selection: $mode) { $0.title }
                    .fixedSize()
            }

            if let context { selection(context) }

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
        .onChange(of: project) { if !canUseWorktree { worktree = false } }
        .onChange(of: harness) {
            if !canUseWorktree { worktree = false }
            otherModel = nil
        }
    }

    /// The chip (file · lines; ↗ back to Forge, ✕ leaves the code out) and the code, read-only.
    private func selection(_ context: AskContext) -> some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            HStack(spacing: skin.size.s6) {
                AinkradChip(label: context.label, systemName: "doc.text") { self.context = nil }
                AinkradIconButton(systemName: "arrow.up.right", size: skin.size.s22, tooltip: "Open in Forge") {
                    model.openInForge(context.file, line: context.lines.lowerBound, directory: context.project)
                }
            }
            OutputBlock(text: context.numbered, maxLines: 8)
        }
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

    private var otherModelMenu: some View {
        let choices = [ModelChoice(id: "", name: "Default")] + (model.models[harness] ?? [])
        return AinkradMenuButton(
            items: choices.map { choice in
                AinkradMenuItem(title: choice.name, systemName: choice.id == (otherModel ?? "") ? "checkmark" : nil) {
                    otherModel = choice.id.isEmpty ? nil : choice.id
                }
            }
        ) {
            PullDownLabel {
                Text(model.modelName(otherModel, for: harness))
                    .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
            }
        }
        .fixedSize()
    }

    private var isGitRepository: Bool {
        FileManager.default.fileExists(atPath: (project as NSString).appendingPathComponent(".git"))
    }

    /// The agents whose CLI was found; Claude when none is, so the sheet still lays out.
    static func installed(_ model: GrimoireModel) -> [Harness] {
        let found = Harness.allCases.filter {
            if case .found = model.status(of: $0) { true } else { false }
        }
        return found.isEmpty ? [.claude] : found
    }

    /// Worktrees are Claude Code's `--worktree`; the other agents have none.
    private var canUseWorktree: Bool { isGitRepository && harness == .claude }

    private var worktreeNote: String {
        if harness != .claude { return "\(harness.displayName) works in the folder itself" }
        return isGitRepository ? "Work in a separate git worktree" : "Not a git repository"
    }

    private var canStart: Bool {
        !project.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func start() {
        guard canStart else { return }
        model.startThread(
            project: project,
            prompt: context.map { $0.message(prompt.trimmingCharacters(in: .whitespacesAndNewlines)) }
                ?? prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            model: harness == .claude ? agentModel : otherModel, mode: mode, worktree: worktree, harness: harness)
        dismiss()
    }
}
