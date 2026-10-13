import AinkradAppKit
import AppKit
import SwiftUI

/// Opens files in Forge from what the thread shows (E5, screen 11). Set by the thread view for its folder.
struct ForgeOpener {
    /// A file (absolute, or relative to the thread's folder) at a 1-based line.
    let open: (_ path: String, _ line: Int?) -> Void
    /// A file where an edit's new-side `lines` now are, `offset` lines in; `fallback` when they cannot be found.
    let openEdit: (_ path: String, _ lines: [String], _ offset: Int, _ fallback: Int?) -> Void
    /// Whether Forge is installed and on: false when the host says it isn't (links then open the file in the default
    /// editor and read "↗ Open"); nil on a host that doesn't say.
    var isForgeAvailable: Bool?

    @MainActor init(model: GrimoireModel, directory: String) {
        open = { model.openInForge($0, line: $1, directory: directory) }
        openEdit = { model.openInForge($0, at: $1, offset: $2, fallback: $3, directory: directory) }
        isForgeAvailable = model.apps?.appAvailability(appID: ForgeLink.appID)
    }
}

extension EnvironmentValues {
    @Entry var forgeOpener: ForgeOpener?
    /// Every "↗ Forge" pill shown as if hovered — for snapshots, which cannot hover.
    @Entry var revealsForgePills = false
}

/// "↗ Forge" (mockup 11's `.forge`): a soft cyan capsule at a row's end, shown while the row is hovered (fades and
/// slides 4 pt in); white on a light glass capsule under Glass. `label` says where it opens ("↗ Open in Forge at 59",
/// "↗ :60"); without Forge every pill reads "↗ Open". A real button (GD28): Full Keyboard Access tabs to it — focus
/// shows it — and VoiceOver finds it whether or not it shows.
struct ForgePill: View {
    let isVisible: Bool
    var label = "↗ Forge"
    /// A faint key hint after the label ("⌘-click").
    var hint: String?
    let action: () -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typography
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @Environment(\.forgeOpener) private var opener

    var body: some View {
        let shown = isVisible || isFocused
        let glass = skin.usesNativeGlass
        let withoutForge = opener?.isForgeAvailable == false
        Button(action: action) {  // design-lint: allow raw-control keyboard-reachable pill (the kit badge has no button form)
            HStack(spacing: skin.size.s4) {
                Text(withoutForge ? "↗ Open" : label)
                if let hint, !withoutForge {
                    Text(hint).foregroundStyle(skin.color(skin.text.faint))
                }
            }
            .font(AinkradFontResolver.font(size: 10.5, typography: typography))
            .foregroundStyle(glass ? theme.foreground : theme.accentSecondary)
            .lineLimit(1)
            .padding(.horizontal, skin.size.s8)
            .padding(.vertical, skin.size.s1)
            .background(
                Capsule().fill(
                    glass
                        ? skin.color(skin.palette.white).opacity(skin.opacity.o14)
                        : theme.accentSecondary.opacity(skin.opacity.o12)))
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .opacity(shown ? 1 : 0)
        .offset(x: shown || reduceMotion ? 0 : skin.size.s4)
        .animation(reduceMotion ? nil : skin.animation(skin.motion.hover), value: shown)
        .help(withoutForge ? "Open in the default editor (or ⌘-click the row)" : "Open in Forge (or ⌘-click the row)")
        .accessibilityLabel(withoutForge ? "Open" : "Open in Forge")
    }
}

/// A row that opens in Forge: hover washes it and shows the pill at its end; ⌘-click anywhere on it opens too.
/// The pill keeps its room at rest (mockup 11: `margin-left: auto`), so the code never runs under it and the row
/// lays out the same hovered or not.
struct ForgeRow<Content: View>: View {
    let open: () -> Void
    var label = "↗ Forge"
    var hint: String?
    @ViewBuilder var content: Content
    @State private var hovering = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.revealsForgePills) private var reveals

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: skin.size.s8) {
            content.frame(maxWidth: .infinity, alignment: .leading)
            ForgePill(isVisible: hovering || reveals, label: label, hint: hint, action: open)
        }
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
                ForgeRow(
                    open: { opener?.open(hit.location.path, hit.location.line) }, label: "↗ Open in Forge", hint: "⌘-click"
                ) {
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
    /// "↗ Open in Forge at 40" where the line is known (a Read's offset); "↗ Open in Forge" otherwise — an edit's line
    /// is only found when it opens.
    static func label(for call: ToolCall) -> String {
        guard call.name == "Read", let offset = call.input["offset"]?.doubleValue else { return "↗ Open in Forge" }
        return "↗ Open in Forge at \(max(1, Int(offset)))"
    }

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

/// A header's "↗ Forge": shown while the header is hovered or the pill has keyboard focus. It keeps its place at
/// rest (GD28: a pill that isn't there can't be tabbed to), so the header no longer shifts on hover either.
struct ForgeHeaderPill: View {
    let isHovered: Bool
    var label = "↗ Forge"
    let action: (() -> Void)?
    @Environment(\.revealsForgePills) private var reveals

    var body: some View {
        if let action {
            // Takes width, not height: the pill is taller than the header's text, and the header stays its height.
            ForgePill(isVisible: isHovered || reveals, label: label, action: action).frame(height: 0)
        }
    }
}
