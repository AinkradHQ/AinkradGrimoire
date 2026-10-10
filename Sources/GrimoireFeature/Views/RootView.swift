import AinkradAppKit
import SwiftUI

/// The window: sidebar and the selected thread side by side, one surface.
struct RootView: View {
    let model: GrimoireModel
    let theme: HostTheme

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            MainPane(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tokens.background)
        .foregroundStyle(theme.tokens.foreground)
        .ainkradHostTheme(theme)
        .task { model.start() }
    }
}

/// The right side: whatever the sidebar's state calls for.
struct MainPane: View {
    let model: GrimoireModel
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        Group {
            switch model.cli {
            case .checking:
                AinkradLoadingState(label: "Looking for Claude Code…")
            case .missing(let searched):
                AinkradEmptyState(
                    icon: "terminal",
                    title: "No coding agent found",
                    message: """
                        Grimoire drives the CLIs you already use. It looked on your login shell's PATH:
                        \(searched)
                        Install Claude Code with: npm install -g @anthropic-ai/claude-code
                        """,
                    actionTitle: "Check again"
                ) { Task { await model.reload() } }
            case .found:
                if model.projects.isEmpty {
                    AinkradEmptyState(
                        icon: "books.vertical",
                        title: "No threads yet",
                        message: "Open a project folder to start. Sessions you run in the terminal show up here too.")
                } else if let thread = model.selectedThread {
                    ThreadView(model: model, thread: thread)
                } else {
                    AinkradEmptyState(
                        icon: "text.bubble", title: "Pick a thread",
                        message: "Choose a thread in the sidebar to see the conversation.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Title and where the thread lives: project · branch · agent · model.
struct ThreadHeader: View {
    let thread: ClaudeSessionSummary
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s4) {
            Text(thread.title)
                .font(skin.font(AinkradFontToken(sizeKey: "t15", weight: "semibold")))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o95))
                .lineLimit(1)
            HStack(spacing: skin.size.s6) {
                Text((thread.projectPath as NSString).lastPathComponent)
                if let branch = thread.gitBranch {
                    Text("·")
                    Text(branch).font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                }
                HarnessBadge.claude
                if let model = thread.model.map(ModelName.display) {
                    Text(model).font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                }
            }
            .font(skin.font(AinkradFontToken(sizeKey: "t11")))
            .foregroundStyle(skin.color(skin.text.muted))
            .lineLimit(1)
        }
        .padding(.horizontal, skin.size.s20)
        .padding(.top, skin.size.s14)
        .padding(.bottom, skin.size.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `claude-opus-5-5` → `opus 5.5`; anything else unchanged.
enum ModelName {
    static func display(_ id: String) -> String {
        var name = id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
        if let dash = name.firstIndex(of: "-"),
            name[name.index(after: dash)...].allSatisfy({ $0.isNumber || $0 == "-" })
        {
            name = name[..<dash] + " " + name[name.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
        }
        return name
    }
}
