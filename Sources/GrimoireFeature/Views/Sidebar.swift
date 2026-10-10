import AinkradAppKit
import AppKit
import SwiftUI

/// Projects → threads. Surfaces are told apart by fill, never by a line.
struct Sidebar: View {
    @Bindable var model: GrimoireModel
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            Text(skin.labelCased(GrimoireApp.displayName))
                .font(skin.font(AinkradFontToken(sizeKey: "t14", weight: "bold")))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                .padding(.horizontal, skin.size.s6)

            HStack(spacing: AinkradSpacing.sm) {
                AinkradButton(title: "New thread", style: .primary, icon: "plus") {}
                    .disabled(true)
                    .help("Coming soon")
                    .frame(maxWidth: .infinity, alignment: .leading)
                AinkradIconButton(systemName: "folder.badge.plus", tooltip: "Open folder…") { chooseFolder() }
            }

            AinkradSearchField(text: $model.searchText, placeholder: "Search threads")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: skin.size.s1) {
                    ForEach(model.visibleProjects) { project in
                        projectSection(project)
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
        .frame(width: skin.size.s280)
        .frame(maxHeight: .infinity, alignment: .top)
        // Fill, not a rule.
        .background(theme.surface.opacity(skin.opacity.o35))
    }

    @ViewBuilder
    private func projectSection(_ project: ClaudeProject) -> some View {
        let expanded =
            !model.searchText.isEmpty || model.settings.isExpanded(project.path, mostRecent: model.mostRecentProject)
        ProjectRow(project: project, isExpanded: expanded) {
            model.settings.toggle(project.path, mostRecent: model.mostRecentProject)
        }
        if expanded {
            ForEach(project.sessions) { thread in
                ThreadRow(thread: thread, isSelected: thread.id == model.selectedThreadID) {
                    model.selectedThreadID = thread.id
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: skin.size.s6) {
            switch model.cli {
            case .found(_, let version):
                Text("claude \(version)")
            case .missing:
                Text("Claude Code not found")
            case .checking:
                Text("Looking for Claude Code…")
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

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openFolder(url)
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
        .onTapGesture(perform: toggle)
        .help(project.path)
        .padding(.top, skin.size.s4)
    }
}

private struct ThreadRow: View {
    let thread: ClaudeSessionSummary
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s3) {
            HStack(spacing: skin.size.s8) {
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
                AinkradBadge(text: "Claude", tint: isSelected ? theme.foreground : HarnessBadge.claudeTint)
                if let worktree = thread.worktree {
                    AinkradBadge(text: "⑂ \(worktree)", tint: isSelected ? theme.foreground : theme.accentSecondary)
                }
            }
        }
        .padding(.vertical, skin.size.s6)
        .padding(.leading, skin.size.s20)
        .padding(.trailing, skin.size.s8)
        .ainkradRowBackground(isSelected: isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: select)
        .help(thread.gitBranch.map { "\(thread.title) — \($0)" } ?? thread.title)
    }
}

private struct ShowAllRow: View {
    let count: Int
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        Text("Show all \(count) projects…")
            .font(skin.font(AinkradFontToken(sizeKey: "t12")))
            .foregroundStyle(skin.color(skin.text.muted))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, skin.size.s6)
            .padding(.horizontal, skin.size.s8)
            .ainkradRowBackground(isSelected: false, isHovered: isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture(perform: action)
            .padding(.top, skin.size.s4)
    }
}

/// Which agent a thread runs on. Only Claude Code until the other adapters land.
enum HarnessBadge {
    // design-lint: allow raw-color kit-gap colors.providerBrand (Claude's brand clay, as Sage's model picker)
    static let claudeTint = Color(.sRGB, red: 0xCC / 255, green: 0x78 / 255, blue: 0x5C / 255)

    static var claude: some View { AinkradBadge(text: "Claude", tint: claudeTint) }
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
