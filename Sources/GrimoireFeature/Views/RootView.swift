import AinkradAppKit
import AppKit
import SwiftUI

/// The window: sidebar and the selected thread side by side, one surface.
struct RootView: View {
    let model: GrimoireModel
    let theme: HostTheme
    /// What another app sent with opening this window (`host.apps.takePendingLaunch()`), read once.
    var takeLaunch: () -> String? = { nil }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            MainPane(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tokens.background)
        .foregroundStyle(theme.tokens.foreground)
        // Off while the New Thread sheet is up, so ⌘F/⌘L and thread keys don't act behind it.
        .overlay { if !model.isComposingNewThread { ShortcutLayer(model: model) } }
        .ainkradModal(
            isPresented: Binding(get: { model.isComposingNewThread }, set: { model.isComposingNewThread = $0 }),
            contentWidth: NewThreadSheet.width
        ) {
            NewThreadSheet(model: model) { model.isComposingNewThread = false }
                // An asked-for project and request are for this sheet only.
                .onDisappear { model.newThreadPreset = nil }
        }
        .ainkradToastHost()
        .ainkradHostTheme(theme)
        .task {
            model.start()
            model.handleLaunch(takeLaunch())
        }
    }
}

/// Grimoire's keyboard shortcuts (GD17). Zero-sized key-equivalent claims, not controls — a plugin has no menu
/// bar. Only available commands are mounted: a mounted chord is claimed even when it would do nothing, and
/// would take the key from the composer (where ⌘⌫ deletes to the start of the line).
private struct ShortcutLayer: View {
    let model: GrimoireModel

    var body: some View {
        ZStack {
            claim("New thread", "n") { if !model.projects.isEmpty { model.isComposingNewThread = true } }
            claim("Search threads", "f") { model.searchFocusRequest += 1 }
            claim("Focus composer", "l") { model.composerFocusRequest += 1 }
            claim("Next thread", "]", [.command, .shift]) { model.selectAdjacentThread(1) }
            claim("Previous thread", "[", [.command, .shift]) { model.selectAdjacentThread(-1) }
            if model.selectedThread != nil {
                claim("Review changes", "r", [.command, .shift]) { model.isReviewOpen.toggle() }
            }
            // Only for the thread on screen: never answer an approval you can't see.
            if let live = model.current, model.selectedThread != nil, !model.isShowingSettings {
                if live.pendingApproval != nil {
                    claim("Allow once", .return) { live.answer(.allow) }
                    if live.canAllowAlways {
                        claim("Always allow", .return, [.command, .option]) { live.answer(.allowAlways) }
                    }
                    claim("Deny", .delete) { live.answer(.deny(reason: "Denied in Grimoire.")) }
                }
                if live.canInterrupt {
                    claim("Stop", ".") { live.interrupt() }
                }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func claim(
        _ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers = .command, action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)  // design-lint: allow raw-control key-equivalent claim
            .keyboardShortcut(key, modifiers: modifiers)
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
                NoAgentView(model: model, searched: searched)
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
            // Narrow, the model goes first, then the branch, then the project — never "… · f…" (GD10).
            ViewThatFits(in: .horizontal) {
                meta(project: true, branch: true, model: true)
                meta(project: true, branch: false, model: false)
                meta(project: false, branch: false, model: false)
            }
            .font(skin.font(AinkradFontToken(sizeKey: "t11")))
            .foregroundStyle(skin.color(skin.text.muted))
            .lineLimit(1)
        }
    }

    private func meta(project: Bool, branch: Bool, model showsModel: Bool) -> some View {
        HStack(spacing: skin.size.s6) {
            if project {
                Text((thread.projectPath as NSString).lastPathComponent)
            }
            if branch, let branch = thread.gitBranch {
                Text("·")
                Text(branch).font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
            }
            HarnessBadge(harness: thread.harness).fixedSize()
            if showsModel, let model = (model ?? thread.model).map(ModelName.display) {
                Text(model).font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
            }
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
