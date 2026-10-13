import AinkradAppKit
import AppKit
import SwiftUI

/// Grimoire's own settings. The agents' configuration (MCP servers, hooks,
/// skills, allow rules) stays in each CLI's files — this links to them.
struct SettingsView: View {
    let model: GrimoireModel
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typography

    private var settings: SettingsStore { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title only (mockup 8): the gear and any thread take you back.
            Text("Settings")
                .font(skin.font(AinkradFontToken(sizeKey: "t15", weight: "semibold")))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o95))
                .padding(.horizontal, skin.size.s20)
                .padding(.top, skin.size.s14)
                .padding(.bottom, skin.size.s10)

            ScrollView {
                VStack(alignment: .leading, spacing: skin.size.s18) {
                    group("Agents") {
                        agentRow(.claude, detail: detail(model.cli) + (config.isSignedIn ? " · signed in" : "")) {
                            AinkradButton(title: "Change…", style: .secondary) { chooseCLI() }.secondaryAccent().fixedSize()
                        }
                        agentRow(.codex, detail: detail(model.status(of: .codex))) { none }
                        agentRow(.opencode, detail: detail(model.status(of: .opencode))) { none }
                        agentRow(.agy, detail: detail(model.status(of: .agy)) + " · approvals follow agy's own setting") {
                            none
                        }
                    }
                    group("New threads") {
                        row("Default model") { defaultModelMenu }
                        row("Default mode") {
                            FittingPicker(
                                items: [.ask, .acceptEdits, .plan],
                                selection: Binding(get: { settings.defaultMode }, set: { settings.defaultMode = $0 })
                            ) { $0.title }
                        }
                        row("Use a worktree") {
                            AinkradToggle(
                                isOn: Binding(
                                    get: { settings.worktreeByDefault }, set: { settings.worktreeByDefault = $0 }))
                        }
                        row("Notify when it needs me") {
                            AinkradToggle(
                                isOn: Binding(
                                    get: { settings.notifyWhenNeeded }, set: { settings.notifyWhenNeeded = $0 }))
                        }
                    }
                    group("Usage") {
                        if model.usage.isEmpty {
                            Text("Shown once an agent reports its limits — Claude after a turn, Codex when listed.")
                                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                                .foregroundStyle(skin.color(skin.text.muted))
                        }
                        let rows = usageRows
                        let agents = Set(rows.map(\.harness)).count
                        ForEach(rows, id: \.id) { harness, window, _ in
                            // The agent's name only when more than one reports windows.
                            row(agents > 1 ? "\(harness.displayName) · \(window.name) window" : "\(window.name) window") {
                                UsageMeter(value: window.utilization, tint: theme.accentSecondary)
                            } trailing: {
                                Text(usageDetail(window))
                                    .font(AinkradFontResolver.font(size: 11, mono: true, typography: typography))
                                    .foregroundStyle(skin.color(skin.text.faint))
                                    .fixedSize()
                            }
                        }
                    }
                    group("MCP servers & hooks") {
                        row("From ~/.claude") {
                            Text(config.summary)
                                .font(skin.font(AinkradFontToken(sizeKey: "t13")))
                                .foregroundStyle(skin.color(skin.text.muted))
                                .lineLimit(1)
                        } trailing: {
                            AinkradButton(title: "Open settings.json", style: .secondary) { open(".claude/settings.json") }
                                .secondaryAccent()
                                .fixedSize()
                        }
                    }
                }
                .padding(.horizontal, skin.size.s28)
                .padding(.top, skin.size.s8)
                .padding(.bottom, skin.size.s28)
            }
        }
        .task { config = ClaudeConfig.read(claudeHome: model.sessionsRoot.deletingLastPathComponent()) }
    }

    @State private var config = ClaudeConfig()

    private var none: some View {
        Text("—").foregroundStyle(skin.color(skin.text.faint))
    }

    /// "Opus ▾": a pull-down, as the composer's Model (mockup 8).
    private var defaultModelMenu: some View {
        AinkradMenuButton(
            items: ["opus", "sonnet", "haiku"].map { alias in
                AinkradMenuItem(title: alias.capitalized, systemName: alias == settings.defaultModel ? "checkmark" : nil) {
                    settings.defaultModel = alias
                }
            }
        ) {
            PullDownLabel { MenuValue(caption: nil, value: settings.defaultModel.capitalized) }
        }
        .fixedSize()
        .help("Default model")
    }

    private func detail(_ status: CLIStatus) -> String {
        switch status {
        case .found(let path, let version): "\((path as NSString).abbreviatingWithTildeInPath) · \(version)"
        case .missing: "Not found on your PATH"
        case .checking: "Looking…"
        }
    }

    /// Every agent's windows, in agent order.
    private var usageRows: [(harness: Harness, window: UsageWindow, id: String)] {
        Harness.allCases.flatMap { harness in
            (model.usage[harness] ?? []).map { (harness, $0, "\(harness.rawValue)-\($0.name)") }
        }
    }

    private func usageDetail(_ window: UsageWindow) -> String {
        let percent = "\(Int((window.utilization * 100).rounded()))%"
        guard let resets = window.resetsAt else { return percent }
        let when =
            Calendar.current.isDateInToday(resets)
            ? resets.formatted(date: .omitted, time: .shortened)
            : resets.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "\(percent) · resets \(when)"
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(skin.labelCased(title))
                .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
                .foregroundStyle(skin.color(skin.text.muted))
                .padding(.bottom, skin.size.s2)
            content()
        }
        .padding(.horizontal, skin.size.s16)
        .padding(.vertical, skin.size.s14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(theme.surface.opacity(skin.opacity.o75))
    }

    /// Mockup `.srow`: a 170 pt label, the control, then anything trailing; the control goes under its label when
    /// the pane is too narrow for both (GD16).
    private func row(
        _ label: String, @ViewBuilder content: () -> some View, @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        let text = Text(label)
            .font(skin.font(AinkradFontToken(sizeKey: "t13")))
            .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: skin.size.s12) {
                text.frame(width: skin.size.s160 + skin.size.s10, alignment: .leading)
                content()
                Spacer(minLength: 0)
                trailing()
            }
            VStack(alignment: .leading, spacing: skin.size.s8) {
                text
                HStack(spacing: skin.size.s12) {
                    content()
                    trailing()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, skin.size.s8)
    }

    private func agentRow(_ harness: Harness, detail: String, @ViewBuilder action: () -> some View) -> some View {
        let badge = HarnessBadge(harness: harness).fixedSize()
        let detail = Text(detail)
            .font(AinkradFontResolver.font(size: 12, mono: true, typography: typography))
            .foregroundStyle(skin.color(skin.text.muted))
            .lineLimit(1)
            .truncationMode(.middle)
        // Narrow (GD26), the path goes under the badge rather than shrink to "…".
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: skin.size.s12) {
                badge.frame(width: skin.size.s160 + skin.size.s10, alignment: .leading)
                detail.fixedSize()
                Spacer(minLength: 0)
                action()
            }
            VStack(alignment: .leading, spacing: skin.size.s4) {
                HStack(spacing: skin.size.s14) {
                    badge
                    Spacer(minLength: 0)
                    action()
                }
                detail
            }
        }
        .padding(.vertical, skin.size.s8)
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Use this CLI"
        panel.message = "Choose the claude executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.cliPathOverride = url.path
        Task { await model.reload() }
    }

    private func open(_ relative: String) {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative))
    }
}
