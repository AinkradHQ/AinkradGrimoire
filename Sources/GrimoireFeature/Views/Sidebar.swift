import AinkradAppKit
import AppKit
import SwiftUI

/// Projects → threads. Surfaces are told apart by fill, never by a line.
struct Sidebar: View {
    @Bindable var model: GrimoireModel
    /// A narrow window (GD26): the sidebar slims and its buttons fold to icons as they stop fitting.
    var isCompact = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typography
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s10) {
            HStack {
                Text(skin.labelCased(GrimoireApp.displayName))
                    .font(skin.font(AinkradFontToken(sizeKey: "t14", weight: "bold")))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                Spacer(minLength: 0)
                // First run shows the title alone (12 A); the gear comes back while Settings is open, the way out.
                if !isFirstRun || model.isShowingSettings {
                    AinkradIconButton(systemName: "gearshape", size: skin.size.s26, tooltip: "Settings") {
                        model.isShowingSettings.toggle()
                    }
                }
            }
            .frame(minHeight: skin.size.s26)
            .padding(.leading, skin.size.s2)

            if !isFirstRun {
                actions
            }
            // With no threads yet the sidebar is the title and its two actions (mockup 9).
            if !isFirstRun, !model.projects.isEmpty {
                AinkradSearchField(text: $model.searchText, placeholder: "Search threads", focus: $isSearchFocused)
                    .keyHint("⌘K")
                    // ⌘K (and ⌘F). A turn later: focus set in the same update as the key event doesn't stick.
                    .onChange(of: model.searchFocusRequest) { DispatchQueue.main.async { isSearchFocused = true } }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: skin.size.s1) {
                        ForEach(model.visibleProjects) { project in
                            projectSection(project)
                        }
                        if Self.noMatchTitle(query: model.searchText, visible: model.visibleProjects) != nil {
                            NoMatchView(query: model.searchText) { model.searchText = "" }
                        }
                        if model.hiddenProjectCount > 0 {
                            ShowAllRow(count: model.projects.count) { model.showsAllProjects = true }
                        }
                    }
                }
                .scrollIndicators(.never)
                .padding(.horizontal, -skin.size.s4)

                footer
            }
        }
        .padding(.top, skin.size.s12)
        .padding(.horizontal, skin.size.s12)
        .padding(.bottom, skin.size.s10)
        // Gives way before the thread does in a narrow window (GD16).
        .frame(
            minWidth: isCompact ? skin.size.s200 : skin.size.s260, idealWidth: isCompact ? skin.size.s200 : skin.size.s280,
            maxWidth: isCompact ? skin.size.s200 : skin.size.s280)
        .frame(maxHeight: .infinity, alignment: .top)
        // Fill, not a rule.
        .background(theme.surface.opacity(skin.opacity.o35))
    }

    /// No coding agent found (12 A): nothing to list or start yet.
    private var isFirstRun: Bool {
        if case .missing = model.agentStatus { true } else { false }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            // Two equal halves (mockup `.side-actions .btn { flex: 1 }`).
            HStack(spacing: skin.size.s8) {
                newThreadButton.frame(maxWidth: .infinity)
                AinkradButton(title: "Open folder…", style: .secondary) { chooseFolder() }
                    .secondaryAccent()
                    .fixedSize()
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: AinkradSpacing.sm) {
                newThreadButton
                openFolderIcon
            }
            HStack(spacing: AinkradSpacing.sm) {
                AinkradIconButton(systemName: "plus", size: skin.size.s30, tooltip: "New thread (⌘N)") { newThread() }
                openFolderIcon
            }
        }
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
                    limit: model.liveThreads[thread.id]?.hitLimit == true ? model.limit(for: thread.harness) : nil,
                    isSelected: thread.id == model.selectedThreadID
                ) {
                    model.selectedThreadID = thread.id
                }
            }
        }
    }

    private var newThreadButton: some View {
        AinkradButton(title: "New thread", style: .primary, icon: "plus") { newThread() }
            .fixedSize()
    }

    /// With no project yet (mockup 9), New thread asks for its folder first.
    private func newThread() {
        if model.projects.isEmpty {
            guard let url = FolderPicker.choose() else { return }
            model.openFolder(url)
        }
        model.isComposingNewThread = true
    }

    private var openFolderIcon: some View {
        AinkradIconButton(systemName: "folder.badge.plus", size: skin.size.s30, tooltip: "Open folder…") { chooseFolder() }
    }

    /// "● 1 working · ● 1 needs you" with their dots, and the agents found at the trailing edge (mockup 1).
    private var footer: some View {
        HStack(spacing: skin.size.s6) {
            let statuses = model.liveThreads.values.map(\.status)
            let working = statuses.filter { $0 == .working }.count
            let waiting = statuses.filter { $0 == .needsYou }.count
            if working > 0 {
                StatusDot(status: .working)
                Text("\(working) working")
            }
            if working > 0, waiting > 0 { Text("·") }
            if waiting > 0 {
                StatusDot(status: .needsYou)
                Text("\(waiting) needs you")
            }
            Spacer(minLength: skin.size.s6)
            if model.isLoading {
                AinkradSpinner()
            }
            if model.cli == .checking {
                Text("Looking for agents…")
            } else {
                // Names only, so three agents fit; versions are in the tooltip and Settings.
                let found = Harness.allCases.compactMap { harness -> (String, String)? in
                    guard case .found(_, let version) = model.status(of: harness) else { return nil }
                    return (harness.command, version)
                }
                Text(found.isEmpty ? "No coding agent found" : found.map(\.0).joined(separator: " · "))
                    .font(AinkradFontResolver.font(size: 11, mono: true, typography: typography))
                    .truncationMode(.head)
                    .help(found.map { "\($0.0) \($0.1)" }.joined(separator: "\n"))
            }
        }
        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
        .foregroundStyle(skin.color(skin.text.muted))
        .lineLimit(1)
        .padding(.horizontal, skin.size.s2)
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
        .padding(.top, skin.size.s6)
    }

    private var label: some View {
        HStack(spacing: skin.size.s8) {
            // The mockup's small faint ▾ / ▸.
            Text(isExpanded ? "▾" : "▸")
                .font(skin.font(AinkradFontToken(sizeKey: "t10")))
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
    /// Its agent's usage limit stopped it: amber until the reset.
    var isLimited = false
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
        if isLimited { return statusColors.warning }
        return switch status {
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
    /// Set when this thread's last turn hit its agent's usage limit, until the reset (E6 D).
    let limit: UsageLimit?
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typography

    var body: some View {
        Button(action: select) {  // design-lint: allow raw-control keyboard-reachable row (kit has no row button)
            label
        }
        .buttonStyle(.plain)
        .help(thread.gitBranch.map { "\(thread.title) — \($0)" } ?? thread.title)
    }

    /// Mockup `.thread`: dot column, title, time; under the title the agent badge, the worktree and a status.
    private var label: some View {
        VStack(alignment: .leading, spacing: skin.size.s2) {
            HStack(spacing: skin.size.s8) {
                StatusDot(status: status, isLimited: limit != nil)
                    .frame(width: skin.size.s10)
                Text(thread.title)
                    .font(skin.font(AinkradFontToken(sizeKey: "t13")))
                    .foregroundStyle(theme.foreground.opacity(isSelected ? skin.opacity.o95 : skin.opacity.o85))
                    .lineLimit(1)
                Spacer(minLength: skin.size.s4)
                Text(RelativeTime.short(thread.lastActivity))
                    .font(AinkradFontResolver.font(size: 11, mono: true, typography: typography))
                    .foregroundStyle(skin.color(skin.text.faint))
            }
            HStack(spacing: skin.size.s6) {
                HarnessBadge(harness: thread.harness)
                if let worktree = thread.worktree {
                    AinkradBadge(text: "⑂ \(worktree)", tint: theme.accentSecondary)
                }
                if let limit {
                    Text(limit.resetsAt.map { "limit · \(UsageLimit.clock($0))" } ?? "limit")
                        .foregroundStyle(statusColors.warning)
                } else if status == .needsYou {
                    Text("needs you").foregroundStyle(statusColors.warning)
                } else if case .failed = status {
                    Text("failed").foregroundStyle(statusColors.danger)
                }
            }
            .font(skin.font(AinkradFontToken(sizeKey: "t11")))
            .foregroundStyle(skin.color(skin.text.faint))
            .padding(.leading, skin.size.s18)
        }
        .padding(.vertical, skin.size.s7)
        .padding(.leading, skin.size.s10)
        .padding(.trailing, skin.size.s8)
        // GP1/GP65: a chamfered 22 % card under Neon, a 12 pt card with a hairline under Glass.
        .ainkradRowBackground(isSelected: isSelected, isHovered: isHovered, style: .card)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // Indented under its project (`.thread { margin-left: 12px }`).
        .padding(.leading, skin.size.s12)
    }
}

/// "No threads match" (mockup 12 D): the query in quotes, what search covers, and a quiet way out. Search already
/// covers every project, so there is no "Search all projects".
private struct NoMatchView: View {
    let query: String
    let clear: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(spacing: skin.size.s8) {
            Text("No threads match")
                .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "bold")))
                .foregroundStyle(theme.foreground)
            Text("“\(query.trimmingCharacters(in: .whitespaces))” isn’t in any thread title or project name.")
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .foregroundStyle(skin.color(skin.text.muted))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            AinkradButton(title: "Clear search", style: .ghost, action: clear).borderless().secondaryAccent().fixedSize()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, skin.size.s18)
        .padding(.vertical, skin.size.s30)
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

/// Which agent a thread runs on, in the kit's agent colour (mockup `.badge.claude` …).
struct HarnessBadge: View {
    let harness: Harness
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        AinkradBadge(text: harness.displayName, tint: skin.agentColor(harness.agent))
    }
}

extension Harness {
    var agent: AinkradAgent { AinkradAgent(identifier: rawValue) }
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
