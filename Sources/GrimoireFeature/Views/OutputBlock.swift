import AinkradAppKit
import SwiftUI

/// A command's output or a file's content: monospaced, the first lines until "N more lines" opens the rest.
struct OutputBlock: View {
    let text: String
    let maxLines: Int
    @State private var showsAll = false
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTypography) private var typography

    var body: some View {
        let lines = ToolSummary.lines(text)
        let shown = lines.prefix(showsAll ? lines.count : maxLines)
        let numbered = shown.compactMap(ToolSummary.gutter)
        VStack(alignment: .leading, spacing: skin.size.s4) {
            Group {
                if !numbered.isEmpty, numbered.count == shown.count {
                    // Numbered lines wrap under their text, not the number (GD5).
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(numbered.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: skin.size.s8) {
                                Text(line.number).foregroundStyle(skin.color(skin.text.faint))
                                Text(line.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else {
                    // ponytail: one Text for the whole output; virtualize if multi-thousand-line outputs get slow.
                    Text(shown.joined(separator: "\n"))
                }
            }
            .font(AinkradFontResolver.font(size: 11.5, mono: true, typography: typography))
            .foregroundStyle(skin.color(skin.text.muted))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if lines.count > maxLines {
                // A plain button, so Full Keyboard Access can focus it and Space opens the rest (GD19).
                Button {  // design-lint: allow raw-control keyboard-reachable expander (kit has no disclosure row)
                    showsAll.toggle()
                } label: {
                    HStack(spacing: skin.size.s4) {
                        Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                        Text(showsAll ? "Show less" : "\(lines.count - maxLines) more lines")
                    }
                    .font(skin.font(AinkradFontToken(sizeKey: "t10")))
                    .foregroundStyle(skin.color(skin.text.faint))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(skin.size.s8)
        .background(skin.shape(cut: AinkradRadius.sm).fill(theme.background.opacity(skin.opacity.o70)))
    }
}
