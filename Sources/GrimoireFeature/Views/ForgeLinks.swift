import AinkradAppKit
import AppKit
import SwiftUI

/// Opens files in Forge from what the thread shows (E5, screen 11). Set by the thread view for its folder.
struct ForgeOpener {
    /// A file (absolute, or relative to the thread's folder) at a 1-based line.
    let open: (_ path: String, _ line: Int?) -> Void
    /// A file where an edit's new-side `lines` now are, `offset` lines in; `fallback` when they cannot be found.
    let openEdit: (_ path: String, _ lines: [String], _ offset: Int, _ fallback: Int?) -> Void

    @MainActor init(model: GrimoireModel, directory: String) {
        open = { model.openInForge($0, line: $1, directory: directory) }
        openEdit = { model.openInForge($0, at: $1, offset: $2, fallback: $3, directory: directory) }
    }
}

extension EnvironmentValues {
    @Entry var forgeOpener: ForgeOpener?
    /// Every "↗ Forge" pill shown as if hovered — for snapshots, which cannot hover.
    @Entry var revealsForgePills = false
}

/// "↗ Forge": the kit badge at a row's end, shown while the row is hovered (fades and slides 4 pt in).
struct ForgePill: View {
    let isVisible: Bool
    let action: () -> Void
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        AinkradBadge(text: "↗ Forge", tint: theme.accentSecondary)
            .fixedSize()
            .opacity(isVisible ? 1 : 0)
            .offset(x: isVisible || reduceMotion ? 0 : skin.size.s4)
            .animation(reduceMotion ? nil : skin.animation(skin.motion.hover), value: isVisible)
            .contentShape(Rectangle())
            // Over a row that is itself a button (a tool card's header): the pill's tap wins.
            .highPriorityGesture(TapGesture().onEnded(action))
            .help("Open in Forge (or ⌘-click the row)")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open in Forge")
            .accessibilityHidden(!isVisible)
    }
}

/// A row that opens in Forge: hover washes it and shows the pill over its end; ⌘-click anywhere on it opens too.
/// The pill overlays rather than takes room, so a row lays out the same hovered or not.
struct ForgeRow<Content: View>: View {
    let open: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.revealsForgePills) private var reveals

    var body: some View {
        content
        .overlay(alignment: .trailing) { ForgePill(isVisible: hovering || reveals, action: open) }
        .background(hovering || reveals ? theme.foreground.opacity(skin.opacity.o06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { if NSEvent.modifierFlags.contains(.command) { open() } })
    }
}

/// Grep's content output (`path:12:text`) as rows: the place in the accent, underlined on hover, the line after it.
struct GrepHits: View {
    let hits: [(location: FileLocation, text: Substring)]
    let maxLines: Int
    @State private var showsAll = false
    @Environment(\.forgeOpener) private var opener
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTypography) private var typography

    /// Every line a hit, or nil (the output is something else: a file list, a count).
    static func parse(_ output: String) -> [(location: FileLocation, text: Substring)]? {
        let lines = ToolSummary.lines(output)
        let hits = lines.compactMap(FileLocation.grepHit)
        return !hits.isEmpty && hits.count == lines.count ? hits : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hits.prefix(showsAll ? hits.count : maxLines).enumerated()), id: \.offset) { _, hit in
                ForgeRow(open: { opener?.open(hit.location.path, hit.location.line) }) {
                    HStack(alignment: .firstTextBaseline, spacing: skin.size.s10) {
                        Text("\(hit.location.path):\(hit.location.line ?? 1)").foregroundStyle(theme.accentSecondary).fixedSize()
                        Text(hit.text.trimmingCharacters(in: .whitespaces)).foregroundStyle(skin.color(skin.text.muted)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, skin.size.s8)
            }
            if hits.count > maxLines {
                Button {  // design-lint: allow raw-control keyboard-reachable expander (kit has no disclosure row)
                    showsAll.toggle()
                } label: {
                    Text(showsAll ? "Show less" : "\(hits.count - maxLines) more matches")
                        .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                        .foregroundStyle(skin.color(skin.text.faint))
                        .padding(.horizontal, skin.size.s8)
                        .padding(.top, skin.size.s4)
                }
                .buttonStyle(.plain)
            }
        }
        .font(AinkradFontResolver.font(size: 11.5, mono: true, typography: typography))
        .padding(.vertical, skin.size.s6)
        .background(skin.shape(cut: AinkradRadius.sm).fill(theme.background.opacity(skin.opacity.o70)))
    }
}

/// Where a tool card's "↗ Forge" opens: a Read at its first line, a Write at the top, an edit at its first change.
enum ForgeTarget {
    @MainActor static func action(for call: ToolCall, opener: ForgeOpener?) -> (() -> Void)? {
        guard let opener, call.result?.isError != true, let path = call.input["file_path"]?.stringValue, !path.isEmpty
        else { return nil }
        switch call.name {
        case "Read":
            let line = call.input["offset"]?.doubleValue.map { max(1, Int($0)) }
            return { opener.open(path, line) }
        case "Write":
            return { opener.open(path, 1) }
        case "Edit", "MultiEdit":
            guard let hunk = ToolSummary.editDiff(call.input).hunks.first else { return { opener.open(path, nil) } }
            let first = hunk.lines.firstIndex { $0.kind != .context } ?? 0
            return { DiffBlock.open(path, hunk: hunk, at: first, with: opener) }
        default:
            return nil
        }
    }
}

/// A header's "↗ Forge": inserted while the header is hovered, so at rest the header lays out as before.
struct ForgeHeaderPill: View {
    let isHovered: Bool
    let action: (() -> Void)?
    @Environment(\.revealsForgePills) private var reveals

    var body: some View {
        if let action, isHovered || reveals {
            ForgePill(isVisible: true, action: action).transition(.opacity.combined(with: .offset(x: 4)))
        }
    }
}
