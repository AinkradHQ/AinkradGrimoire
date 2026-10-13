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
    private var isBusy: Bool { live.canInterrupt && live.pendingApproval == nil }

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
            StatusLine(live: live, isLimited: limit != nil, harness: harness)
            AinkradComposer(
                text: Bindable(live).draft,
                placeholder: "Message \(harness.displayName)… (/ for commands, @ for files)", isEditable: true,
                canSend: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, autoFocus: true,
                suggestions: suggestions, onPick: { _, _ in },
                onDrop: harness.acceptsImages ? { Attach.drop($0, into: live) } : nil, onSend: send
            ) {
                AttachmentChips(live: live)
            } leading: {
                // The captions go first when the thread is squeezed (GD10).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: skin.spacing.sm) {
                        modeMenu(captions: true)
                        modelMenu(captions: true)
                        EffortMenu(live: live, harness: harness, captions: true)
                    }
                    HStack(spacing: skin.spacing.sm) {
                        modeMenu(captions: false)
                        modelMenu(captions: false)
                        EffortMenu(live: live, harness: harness, captions: false)
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
                if harness.acceptsImages {
                    AinkradIconButton(
                        systemName: "paperclip", size: AinkradComposer<EmptyView, EmptyView, EmptyView>.controlHeight,
                        tooltip: "Attach images (or drop or paste them)"
                    ) { Attach.choose(into: live) }
                }
            }
            .paletteSuggestionRows()
            // Busy (mockup 1): the red "■ Stop" on its faint red fill, and Send's ↑ becomes a lit ↵, which queues
            // the next message. The approval bar is the one thing to answer while it waits (mockup 4); ⌘. still stops.
            .stopButton("■ Stop", action: isBusy ? { live.interrupt() } : nil)
            .tintedStopButton()
            .sendGlyph(isBusy ? "↵" : "↑")
            .sendStaysLit(when: isBusy)
            // Waiting on the limit's reset, only the field steps back; the strip and Send stay lit (mockup 12 D).
            .textFieldDimmed(limit != nil)
            .background {
                if harness.acceptsImages { PasteImageMonitor { Attach.paste($0, into: live) } }
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
        let attachments = live.attachments
        live.attachments = []
        live.send(text, images: attachments.map(\.image), imageNames: attachments.map(\.name))
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
            // Mockup 3: "Session" commands (›) then "Skills" (✦), when the CLI says which are skills.
            let matches = live.commands.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            let skills = live.skills
            let grouped = matches.filter { !skills.contains($0.name) } + matches.filter { skills.contains($0.name) }
            return grouped.prefix(40).map {
                let isSkill = skills.contains($0.name)
                return AinkradComposerSuggestion(
                    id: $0.name, icon: isSkill ? "sparkle" : "chevron.forward", title: "/\($0.name)",
                    subtitle: $0.description, section: skills.isEmpty ? nil : isSkill ? "Skills" : "Session",
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
            PullDownLabel(showsChevron: false) { MenuValue(caption: captions ? "Mode" : nil, value: live.mode.title) }
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
                MenuValue(caption: captions ? "Model" : nil, value: live.model.map(ModelName.title) ?? "Default")
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
struct MenuValue: View {
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

/// The approval the agent is waiting on, docked above the composer. "Deny…" asks for an optional reason the agent
/// sees (mockup 4); ⌘⌫ still denies at once.
extension AinkradComposer {
    /// `sendStaysLit()` only while `lit` — idle, an empty draft's ↑ still reads as disabled.
    fileprivate func sendStaysLit(when lit: Bool) -> Self { lit ? sendStaysLit() : self }
}

struct ApprovalBar: View {
    let request: ApprovalRequest
    let workingDirectory: String
    let live: LiveThread
    /// Internal so a snapshot can show the reason field open.
    @State var isDenying = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        let argument = ToolSummary.argument(
            name: request.toolName, input: request.input, workingDirectory: workingDirectory)
        let title = request.toolName == "Bash" ? "Run \(argument)" : "\(request.toolName) \(argument)"
        VStack(alignment: .leading, spacing: 0) {
            AinkradDecisionBar(
                icon: "bolt.horizontal", iconTint: .secondary, caption: isDenying ? "Deny" : "Approval required",
                title: title, actions: isDenying ? denyActions : actions
            )
            .labelCasedCaption()
            .iconGlyph("⌁")
            if isDenying {
                AinkradTextField(
                    text: $reason, placeholder: "Reason for the agent (optional) — ↵ denies", focus: $reasonFocused
                )
                .onSubmit(deny)
                // A turn later: focus set in the same update as the click doesn't stick.
                .onAppear { DispatchQueue.main.async { reasonFocused = true } }
                .padding(.horizontal, skin.size.s14)
                .padding(.bottom, skin.spacing.xs)
                .transition(.opacity)
            }
        }
        .id(request.id)
    }

    /// Mockup 4: a bare cyan Deny…, Always allow named by the CLI's own rule, Allow once with its key.
    private var actions: [AinkradDecisionBar.Action] {
        var actions: [AinkradDecisionBar.Action] = [
            AinkradDecisionBar.Action(title: "Deny…", style: .ghost) { isDenying = true }.borderless().secondaryAccent()
        ]
        if live.canAllowAlways {
            // A rule reads as a faint mono suffix ("Always allow `git push *`"); a mode as words.
            let rule = ApprovalBarRule.rule(request.suggestions)
            let isMode = rule == ApprovalBarRule.acceptEdits
            let always = AinkradDecisionBar.Action(
                title: isMode ? "Always allow \(ApprovalBarRule.acceptEdits)" : "Always allow", style: .secondary
            ) { live.answer(.allowAlways) }.secondaryAccent()
            actions.append(isMode ? always : rule.map(always.detail) ?? always)
        }
        actions.append(.init(title: "Allow once ↵", style: .primary) { live.answer(.allow) })
        return actions
    }

    private var denyActions: [AinkradDecisionBar.Action] {
        [
            AinkradDecisionBar.Action(title: "Cancel", style: .ghost) {
                isDenying = false
                reason = ""
            }.borderless().secondaryAccent(),
            AinkradDecisionBar.Action(title: "Deny", style: .danger, perform: deny),
        ]
    }

    private func deny() { live.answer(.deny(reason: ApprovalBarRule.denial(reason))) }
}

enum ApprovalBarRule {
    static let acceptEdits = "accept edits for this session"

    /// What the agent is told on a denial: your reason, or a plain "denied".
    static func denial(_ reason: String) -> String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? "Denied in Grimoire." : "Denied in Grimoire: \(reason)"
    }

    /// What "Always allow" adopts, in the CLI's words: Claude's rule (`git push:*` → `git push *`), or its mode
    /// ("accept edits for this session"). Nil when the suggestion names neither (Codex, OpenCode).
    static func rule(_ suggestions: [JSONValue]) -> String? {
        for suggestion in suggestions {
            if let content = suggestion["rules"]?.arrayValue?.first?["ruleContent"]?.stringValue {
                return content.hasSuffix(":*") ? content.dropLast(2) + " *" : content
            }
            if suggestion["type"]?.stringValue == "setMode", suggestion["mode"]?.stringValue == "acceptEdits" {
                return acceptEdits
            }
        }
        return nil
    }
}

/// What the agent is doing right now, for how long and with how many tokens; then how the turn went (mockups 1, 2).
private struct StatusLine: View {
    let live: LiveThread
    /// The limit bar says it; the line stays quiet.
    let isLimited: Bool
    let harness: Harness
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography

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
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                line(
                    dot: theme.accentSecondary, text: live.activity.map { "\($0)…" } ?? "Working…",
                    detail: Self.detail(live.turnElapsed, tokens: live.turnOutputTokens))
            }
        case .needsYou:
            // The approval bar says it (mockup 4).
            EmptyView()
        case .failed(let message):
            // An error can carry what to do next on a second line (E0 GD7): let it wrap.
            line(dot: statusColors.danger, text: message, detail: nil, lines: 3)
        case .idle:
            if let turn = live.lastTurn {
                // Cost only where the agent reports it (Claude); tokens likewise.
                line(
                    dot: statusColors.success, text: "Done in \(StatusTime.short(turn.duration))",
                    detail: Self.detail(nil, tokens: turn.tokens, cost: live.costUSD).map { "· \($0)" })
            }
        }
    }

    /// "1m 12s · 18.4k tokens · $0.42", leaving out what is not known.
    static func detail(_ elapsed: TimeInterval?, tokens: Int?, cost: Double = 0) -> String? {
        let parts = [
            elapsed.map(StatusTime.short), tokens.map { "\(TokenCount.short($0)) tokens" },
            cost > 0 ? String(format: "$%.2f", cost) : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }


    private func line(dot: Color, text: String, detail: String?, lines: Int = 1) -> some View {
        HStack(spacing: skin.size.s8) {
            Circle().fill(dot).frame(width: skin.size.s7, height: skin.size.s7)
            Text(text).lineLimit(lines)
            if let detail {
                Text(detail).font(AinkradFontResolver.font(size: 11, mono: true, typography: typography))
                    .foregroundStyle(skin.color(skin.text.faint))
                    .lineLimit(1)
            }
        }
        .font(skin.font(AinkradFontToken(sizeKey: "t12")))
        .foregroundStyle(skin.color(skin.text.muted))
        .padding(.horizontal, skin.size.s20)
        .padding(.vertical, skin.size.s6)
    }
}

/// "48s", "2m 40s".
enum StatusTime {
    static func short(_ seconds: TimeInterval) -> String {
        let seconds = Int(seconds)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// "31.2k" for 31 200; small counts as they are.
enum TokenCount {
    static func short(_ count: Int) -> String {
        count < 1_000 ? "\(count)" : String(format: "%.1fk", Double(count) / 1_000)
    }
}
