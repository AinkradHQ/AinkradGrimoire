import AinkradAppKit
import SwiftUI

/// Forge's ⌘I, arrived (screen 11 B): a new thread in the main pane, prefilled — the selection as a chip (↗ back to
/// Forge, ✕ leaves the code out), the code read-only, the request in the field. Nothing runs until Send; only
/// the header's ✕ discards — Esc is left to the composer, which closes its `@` list with it. The agent, project,
/// mode and model can still be changed in the composer's strip.
struct ForgeAskView: View {
    let model: GrimoireModel
    /// The ask as it arrived; the edits are written to `model.forgeAsk` (GD31).
    let arrived: ForgeAsk
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typography

    init(model: GrimoireModel, ask: ForgeAsk) {
        self.model = model
        self.arrived = ask
    }

    private var ask: ForgeAsk { model.forgeAsk ?? arrived }
    private func edit(_ change: (inout ForgeAsk) -> Void) {
        guard var ask = model.forgeAsk else { return }
        change(&ask)
        model.forgeAsk = ask
    }
    private var project: String { ask.project }
    private var harness: Harness { ask.harness ?? NewThreadSheet.installed(model).first ?? .claude }
    private var mode: PermissionMode { ask.mode ?? model.settings.defaultMode }
    /// Claude's model alias; `otherModel` for the other agents (nil is their default).
    private var agentModel: String { ask.agentModel ?? model.settings.defaultModel }
    private var otherModel: String? { ask.otherModel }
    private var context: AskContext? { ask.context }
    private var prompt: Binding<String> {
        Binding(get: { ask.request }, set: { text in edit { $0.request = text } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Mockup 11 B: a small cyan ⚒ and one line, no title.
            VStack(spacing: skin.size.s6) {
                Text("⚒")
                    .font(skin.font(AinkradFontToken(sizeKey: "t28")))
                    .foregroundStyle(theme.accentSecondary.opacity(skin.opacity.o80))
                Text("Forge sent a selection. Edit the request, then Send — nothing runs until you do.")
                    .font(skin.font(AinkradFontToken(sizeKey: "t13")))
                    .foregroundStyle(skin.color(skin.text.muted))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, skin.size.s20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ⌘↵ sends, as the Send button says.
            Button("Send", action: send)  // design-lint: allow raw-control key-equivalent claim
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
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
                // "Ainkrad · feat/glass-sidebar · [Claude] · from Forge ⌘I"; the badge picks the agent.
                HStack(spacing: skin.size.s6) {
                    Text((project as NSString).lastPathComponent)
                    Text("·")
                    if let branch = Self.branch(of: project) {
                        Text(branch).font(AinkradFontResolver.font(size: 11, mono: true, typography: typography))
                        Text("·")
                    }
                    agentMenu
                    Text("· from")
                    Text("Forge").fontWeight(.bold).foregroundStyle(theme.foreground)
                    Text("⌘I")
                }
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(skin.color(skin.text.muted))
                .lineLimit(1)
            }
            Spacer(minLength: skin.size.s8)
            // A newer ⌘I kept by the confirm's Cancel waits here, one click away (GD39).
            if !model.queuedForgeAsks.isEmpty {
                let count = model.queuedForgeAsks.count
                AinkradButton(
                    title: "\(count) more request\(count == 1 ? "" : "s") from Forge", style: .ghost,
                    icon: "tray.full"
                ) { model.showNextForgeAsk() }
                .fixedSize()
            }
            AinkradMenuButton(items: [AinkradMenuItem(title: "Discard", systemName: "trash") { discard() }]) {
                IconMenuLabel(systemName: "ellipsis", size: skin.size.s30)
            }
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, skin.size.s20)
        .padding(.top, skin.size.s14)
        .padding(.bottom, skin.size.s10)
    }

    private var composer: some View {
        AinkradComposer(
            text: prompt, placeholder: "What should \(harness.displayName) do? (@ for files)", isEditable: true,
            canSend: canSend, autoFocus: true, suggestions: suggestions, onPick: { _, _ in }, onDrop: nil, onSend: send
        ) {
            if let context { selection(context) }
        } leading: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: skin.spacing.sm) { menus(captions: true) }
                HStack(spacing: skin.spacing.sm) { menus(captions: false) }
            }
        } trailing: {
            // Esc doesn't discard (10-13: it would lose the ask); ⋯ → Discard does.
            Text("⌘↵ sends")
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(skin.color(skin.text.faint))
                .fixedSize()
        }
        .sendTitle("Send ⌘↵")
        .paletteSuggestionRows()
    }

    /// The agent, as the crumb's badge: a pull-down of the installed agents.
    private var agentMenu: some View {
        AinkradMenuButton(
            items: NewThreadSheet.installed(model).map { choice in
                AinkradMenuItem(title: choice.displayName, systemName: choice == harness ? "checkmark" : nil) {
                    edit {
                        $0.harness = choice
                        $0.otherModel = nil
                    }
                }
            }
        ) {
            HarnessBadge(harness: harness)
        }
        .fixedSize()
        .help("Agent")
    }

    /// The checked-out branch, from `.git/HEAD`; nil when detached or not a plain repository.
    static func branch(of project: String) -> String? {
        let head = try? String(contentsOfFile: (project as NSString).appendingPathComponent(".git/HEAD"), encoding: .utf8)
        let prefix = "ref: refs/heads/"
        guard let head, head.hasPrefix(prefix) else { return nil }
        return head.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The chip and the code, read-only.
    private func selection(_ context: AskContext) -> some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            ContextChip(
                context: context,
                open: { model.openInForge(context.file, line: context.lines.lowerBound, directory: context.project) },
                remove: { edit { $0.context = nil } })
            OutputBlock(text: context.numbered, maxLines: 8)
        }
    }

    /// MODE and MODEL only (mockup 11 B): the agent is the crumb's badge, the project is Forge's.
    @ViewBuilder
    private func menus(captions: Bool) -> some View {
        menu("Mode", captions, mode.title, chevron: false, PermissionMode.allCases.map { choice in
            AinkradMenuItem(title: choice.title, systemName: choice == mode ? "checkmark" : nil) { edit { $0.mode = choice } }
        })
        if harness == .claude {
            menu("Model", captions, agentModel.capitalized, ["opus", "sonnet", "haiku"].map { alias in
                AinkradMenuItem(title: alias.capitalized, systemName: alias == agentModel ? "checkmark" : nil) {
                    edit { $0.agentModel = alias }
                }
            })
        } else {
            menu("Model", captions, model.modelName(otherModel, for: harness),
                ([ModelChoice(id: "", name: "Default")] + (model.models[harness] ?? [])).map { choice in
                    AinkradMenuItem(title: choice.name, systemName: choice.id == (otherModel ?? "") ? "checkmark" : nil) {
                        edit { $0.otherModel = choice.id.isEmpty ? nil : choice.id }
                    }
                })
        }
    }

    private func menu(
        _ caption: String, _ captions: Bool, _ value: String, chevron: Bool = true, _ items: [AinkradMenuItem]
    ) -> some View {
        AinkradMenuButton(items: items) {
            PullDownLabel(showsChevron: chevron) { MenuValue(caption: captions ? caption : nil, value: value) }
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

    private var request: String { ask.request.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !project.isEmpty && !request.isEmpty }

    private func send() {
        guard canSend else { return }
        let worktree =
            harness == .claude && model.settings.worktreeByDefault
            && FileManager.default.fileExists(atPath: (project as NSString).appendingPathComponent(".git"))
        let (project, prompt, harness, mode) = (project, context.map { $0.message(request) } ?? request, harness, mode)
        let agentModel = harness == .claude ? agentModel : otherModel
        // Sent, not set aside: the ask goes before the new thread is selected (its edits are read above). The new
        // thread stays in front; Forge's waiting requests show in the strip over it (GD39).
        model.forgeAsk = nil
        model.startThread(
            project: project, prompt: prompt, model: agentModel, mode: mode, worktree: worktree, harness: harness)
    }

    /// Discarded, the next waiting request (if any) comes up in its place.
    private func discard() {
        model.forgeAsk = nil
        model.showNextForgeAsk()
    }
}

/// Forge's selection as mockup 11 B's chip: a cyan-rimmed chip with the file's ◆, its mono name, the range, and ↗ (back
/// to Forge) and ✕ (leave the code out) inside it.
private struct ContextChip: View {
    let context: AskContext
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typography

    // design-lint: allow raw-color kit-gap file-type glyph (the mockup's Swift-file orange)
    private static let fileTint = Color(.sRGB, red: 0xF9 / 255, green: 0x73 / 255, blue: 0x16 / 255)

    var body: some View {
        let shape = skin.usesNativeGlass ? AnyShape(Capsule()) : AnyShape(skin.shape(cut: skin.size.s5))
        HStack(spacing: skin.size.s8) {
            Text("◆").foregroundStyle(Self.fileTint)
            Text((context.file as NSString).lastPathComponent)
                .font(AinkradFontResolver.font(size: 11.5, mono: true, typography: typography))
                .foregroundStyle(theme.foreground)
            Text(range).foregroundStyle(skin.color(skin.text.faint))
            chipButton("↗", help: "Open in Forge", action: open)
            chipButton("✕", help: "Leave the code out", action: remove)
        }
        .font(skin.font(AinkradFontToken(sizeKey: "t11")))
        .lineLimit(1)
        .padding(.horizontal, skin.size.s10)
        .padding(.vertical, skin.size.s4)
        .background(shape.fill(skin.usesNativeGlass ? theme.accentSecondary.opacity(skin.opacity.o10) : theme.background.opacity(skin.opacity.o96)))
        .overlay(shape.stroke(theme.accentSecondary.opacity(skin.opacity.o45), lineWidth: 1))
        .fixedSize()
    }

    /// "· lines 18–21 · 4 lines".
    private var range: String {
        let lines = context.lines
        return lines.count > 1 ? "· lines \(lines.lowerBound)–\(lines.upperBound) · \(lines.count) lines" : "· line \(lines.lowerBound)"
    }

    private func chipButton(_ glyph: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {  // design-lint: allow raw-control glyph button inside the chip
            Text(glyph).foregroundStyle(skin.color(skin.text.faint)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
