import AinkradAppKit
import AppKit
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
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typography

    init(model: GrimoireModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        let project = model.selectedThread?.projectPath ?? model.mostRecentProject ?? ""
        _project = State(initialValue: project)
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
                Text("Starts an agent session in a project. It shows up in that CLI's own history too.")
                    .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                    .foregroundStyle(skin.color(skin.text.muted))
            }

            row("Agent") {
                // Every agent (mockup 7); one that isn't installed is disabled, and Install… copies its command.
                HStack(spacing: skin.size.s8) {
                    AinkradSegmentedPicker(items: Harness.allCases, selection: $harness) {
                        $0 == .claude ? "Claude Code" : $0.displayName
                    }
                    .disabledOptions { !Self.isFound($0, in: model) }
                    .fixedSize()
                    let missing = Harness.allCases.filter { !Self.isFound($0, in: model) }
                        .compactMap { harness in NoAgentView.installCommand(harness).map { (harness, $0) } }
                    if !missing.isEmpty {
                        AinkradMenuButton(
                            items: missing.map { harness, command in
                                AinkradMenuItem(
                                    title: "Copy the \(harness.displayName) install command", systemName: "doc.on.doc"
                                ) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(command, forType: .string)
                                }
                            }
                        ) {
                            Text(skin.labelCased("Install…"))
                                .font(skin.font(AinkradFontToken(sizeKey: "t11", weight: "semibold")))
                                .foregroundStyle(theme.accentSecondary)
                        }
                        .fixedSize()
                        .help(missing.map(\.1).joined(separator: "\n"))
                    } else if harness == .agy {
                        Text("agy runs tools per its own permission setting")
                            .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                            .foregroundStyle(skin.color(skin.text.faint))
                    }
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

            AinkradTextArea(
                text: $prompt, placeholder: "What should it do?", minHeight: skin.size.s70, maxHeight: skin.size.s200,
                autoFocus: true, onSubmit: start)

            HStack(spacing: skin.size.s8) {
                Spacer(minLength: 0)
                AinkradButton(title: "Cancel", style: .ghost, action: dismiss).borderless().secondaryAccent().fixedSize()
                AinkradButton(title: "Start ⌘↵", style: .primary, action: start)
                    .fixedSize()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canStart)
            }
        }
        .onChange(of: project) { if !canUseWorktree { worktree = false } }
        .onChange(of: harness) {
            if !canUseWorktree { worktree = false }
            otherModel = nil
        }
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: skin.size.s14) {
            Text(skin.labelCased(label))
                .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
                .foregroundStyle(skin.color(skin.text.muted))
                .frame(width: skin.size.s120 + skin.size.s10, alignment: .leading)
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
            // Full width: the name, then where it is (mockup 7: "Ainkrad   ~/…/Repositories/Ainkrad ▾").
            PullDownLabel {
                HStack(spacing: skin.size.s8) {
                    Text(project.isEmpty ? "Choose a project" : (project as NSString).lastPathComponent)
                        .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                        .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                    Spacer(minLength: skin.size.s8)
                    Text(Self.shortPath(project))
                        .font(AinkradFontResolver.font(size: 11, mono: true, typography: typography))
                        .foregroundStyle(skin.color(skin.text.faint))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
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

    /// `~/Home/Projects/Ainkrad/Repositories/Ainkrad` → `~/…/Repositories/Ainkrad`; short paths unchanged.
    static func shortPath(_ path: String) -> String {
        let parts = (path as NSString).abbreviatingWithTildeInPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 4 else { return (path as NSString).abbreviatingWithTildeInPath }
        return ([parts[0], "…"] + parts.suffix(2)).joined(separator: "/")
    }

    private var isInstalled: Bool { Self.isFound(harness, in: model) }

    static func isFound(_ harness: Harness, in model: GrimoireModel) -> Bool {
        if case .found = model.status(of: harness) { true } else { false }
    }

    /// The agents whose CLI was found; Claude when none is, so the sheet still lays out.
    static func installed(_ model: GrimoireModel) -> [Harness] {
        let found = Harness.allCases.filter { isFound($0, in: model) }
        return found.isEmpty ? [.claude] : found
    }

    /// Worktrees are Claude Code's `--worktree`; the other agents have none.
    private var canUseWorktree: Bool { isGitRepository && harness == .claude }

    private var worktreeNote: String {
        if harness != .claude { return "\(harness.displayName) works in the folder itself" }
        return isGitRepository ? "Work in a separate git worktree" : "Not a git repository"
    }

    private var canStart: Bool {
        isInstalled && !project.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func start() {
        guard canStart else { return }
        model.startThread(
            project: project, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            model: harness == .claude ? agentModel : otherModel, mode: mode, worktree: worktree, harness: harness)
        dismiss()
    }
}
