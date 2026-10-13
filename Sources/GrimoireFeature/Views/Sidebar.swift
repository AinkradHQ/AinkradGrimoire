import AinkradAppKit
import AppKit
import SwiftUI

/// Projects → threads. Surfaces are told apart by fill, never by a line.
struct Sidebar: View {
    @Bindable var model: GrimoireModel
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            HStack {
                Text(skin.labelCased(GrimoireApp.displayName))
                    .font(skin.font(AinkradFontToken(sizeKey: "t14", weight: "bold")))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                Spacer(minLength: 0)
                AinkradIconButton(systemName: "gearshape", size: skin.size.s26, tooltip: "Settings") {
                    model.isShowingSettings.toggle()
                }
            }
            .padding(.leading, skin.size.s6)

            HStack(spacing: AinkradSpacing.sm) {
                AinkradButton(title: "New thread", style: .primary, icon: "plus") { model.isComposingNewThread = true }
                    .disabled(model.projects.isEmpty)
                    .fixedSize()
                AinkradButton(title: "Open folder…", style: .secondary) { chooseFolder() }
                    .fixedSize()
            }

            AinkradSearchField(text: $model.searchText, placeholder: "Search threads", focus: $isSearchFocused)
                // ⌘F. A turn later: focus set in the same update as the key event doesn't stick.
                .onChange(of: model.searchFocusRequest) { DispatchQueue.main.async { isSearchFocused = true } }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: skin.size.s1) {
                    ForEach(model.visibleProjects) { project in
                        projectSection(project)
                    }
                    if let title = Self.noMatchTitle(query: model.searchText, visible: model.visibleProjects) {
                        AinkradEmptyState(
                            icon: "magnifyingglass", title: title, message: "Search looks at thread titles and project names.")
                        .padding(.top, skin.size.s20)
                    }
                    if model.hiddenProjectCount > 0 {
                        ShowAllRow(count: model.projects.count) { model.showsAllProjects = true }
                    }
                }
            }
            .scrollIndicators(.never)

            footer
        }
        .padding(.top, skin.size.s12)
        .padding(.horizontal, skin.size.s10)
        .padding(.bottom, skin.size.s10)
        // Gives way before the thread does in a narrow window (GD16).
        .frame(minWidth: skin.size.s260, idealWidth: skin.size.s300, maxWidth: skin.size.s300)
        .frame(maxHeight: .infinity, alignment: .top)
        // Fill, not a rule.
        .background(theme.surface.opacity(skin.opacity.o35))
    }

    @ViewBuilder
    private func projectSection(_ project: ClaudeProject) -> some View {
        let expanded = model.isExpanded(project)
        ProjectRow(project: project, isExpanded: expanded) {
            model.settings.toggle(project.path, mostRecent: model.mostRecentProject)
        }
        if expanded {
            ForEach(project.sessions) { thread in
                ThreadRow(
                    thread: thread, status: model.liveThreads[thread.id]?.status,
                    isSelected: thread.id == model.selectedThreadID
                ) {
                    model.selectedThreadID = thread.id
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: skin.size.s6) {
            let statuses = model.liveThreads.values.map(\.status)
            let working = statuses.filter { $0 == .working }.count
            let waiting = statuses.filter { $0 == .needsYou }.count
            if working > 0 { Text("\(working) working") }
            if waiting > 0 { Text("\(waiting) needs you") }
            if model.cli == .checking {
                Text("Looking for agents…")
            } else {
                // Names only, so three agents fit; versions are in the tooltip and Settings.
                let found = Harness.allCases.compactMap { harness -> (String, String)? in
                    guard case .found(_, let version) = model.status(of: harness) else { return nil }
                    return (harness.command, version)
                }
                Text(found.isEmpty ? "No coding agent found" : found.map(\.0).joined(separator: " · "))
                    .help(found.map { "\($0.0) \($0.1)" }.joined(separator: "\n"))
            }
            Spacer(minLength: 0)
            if model.isLoading {
                AinkradSpinner()
            }
        }
        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
        .foregroundStyle(skin.color(skin.text.muted))
        .lineLimit(1)
        .padding(.horizontal, skin.size.s6)
    }

    /// "No threads match “x”" when a search hides every project (GD20); nil otherwise.
    static func noMatchTitle(query: String, visible: [ClaudeProject]) -> String? {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || !visible.isEmpty ? nil : "No threads match “\(query)”"
    }

    private func chooseFolder() {
        if let url = FolderPicker.choose() { model.openFolder(url) }
    }
}

private struct ProjectRow: View {
    let project: ClaudeProject
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        // A plain button, so Full Keyboard Access can focus it and Space toggles it.
        Button(action: toggle) {  // design-lint: allow raw-control keyboard-reachable row (kit has no row button)
            label
        }
        .buttonStyle(.plain)
        .help(project.path)
        .padding(.top, skin.size.s4)
    }

    private var label: some View {
        HStack(spacing: skin.size.s8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(skin.font(AinkradFontToken(sizeKey: "t9", weight: "semibold")))
                .foregroundStyle(skin.color(skin.text.faint))
                .frame(width: skin.size.s10)
            Text(project.name)
                .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "semibold")))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                .lineLimit(1)
            Spacer(minLength: skin.size.s4)
            Text("\(project.sessions.count)")
                .font(skin.font(AinkradFontToken(sizeKey: "t10", monospacedDigits: true)))
                .foregroundStyle(skin.color(skin.text.faint))
        }
        .padding(.vertical, skin.size.s6)
        .padding(.horizontal, skin.size.s8)
        .ainkradRowBackground(isSelected: false, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// Cyan pulse while working, amber when it needs you, red after a failure;
/// an empty slot keeps titles aligned.
private struct StatusDot: View {
    let status: LiveThread.Status?
    @State private var dim = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: skin.size.s7, height: skin.size.s7)
            .opacity(status == .working && dim ? skin.opacity.o35 : 1)
            .onAppear { pulse() }
            .onChange(of: status) { pulse() }
    }

    private var color: Color {
        switch status {
        case .working: theme.accentSecondary
        case .needsYou: statusColors.warning
        case .failed: statusColors.danger
        case .idle, nil: .clear
        }
    }

    private func pulse() {
        guard status == .working, !reduceMotion else {
            dim = false
            return
        }
        withAnimation(skin.animation(skin.motion.hover).repeatForever(autoreverses: true)) { dim = true }
    }
}

private struct ThreadRow: View {
    let thread: ClaudeSessionSummary
    /// Set while the thread is open this run; drives the status dot.
    let status: LiveThread.Status?
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        Button(action: select) {  // design-lint: allow raw-control keyboard-reachable row (kit has no row button)
            label
        }
        .buttonStyle(.plain)
        .help(thread.gitBranch.map { "\(thread.title) — \($0)" } ?? thread.title)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: skin.size.s3) {
            HStack(spacing: skin.size.s8) {
                StatusDot(status: status)
                Text(thread.title)
                    .font(skin.font(AinkradFontToken(sizeKey: "t13")))
                    .foregroundStyle(theme.foreground.opacity(isSelected ? skin.opacity.o95 : skin.opacity.o85))
                    .lineLimit(1)
                Spacer(minLength: skin.size.s4)
                Text(RelativeTime.short(thread.lastActivity))
                    .font(skin.font(AinkradFontToken(sizeKey: "t10", monospacedDigits: true)))
                    .foregroundStyle(skin.color(skin.text.faint))
            }
            // On a selected row (a solid accent fill under Glass) badges take the
            // foreground colour so they stay readable.
            HStack(spacing: skin.size.s6) {
                HarnessBadge(harness: thread.harness, onSelection: isSelected)
                if let worktree = thread.worktree {
                    AinkradBadge(text: "⑂ \(worktree)", tint: isSelected ? theme.foreground : theme.accentSecondary)
                }
                if status == .needsYou {
                    Text("needs you").foregroundStyle(statusColors.warning)
                } else if case .failed = status {
                    Text("failed").foregroundStyle(statusColors.danger)
                }
            }
            .font(skin.font(AinkradFontToken(sizeKey: "t11")))
            .padding(.leading, skin.size.s15)
        }
        .padding(.vertical, skin.size.s6)
        .padding(.leading, skin.size.s8)
        .padding(.trailing, skin.size.s8)
        .ainkradRowBackground(isSelected: isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct ShowAllRow: View {
    let count: Int
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        Button(action: action) {  // design-lint: allow raw-control keyboard-reachable row (kit has no row button)
            label
        }
        .buttonStyle(.plain)
        .padding(.top, skin.size.s4)
    }

    private var label: some View {
        Text("Show all \(count) projects…")
            .font(skin.font(AinkradFontToken(sizeKey: "t12")))
            .foregroundStyle(skin.color(skin.text.muted))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, skin.size.s6)
            .padding(.horizontal, skin.size.s8)
            .ainkradRowBackground(isSelected: false, isHovered: isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

/// Which agent a thread runs on: Claude in its brand clay, Codex in the
/// foreground colour, OpenCode and agy in the theme's tertiary and primary accents.
struct HarnessBadge: View {
    // design-lint: allow raw-color kit-gap colors.providerBrand (Claude's brand clay, as Sage's model picker)
    static let claudeTint = Color(.sRGB, red: 0xCC / 255, green: 0x78 / 255, blue: 0x5C / 255)

    let harness: Harness
    /// On a selected row's accent fill every badge takes the foreground colour.
    var onSelection = false
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        AinkradBadge(
            text: harness.displayName,
            tint: onSelection ? theme.foreground : tint)
    }

    private var tint: Color {
        switch harness {
        case .claude: Self.claudeTint
        case .codex: theme.foreground
        case .opencode: theme.accentTertiary
        case .agy: theme.accentPrimary
        }
    }
}

/// Compact relative times for thread rows: now, 5m, 3h, yesterday, Oct 2.
enum RelativeTime {
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3_600))h" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "yesterday"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
