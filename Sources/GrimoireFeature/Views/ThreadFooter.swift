import AinkradAppKit
import SwiftUI

/// Under the conversation: a pending approval docked above the composer, a
/// status line while the agent works, and the composer.
struct ThreadFooter: View {
    let live: LiveThread
    let model: GrimoireModel
    let workingDirectory: String
    var harness: Harness = .claude
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    private var draft: String { live.draft }

    var body: some View {
        let limit = model.limit(for: harness)
        VStack(alignment: .leading, spacing: 0) {
            if let request = live.pendingApproval {
                ApprovalBar(request: request, workingDirectory: workingDirectory, live: live)
            } else if limit != nil {
                // Re-read each minute, so the bar goes once the window resets.
                TimelineView(.everyMinute) { _ in
                    if let limit = model.limit(for: harness) {
                        limitBar(limit)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            StatusLine(live: live, isLimited: limit != nil)
            AinkradComposer(
                text: Bindable(live).draft,
                placeholder: "Message \(harness.displayName)… (/ for commands, @ for files)", isEditable: true,
                canSend: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, autoFocus: true,
                suggestions: suggestions, onPick: { _, _ in }, onDrop: nil, onSend: send
            ) {
                EmptyView()
            } leading: {
                // The captions go first when the thread is squeezed (GD10).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: skin.spacing.sm) {
                        modeMenu(captions: true)
                        modelMenu(captions: true)
                    }
                    HStack(spacing: skin.spacing.sm) {
                        modeMenu(captions: false)
                        modelMenu(captions: false)
                    }
                }
            } trailing: {
                if let at = live.sendAt {
                    queued(at)
                }
                if live.canInterrupt {
                    AinkradButton(title: "Stop", style: .danger, icon: "stop.fill") { live.interrupt() }
                        .fixedSize()
                        .help("Stop (⌘.)")
                }
            }
            // ⌘L: a fresh editor autofocuses — the kit's composer has no other focus hook. The draft is kept.
            .id(model.composerFocusRequest)
            .padding(.horizontal, skin.size.s14)
            .padding(.bottom, skin.size.s14)
        }
        // Start the agent as soon as there is something to say, so `/` lists
        // the CLI's own commands by the time you look.
        .onChange(of: live.draft) { _, text in if !text.isEmpty { live.ensureStarted() } }
        .animation(reduceMotion ? nil : skin.animation(skin.motion.present), value: limit)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        live.draft = ""
        live.send(text)
    }

    private func limitBar(_ limit: UsageLimit) -> some View {
        let alternative = model.alternative(to: harness)
        let canQueue =
            limit.resetsAt != nil && live.sendAt == nil && !draft.trimmingCharacters(in: .whitespaces).isEmpty
        return LimitBar(
            limit: limit, now: model.now,
            sendAtReset: canQueue ? { limit.resetsAt.map(live.sendAtReset) } : nil,
            alternative: alternative,
            carryOver: {
                guard let alternative, let thread = model.selectedThread else { return }
                model.carryOver(thread, to: alternative)
            })
    }

    /// "queued · sends at 15:00", with a way to take it back.
    private func queued(_ date: Date) -> some View {
        HStack(spacing: skin.size.s4) {
            Text("queued · sends at \(UsageLimit.clock(date))")
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .foregroundStyle(skin.color(skin.text.faint))
                .lineLimit(1)
            AinkradIconButton(systemName: "xmark", size: skin.size.s22, tooltip: "Don't send at reset") {
                live.cancelSendAtReset()
            }
        }
        .fixedSize()
    }

    private func suggestions(_ trigger: AinkradComposerTrigger) -> [AinkradComposerSuggestion] {
        switch trigger {
        case .command(let query):
            return live.commands
                .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                .prefix(40)
                .map {
                    AinkradComposerSuggestion(
                        id: $0.name, icon: "chevron.right.circle", title: "/\($0.name)", subtitle: $0.description,
                        insertText: "/\($0.name)")
                }
        case .mention(let query):
            return ProjectFiles.search(model.files(in: workingDirectory), query: query).map {
                AinkradComposerSuggestion(
                    id: $0, icon: "doc.text", title: ($0 as NSString).lastPathComponent, subtitle: $0,
                    insertText: "@\($0)")
            }
        @unknown default:
            return []
        }
    }

    private func modeMenu(captions: Bool) -> some View {
        AinkradMenuButton(
            items: PermissionMode.allCases.map { mode in
                AinkradMenuItem(title: mode.title, systemName: mode == live.mode ? "checkmark" : nil) {
                    live.setMode(mode)
                }
            }
        ) {
            PullDownLabel { MenuValue(caption: captions ? "Mode" : nil, value: live.mode.title) }
        }
        .fixedSize()
        .help("Permission mode")
    }

    @ViewBuilder
    private func modelMenu(captions: Bool) -> some View {
        if harness == .claude {
            claudeModelMenu(captions: captions)
        } else {
            // The models the agent listed; it applies the pick from the next turn.
            AinkradMenuButton(
                items: (model.models[harness] ?? []).map { choice in
                    AinkradMenuItem(title: choice.name, systemName: choice.id == live.model ? "checkmark" : nil) {
                        live.setModel(choice.id)
                    }
                }
            ) {
                PullDownLabel {
                    MenuValue(caption: captions ? "Model" : nil, value: model.modelName(live.model, for: harness))
                }
            }
            .fixedSize()
            .help("Model")
        }
    }

    private func claudeModelMenu(captions: Bool) -> some View {
        AinkradMenuButton(
            items: ["opus", "sonnet", "haiku"].map { alias in
                // The CLI reports a full id (`claude-opus-5-5`); a pick here is the alias itself.
                AinkradMenuItem(
                    title: alias.capitalized, systemName: live.model?.contains(alias) == true ? "checkmark" : nil
                ) { live.setModel(alias) }
            }
        ) {
            PullDownLabel {
                MenuValue(caption: captions ? "Model" : nil, value: live.model.map(ModelName.display) ?? "Default")
            }
        }
        .fixedSize()
        .help("Model")
    }
}

extension PermissionMode {
    var title: String {
        switch self {
        case .ask: "Ask"
        case .acceptEdits: "Accept edits"
        case .plan: "Plan"
        case .bypassPermissions: "Bypass"
        }
    }
}

/// "MODE Ask": a faint caption and the value, inside a pull-down label.
private struct MenuValue: View {
    let caption: String?
    let value: String
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        HStack(spacing: skin.size.s6) {
            if let caption {
                Text(skin.labelCased(caption))
                    .font(skin.font(AinkradFontToken(sizeKey: "t9", weight: "semibold")))
                    .foregroundStyle(skin.color(skin.text.faint))
            }
            Text(value)
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
        }
    }
}

/// The approval the agent is waiting on, docked above the composer.
private struct ApprovalBar: View {
    let request: ApprovalRequest
    let workingDirectory: String
    let live: LiveThread

    var body: some View {
        let argument = ToolSummary.argument(
            name: request.toolName, input: request.input, workingDirectory: workingDirectory)
        var actions: [AinkradDecisionBar.Action] = [
            .init(title: "Deny", style: .ghost) { live.answer(.deny(reason: "Denied in Grimoire.")) }
        ]
        if live.canAllowAlways {
            actions.append(.init(title: "Always allow", style: .secondary) { live.answer(.allowAlways) })
        }
        actions.append(.init(title: "Allow once", style: .primary) { live.answer(.allow) })
        return AinkradDecisionBar(
            icon: request.toolName == "Bash" ? "terminal" : "pencil", iconTint: .primary,
            caption: "Approval required", title: "\(request.toolName) \(argument)", actions: actions)
    }
}

/// What the agent is doing right now, and for how long.
private struct StatusLine: View {
    let live: LiveThread
    /// The limit bar says it; the line stays quiet.
    let isLimited: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    var body: some View {
        if live.failure != nil || (isLimited && live.status != .working) {
            // The failure card or the limit bar says it.
        } else if live.startingSince != nil {
            HStack(spacing: skin.size.s8) {
                AinkradSpinner(size: skin.size.s10)
                Text("Starting engine…")
                Text("you can type; it sends when ready").foregroundStyle(skin.color(skin.text.faint))
            }
            .lineLimit(1)
            .font(skin.font(AinkradFontToken(sizeKey: "t12")))
            .foregroundStyle(skin.color(skin.text.muted))
            .padding(.horizontal, skin.size.s20)
            .padding(.vertical, skin.size.s6)
        } else {
            statusBody
        }
    }

    @ViewBuilder
    private var statusBody: some View {
        switch live.status {
        case .working:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                line(dot: theme.accentSecondary, text: "Working…", detail: elapsed(at: context.date))
            }
        case .needsYou:
            line(dot: statusColors.warning, text: "Waiting for your approval", detail: nil)
        case .failed(let message):
            // An error can carry what to do next on a second line (E0 GD7): let it wrap.
            line(dot: statusColors.danger, text: message, detail: nil, lines: 3)
        case .idle:
            if live.costUSD > 0 {
                line(
                    dot: statusColors.success, text: "Done", detail: String(format: "$%.2f this session", live.costUSD))
            }
        }
    }

    private func elapsed(at now: Date) -> String? {
        guard let start = live.turnStartedAt else { return nil }
        let seconds = Int(now.timeIntervalSince(start))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private func line(dot: Color, text: String, detail: String?, lines: Int = 1) -> some View {
        HStack(spacing: skin.size.s8) {
            Circle().fill(dot).frame(width: skin.size.s7, height: skin.size.s7)
            Text(text).lineLimit(lines)
            if let detail {
                Text(detail).font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                    .foregroundStyle(skin.color(skin.text.faint))
            }
        }
        .font(skin.font(AinkradFontToken(sizeKey: "t12")))
        .foregroundStyle(skin.color(skin.text.muted))
        .padding(.horizontal, skin.size.s20)
        .padding(.vertical, skin.size.s6)
    }
}
