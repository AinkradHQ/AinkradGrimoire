import AinkradAppKit
import SwiftUI

/// Forge's ⌘I, arrived (screen 11 B): a new thread in the main pane, prefilled — the selection as a chip (↗ back to
/// Forge, ✕ leaves the code out), the code read-only, the request in the field. Nothing runs until Send; only
/// the header's ✕ discards — Esc is left to the composer, which closes its `@` list with it. The agent, project,
/// mode and model can still be changed in the composer's strip.
struct ForgeAskView: View {
    let model: GrimoireModel
    @State private var project: String
    @State private var harness: Harness
    @State private var mode: PermissionMode
    /// Claude's model alias; `otherModel` for the other agents (nil is their default).
    @State private var agentModel: String
    @State private var otherModel: String?
    @State private var prompt: String
    @State private var context: AskContext?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    init(model: GrimoireModel, ask: ForgeAsk) {
        self.model = model
        _project = State(initialValue: ask.project)
        _harness = State(initialValue: NewThreadSheet.installed(model).first ?? .claude)
        _mode = State(initialValue: model.settings.defaultMode)
        _agentModel = State(initialValue: model.settings.defaultModel)
        _prompt = State(initialValue: ask.prompt)
        _context = State(initialValue: ask.context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            AinkradEmptyState(
                icon: "hammer", title: "From Forge",
                message: "Forge sent a selection. Edit the request, then Send — nothing runs until you do.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
                .padding(.horizontal, skin.size.s14)
                .padding(.bottom, skin.size.s14)
        }
    }

    /// "New thread", and where it will run: project · agent · from Forge ⌘I.
    private var header: some View {
        HStack(alignment: .top, spacing: skin.size.s10) {
            VStack(alignment: .leading, spacing: skin.size.s4) {
                Text("New thread")
                    .font(skin.font(AinkradFontToken(sizeKey: "t15", weight: "semibold")))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o95))
                HStack(spacing: skin.size.s6) {
                    Text((project as NSString).lastPathComponent)
                    HarnessBadge(harness: harness).fixedSize()
                    Text("· from")
                    Text("Forge").foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                    Text("⌘I")
                }
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(skin.color(skin.text.muted))
                .lineLimit(1)
            }
            Spacer(minLength: skin.size.s8)
            AinkradIconButton(systemName: "xmark", size: skin.size.s26, tooltip: "Discard") { discard() }
        }
        .padding(.horizontal, skin.size.s20)
        .padding(.top, skin.size.s14)
        .padding(.bottom, skin.size.s10)
    }

    private var composer: some View {
        AinkradComposer(
            text: $prompt, placeholder: "What should \(harness.displayName) do? (@ for files)", isEditable: true,
            canSend: canSend, autoFocus: true, suggestions: suggestions, onPick: { _, _ in }, onDrop: nil, onSend: send
        ) {
            if let context { selection(context) }
        } leading: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: skin.spacing.sm) { menus(captions: true) }
                HStack(spacing: skin.spacing.sm) { menus(captions: false) }
            }
        } trailing: {
            EmptyView()
        }
    }

    /// The chip and the code, read-only.
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

    @ViewBuilder
    private func menus(captions: Bool) -> some View {
        menu("Agent", captions, harness.displayName, NewThreadSheet.installed(model).map { choice in
            AinkradMenuItem(title: choice.displayName, systemName: choice == harness ? "checkmark" : nil) {
                harness = choice
                otherModel = nil
            }
        })
        menu("Project", captions, (project as NSString).lastPathComponent,
            model.projects.prefix(GrimoireModel.recentLimit).map { candidate in
                AinkradMenuItem(title: candidate.name, systemName: candidate.path == project ? "checkmark" : nil) {
                    project = candidate.path
                }
            })
        menu("Mode", captions, mode.title, PermissionMode.allCases.map { choice in
            AinkradMenuItem(title: choice.title, systemName: choice == mode ? "checkmark" : nil) { mode = choice }
        })
        if harness == .claude {
            menu("Model", captions, agentModel.capitalized, ["opus", "sonnet", "haiku"].map { alias in
                AinkradMenuItem(title: alias.capitalized, systemName: alias == agentModel ? "checkmark" : nil) {
                    agentModel = alias
                }
            })
        } else {
            menu("Model", captions, model.modelName(otherModel, for: harness),
                ([ModelChoice(id: "", name: "Default")] + (model.models[harness] ?? [])).map { choice in
                    AinkradMenuItem(title: choice.name, systemName: choice.id == (otherModel ?? "") ? "checkmark" : nil) {
                        otherModel = choice.id.isEmpty ? nil : choice.id
                    }
                })
        }
    }

    private func menu(_ caption: String, _ captions: Bool, _ value: String, _ items: [AinkradMenuItem]) -> some View {
        AinkradMenuButton(items: items) {
            PullDownLabel { MenuValue(caption: captions ? caption : nil, value: value) }
        }
        .fixedSize()
        .help(caption)
    }

    private func suggestions(_ trigger: AinkradComposerTrigger) -> [AinkradComposerSuggestion] {
        guard case .mention(let query) = trigger else { return [] }
        return ProjectFiles.search(model.files(in: project), query: query).map {
            AinkradComposerSuggestion(
                id: $0, icon: "doc.text", title: ($0 as NSString).lastPathComponent, subtitle: $0, insertText: "@\($0)")
        }
    }

    private var request: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !project.isEmpty && !request.isEmpty }

    private func send() {
        guard canSend else { return }
        let worktree =
            harness == .claude && model.settings.worktreeByDefault
            && FileManager.default.fileExists(atPath: (project as NSString).appendingPathComponent(".git"))
        // Selects the new thread, which clears the ask.
        model.startThread(
            project: project, prompt: context.map { $0.message(request) } ?? request,
            model: harness == .claude ? agentModel : otherModel, mode: mode, worktree: worktree, harness: harness)
    }

    private func discard() { model.forgeAsk = nil }
}
