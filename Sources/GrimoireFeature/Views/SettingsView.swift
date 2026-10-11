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
            HStack {
                Text("Settings")
                    .font(skin.font(AinkradFontToken(sizeKey: "t15", weight: "semibold")))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o95))
                Spacer()
                AinkradIconButton(systemName: "xmark", size: skin.size.s26, tooltip: "Close") {
                    model.isShowingSettings = false
                }
            }
            .padding(.horizontal, skin.size.s20)
            .padding(.top, skin.size.s14)
            .padding(.bottom, skin.size.s10)

            ScrollView {
                VStack(alignment: .leading, spacing: skin.size.s16) {
                    group("Agents") {
                        agentRow(badge: "Claude", tint: HarnessBadge.claudeTint, detail: detail(model.cli)) {
                            AinkradButton(title: "Change…", style: .secondary) { chooseCLI() }.fixedSize()
                        }
                        agentRow(badge: "Codex", tint: theme.foreground, detail: detail(model.status(of: .codex))) {
                            EmptyView()
                        }
                        agentRow(badge: "OpenCode", tint: theme.accentTertiary, detail: detail(model.status(of: .opencode))) {
                            EmptyView()
                        }
                        agentRow(
                            badge: "agy", tint: theme.accentPrimary,
                            detail: detail(model.status(of: .agy)) + " · approvals follow agy's own setting") {
                            EmptyView()
                        }
                    }
                    group("New threads") {
                        row("Default model") {
                            AinkradSegmentedPicker(
                                items: ["opus", "sonnet", "haiku"],
                                selection: Binding(get: { settings.defaultModel }, set: { settings.defaultModel = $0 })
                            ) { $0.capitalized }
                            .fixedSize()
                        }
                        row("Default mode") {
                            AinkradSegmentedPicker(
                                items: PermissionMode.allCases,
                                selection: Binding(get: { settings.defaultMode }, set: { settings.defaultMode = $0 })
                            ) { $0.title }
                            .fixedSize()
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
                        ForEach(usageRows, id: \.id) { harness, window, _ in
                            row("\(harness.displayName) · \(window.name) window") {
                                HStack(spacing: skin.size.s10) {
                                    AinkradStatusBar(value: window.utilization)
                                        .frame(width: skin.size.s240)
                                    Text(usageDetail(window))
                                        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                                        .foregroundStyle(skin.color(skin.text.faint))
                                        .fixedSize()
                                }
                            }
                        }
                    }
                    group("MCP servers, hooks & skills") {
                        row("Claude Code's own files") {
                            HStack(spacing: skin.size.s8) {
                                AinkradButton(title: "Open settings.json", style: .secondary) {
                                    open(".claude/settings.json")
                                }
                                .fixedSize()
                                AinkradButton(title: "Open ~/.claude", style: .ghost) { open(".claude") }.fixedSize()
                            }
                        }
                    }
                }
                .padding(.horizontal, skin.size.s20)
                .padding(.bottom, skin.size.s20)
            }
        }
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
        VStack(alignment: .leading, spacing: skin.size.s10) {
            Text(skin.labelCased(title))
                .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
                .foregroundStyle(skin.color(skin.text.muted))
            content()
        }
        .padding(skin.size.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.shape(cut: AinkradRadius.md).fill(theme.surface.opacity(skin.opacity.o60)))
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: skin.size.s14) {
            Text(label)
                .font(skin.font(AinkradFontToken(sizeKey: "t13")))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                .frame(width: skin.size.s200, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func agentRow(badge: String, tint: Color, detail: String, @ViewBuilder action: () -> some View) -> some View
    {
        HStack(spacing: skin.size.s14) {
            AinkradBadge(text: badge, tint: tint)
                .fixedSize()
                .frame(width: skin.size.s200, alignment: .leading)
            Text(detail)
                .font(AinkradFontResolver.font(size: 12, mono: true, typography: typography))
                .foregroundStyle(skin.color(skin.text.muted))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            action()
        }
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
