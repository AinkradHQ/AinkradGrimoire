import AinkradAppKit
import AppKit
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
        .ainkradModal(
            isPresented: Binding(get: { model.isComposingNewThread }, set: { model.isComposingNewThread = $0 }),
            contentWidth: NewThreadSheet.width
        ) {
            NewThreadSheet(model: model) { model.isComposingNewThread = false }
        }
        .ainkradToastHost()
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
            if model.isShowingSettings {
                SettingsView(model: model)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch model.agentStatus {
            case .checking:
                AinkradLoadingState(label: "Looking for coding agents…")
            case .missing(let searched):
                EmptyWithActions(
                    icon: "terminal",
                    title: "No coding agent found",
                    message: """
                        Grimoire drives the CLIs you already use. It looked on your login shell's PATH:
                        \(searched)
                        Install Claude Code with: npm install -g @anthropic-ai/claude-code
                        or Codex with: npm install -g @openai/codex
                        """
                ) {
                    AinkradButton(title: "Choose the CLI…", style: .secondary) { model.isShowingSettings = true }
                        .fixedSize()
                    AinkradButton(title: "Check again", style: .primary) { Task { await model.reload() } }
                        .fixedSize()
                }
            case .found:
                if model.projects.isEmpty {
                    EmptyWithActions(
                        icon: "books.vertical",
                        title: "No threads yet",
                        message:
                            "Open a project folder and start a thread — or keep using the terminal; sessions you run there show up here too."
                    ) {
                        AinkradButton(title: "Open folder…", style: .secondary) {
                            if let url = FolderPicker.choose() { model.openFolder(url) }
                        }
                        .fixedSize()
                    }
                } else if model.selectedThread == nil, model.selectedThreadID == nil {
                    AinkradEmptyState(
                        icon: "text.bubble", title: "Pick a thread",
                        message: "Choose a thread in the sidebar, or start a new one.",
                        actionTitle: "New thread"
                    ) { model.isComposingNewThread = true }
                } else if let thread = model.selectedThread {
                    ThreadView(model: model, thread: thread).id(thread.id)
                } else {
                    AinkradLoadingState(label: "Opening the thread…")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An empty state with more than one way out.
struct EmptyWithActions<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        VStack(spacing: skin.size.s14) {
            AinkradEmptyState(icon: icon, title: title, message: message).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: skin.size.s8) { actions }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Asks for a project folder.
enum FolderPicker {
    @MainActor static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Title and where the thread lives: project · branch · agent · model.
struct ThreadHeader<Actions: View>: View {
    let thread: ClaudeSessionSummary
    /// The running agent's model, when it differs from the stored one.
    var model: String?
    @ViewBuilder var actions: Actions
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: skin.size.s10) {
            details
            Spacer(minLength: skin.size.s8)
            HStack(spacing: skin.size.s6) { actions }
        }
        .padding(.horizontal, skin.size.s20)
        .padding(.top, skin.size.s14)
        .padding(.bottom, skin.size.s10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var details: some View {
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
                HarnessBadge(harness: thread.harness).fixedSize()
                if let model = (model ?? thread.model).map(ModelName.display) {
                    Text(model).font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                }
            }
            .font(skin.font(AinkradFontToken(sizeKey: "t11")))
            .foregroundStyle(skin.color(skin.text.muted))
            .lineLimit(1)
        }
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
