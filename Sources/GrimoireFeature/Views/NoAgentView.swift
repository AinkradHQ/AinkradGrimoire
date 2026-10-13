import AinkradAppKit
import AppKit
import SwiftUI

/// First run with no agent CLI on the PATH (GD23): left-aligned, one install command per harness on one
/// line (scrolling sideways, never breaking inside a token), and the PATH as separate folders.
struct NoAgentView: View {
    let model: GrimoireModel
    /// The login shell's PATH that was searched.
    let searched: String
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @State private var isNarrow = false

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s14) {
            HStack(spacing: skin.size.s12) {
                Image(systemName: "terminal")
                    .font(skin.font(AinkradFontToken(sizeKey: "t20")))
                    .foregroundStyle(theme.accentSecondary)
                Text("No coding agent found")
                    .font(skin.font(AinkradFontToken(sizeKey: "t16", weight: "semibold")))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o95))
            }
            Text("Grimoire drives the agent CLIs you already use. Install one, then check again — or point Grimoire at a binary.")
                .font(skin.font(AinkradFontToken(sizeKey: "t13")))
                .foregroundStyle(skin.color(skin.text.muted))
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: skin.size.s4) {
                ForEach(Harness.allCases, id: \.self) { harness in
                    if let command = Self.installCommand(harness) {
                        InstallRow(harness: harness.displayName, command: command)
                    }
                }
            }
            VStack(alignment: .leading, spacing: skin.size.s6) {
                Text(skin.labelCased("Looked in your login shell's PATH"))
                    .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
                    .foregroundStyle(skin.color(skin.text.muted))
                FlowLayout(spacing: skin.size.s6) {
                    ForEach(Self.folders(searched), id: \.self) { AinkradChip(label: $0) }
                }
            }
            // Narrow (GD26), the buttons wrap rather than run off the edge.
            FlowLayout(spacing: skin.size.s8) { buttons }
        }
        .frame(maxWidth: skin.size.s640, alignment: .leading)
        // The mockup's 48 pt sides where there is room; 20 in a narrow window (GD26).
        .padding(.horizontal, isNarrow ? skin.size.s20 : skin.size.s48)
        .padding(.vertical, skin.size.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: Bool.self) { $0.size.width < skin.size.s440 } action: { isNarrow = $0 }
    }

    @ViewBuilder
    private var buttons: some View {
        AinkradButton(title: "Choose a binary…", style: .secondary) { model.isShowingSettings = true }
            .fixedSize()
        AinkradButton(title: "Check again", style: .primary) { Task { await model.reload() } }
            .fixedSize()
    }

    /// Only commands known to be right; agy has no package-manager install to point at.
    static func installCommand(_ harness: Harness) -> String? {
        switch harness {
        case .claude: "npm install -g @anthropic-ai/claude-code"
        case .codex: "npm install -g @openai/codex"
        case .opencode: "brew install anomalyco/tap/opencode"
        case .agy: nil
        }
    }

    /// The PATH's folders, home shown as `~`.
    static func folders(_ path: String) -> [String] {
        path.split(separator: ":").map { (String($0) as NSString).abbreviatingWithTildeInPath }
    }
}

/// "Claude  npm install -g …  [copy]": the command in mono on one line, scrolling sideways if it must.
private struct InstallRow: View {
    let harness: String
    let command: String
    @State private var isHovering = false
    @State private var copied = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typography

    var body: some View {
        HStack(spacing: skin.size.s12) {
            Text(harness)
                .font(skin.font(AinkradFontToken(sizeKey: "t12", weight: "semibold")))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                .frame(width: skin.size.s90, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(command)
                    .font(AinkradFontResolver.font(size: 12, mono: true, typography: typography))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o90))
                    .textSelection(.enabled)
                    .fixedSize()
            }
            AinkradIconButton(systemName: copied ? "checkmark" : "doc.on.doc", tooltip: "Copy") { copy() }
                .opacity(isHovering || copied ? 1 : skin.opacity.o55)
        }
        .padding(.leading, skin.size.s12)
        .padding(.trailing, skin.size.s8)
        .padding(.vertical, skin.size.s6)
        .background(
            skin.shape(cut: AinkradRadius.sm).fill(
                theme.surface.opacity(isHovering ? skin.opacity.o90 : skin.opacity.o60))
        )
        .onHover { isHovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// Lays its children out in rows, wrapping only between them; each centred in its row's height.
struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(width: bounds.width, subviews).points) {
            subview.place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .leading, proposal: .unspecified)
        }
    }

    /// Each subview's leading-centre point.
    private func arrange(width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var rows: [[(x: CGFloat, height: CGFloat)]] = [[]]
        var x: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((x, size.height))
            x += size.width + spacing
            widest = max(widest, x - spacing)
        }
        var points: [CGPoint] = []
        var y: CGFloat = 0
        for row in rows where !row.isEmpty {
            let height = row.map(\.height).max() ?? 0
            points += row.map { CGPoint(x: $0.x, y: y + height / 2) }
            y += height + spacing
        }
        return (points, CGSize(width: widest, height: max(y - spacing, 0)))
    }
}
