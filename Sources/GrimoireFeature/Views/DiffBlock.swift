import AinkradAppKit
import SwiftUI

/// An edit's hunks: removed lines red, added green, context muted.
struct DiffBlock: View {
    let diff: AinkradFileDiff
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography
    @Environment(\.forgeOpener) private var opener

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff.hunks) { hunk in
                Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                    .foregroundStyle(skin.color(skin.text.faint))
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                    if let opener, !diff.path.isEmpty {
                        // Every line opens in Forge where it now is (a removed line: where it was).
                        ForgeRow(open: { Self.open(diff.path, hunk: hunk, at: index, with: opener) }) { row(line) }
                    } else {
                        row(line)
                    }
                }
            }
        }
        .font(AinkradFontResolver.font(size: 11.5, mono: true, typography: typography))
        .textSelection(.enabled)
        .padding(.vertical, skin.size.s6)
        .padding(.horizontal, skin.size.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.shape(cut: AinkradRadius.sm).fill(theme.background.opacity(skin.opacity.o70)))
    }

    private func row(_ line: AinkradDiffLine) -> some View {
        let (sign, color): (String, Color) =
            switch line.kind {
            case .insertion: ("+", statusColors.success)
            case .deletion: ("-", statusColors.danger)
            case .context: (" ", skin.color(skin.text.muted))
            }
        // Long lines wrap under the text, not the sign, so the changed end stays readable.
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(sign) ")
            Text(line.text).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .context ? .clear : color.opacity(skin.opacity.o08))
    }
}


extension DiffBlock {
    /// Opens `path` in Forge at hunk line `index`: found by the hunk's new side in the file (edits carry no line
    /// numbers), the hunk's own number when it is not there.
    static func open(_ path: String, hunk: AinkradDiffHunk, at index: Int, with opener: ForgeOpener) {
        let offset = hunk.lines.prefix(index).filter { $0.kind != .deletion }.count
        opener.openEdit(path, hunk.newLines, offset, max(1, hunk.newStart) + offset)
    }
}
