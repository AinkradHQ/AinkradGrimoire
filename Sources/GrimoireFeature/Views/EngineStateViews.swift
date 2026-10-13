import AinkradAppKit
import AppKit
import SwiftUI

/// While the agent starts (E6 B): the steps as they finish — a spinner on the current one — then shimmer
/// where its reply will land. Both loops stop the moment the agent answers (the view goes away).
struct StartupView: View {
    let steps: [StartupStep]
    let since: Date
    let now: () -> Date
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                StartupStepRow(step: step, index: index, since: since, now: now)
            }
            VStack(alignment: .leading, spacing: skin.size.s8) {
                ShimmerBar(maxWidth: skin.size.s520)
                ShimmerBar(maxWidth: skin.size.s440)
                ShimmerBar(maxWidth: skin.size.s340)
            }
            .padding(.top, skin.size.s6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One startup step; steps tick in one by one with a short fade.
private struct StartupStepRow: View {
    let step: StartupStep
    let index: Int
    let since: Date
    let now: () -> Date
    @State private var isShown = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @Environment(\.ainkradMotionBudget) private var budget

    var body: some View {
        HStack(spacing: skin.size.s8) {
            Group {
                if step.done {
                    Image(systemName: "checkmark")
                        .font(skin.font(AinkradFontToken(sizeKey: "t11", weight: "bold")))
                        .foregroundStyle(statusColors.success)
                } else {
                    AinkradSpinner(size: skin.size.s12)
                }
            }
            .frame(width: skin.size.s14)
            Text(step.title)
            if let code = step.code {
                Text(code).font(AinkradFontResolver.font(size: 12, mono: true, typography: typography))
            }
            if !step.done {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(max(Int(now().timeIntervalSince(since)), 0)) s")
                        .font(AinkradFontResolver.font(size: 11, mono: true, typography: typography))
                        .foregroundStyle(skin.color(skin.text.faint))
                }
            }
        }
        .font(skin.font(AinkradFontToken(sizeKey: "t13")))
        .foregroundStyle(skin.color(skin.text.muted))
        .opacity(isShown ? 1 : 0)
        .onAppear {
            guard !reduceMotion, budget.isAnimating else {
                isShown = true
                return
            }
            withAnimation(skin.animation(skin.motion.present).delay(Double(index) * skin.motion.fast)) { isShown = true }
        }
    }
}

/// A placeholder line with a highlight sweeping across it; still under Reduce Motion or a frozen budget.
private struct ShimmerBar: View {
    let maxWidth: CGFloat
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        BudgetedTimelineView { date in
            let period = skin.motion.materialize * 3
            let phase = reduceMotion ? -1 : date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            skin.shape(cut: AinkradRadius.sm)
                .fill(theme.foreground.opacity(skin.opacity.o07))
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: phase - 0.25),
                            .init(color: theme.foreground.opacity(skin.opacity.o10), location: phase),
                            .init(color: .clear, location: phase + 0.25),
                        ], startPoint: .leading, endPoint: .trailing
                    )
                    .clipShape(skin.shape(cut: AinkradRadius.sm))
                }
        }
        .frame(maxWidth: maxWidth)
        .frame(height: skin.size.s10)
    }
}

/// The agent stopped (E6 C): a red-washed card in the transcript, not a modal.
struct FailureCard: View {
    let failure: EngineFailure
    let harness: Harness
    let retry: () -> Void
    /// Opens a terminal to log in; offered when the error is an auth one.
    let openTerminal: () -> Void
    @State private var copied = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s8) {
            HStack(spacing: skin.size.s8) {
                Image(systemName: "xmark.octagon").foregroundStyle(statusColors.danger)
                Text(failure.headline(harness))
                    .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "semibold")))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(failure.detail())
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .foregroundStyle(skin.color(skin.text.muted))
                .fixedSize(horizontal: false, vertical: true)
            if !failure.output.isEmpty { output }
            // Narrow (GD26), the buttons wrap under each other rather than widen the card past the window.
            FlowLayout(spacing: skin.size.s8) { buttons }
        }
        .padding(skin.size.s14)
        .frame(maxWidth: skin.size.s640, alignment: .leading)
        .background(skin.shape(cut: AinkradRadius.md).fill(statusColors.danger.opacity(skin.opacity.o08)))
        .overlay(skin.shape(cut: AinkradRadius.md).stroke(statusColors.danger.opacity(skin.opacity.o35), lineWidth: 1))
    }

    @ViewBuilder
    private var buttons: some View {
        AinkradButton(title: "Retry", style: .primary, icon: "arrow.clockwise", action: retry).fixedSize()
        if failure.kind == .auth {
            AinkradButton(title: "Open Terminal to log in", style: .secondary, icon: "terminal", action: openTerminal)
                .fixedSize()
                .help(EngineFailure.loginHint(harness))
        }
        AinkradButton(title: copied ? "Copied" : "Copy details", style: .ghost, icon: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(failure.details(harness), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .fixedSize()
    }

    /// The last stderr lines, scrollable, opened at the end.
    private var output: some View {
        ScrollView {
            Text(failure.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n"))
                .font(AinkradFontResolver.font(size: 11.5, mono: true, typography: typography))
                .foregroundStyle(skin.color(skin.text.muted))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(skin.size.s8)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: skin.size.s120)
        .fixedSize(horizontal: false, vertical: true)
        .background(skin.shape(cut: AinkradRadius.sm).fill(theme.background.opacity(skin.opacity.o70)))
    }
}

/// The agent's usage limit is reached (E6 D): an amber bar docked above the composer, where the
/// approval bar sits.
struct LimitBar: View {
    let limit: UsageLimit
    let now: () -> Date
    /// `nil` when the reset time isn't known or the message is already queued.
    let sendAtReset: (() -> Void)?
    let alternative: Harness?
    let carryOver: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography

    var body: some View {
        // Squeezed, the buttons go under the text rather than cut it short.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: skin.size.s10) {
                summary(wraps: false).fixedSize()
                Spacer(minLength: skin.size.s8)
                meter
                buttons
            }
            // Narrower still (GD26): the text gets the width (the full meter only repeats it) and the buttons wrap.
            VStack(alignment: .leading, spacing: skin.size.s8) {
                summary(wraps: true)
                FlowLayout(spacing: skin.size.s8) { buttons }
            }
        }
        .padding(.horizontal, skin.size.s14).padding(.vertical, skin.size.s9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.shape(cut: AinkradRadius.md).fill(statusColors.warning.opacity(skin.opacity.o10)))
        .overlay(skin.shape(cut: AinkradRadius.md).stroke(statusColors.warning.opacity(skin.opacity.o45), lineWidth: 1))
        .padding(.horizontal, skin.size.s14)
        .padding(.bottom, skin.spacing.xs)
    }

    /// Wrapping when squeezed (GD26), rather than cutting the headline short.
    private func summary(wraps: Bool) -> some View {
        HStack(spacing: skin.size.s10) {
            Image(systemName: "gauge.with.needle")
                .font(skin.font(AinkradFontToken(sizeKey: "t13", scaled: false)))
                .foregroundStyle(statusColors.warning)
            VStack(alignment: .leading, spacing: skin.size.s1) {
                Text("\(limit.harness.displayName) usage limit reached")
                    .font(AinkradFontResolver.font(size: 12, weight: .semibold, typography: typography))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                TimelineView(.everyMinute) { _ in
                    Text(detail(now: now()))
                        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                        .foregroundStyle(skin.color(skin.text.muted))
                }
            }
            .lineLimit(wraps ? nil : 1)
            .fixedSize(horizontal: false, vertical: wraps)
        }
    }

    private var meter: some View {
        AinkradStatusBar(value: limit.utilization, kind: .status(.warning), segments: 8)
            .frame(width: skin.size.s60)
    }

    @ViewBuilder
    private var buttons: some View {
        if let sendAtReset {
            AinkradButton(title: "Send at reset", style: .secondary, icon: "clock", action: sendAtReset).fixedSize()
        }
        if let alternative {
            AinkradButton(title: "New thread with \(alternative.displayName)", style: .ghost, action: carryOver)
                .fixedSize()
        }
    }

    /// "Resets at 15:00 — in 1 h 12 min · 5-hour window".
    private func detail(now: Date) -> String {
        var parts: [String] = []
        if let reset = limit.resetsAt {
            parts.append("Resets at \(UsageLimit.clock(reset)) — \(UsageLimit.countdown(to: reset, now: now))")
        } else {
            parts.append("Reset time not reported")
        }
        if let window = limit.window { parts.append("\(window) window") }
        return parts.joined(separator: " · ")
    }
}

/// Under the last message: the startup steps while the agent starts, or the failure card once it stopped.
struct EngineStateRows: View {
    let model: GrimoireModel
    let thread: ClaudeSessionSummary
    let live: LiveThread
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let since = live.startingSince {
                StartupView(steps: model.startupSteps(for: thread, live: live), since: since, now: model.now)
                    .transition(.opacity)
            } else if let failure = live.failure {
                FailureCard(
                    failure: failure, harness: thread.harness, retry: live.retry,
                    openTerminal: { model.openTerminal(for: thread) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : skin.animation(skin.motion.present), value: live.failure)
    }
}
