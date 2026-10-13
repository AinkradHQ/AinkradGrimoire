import AinkradAppKit
import SwiftUI

/// An edit's hunks: removed lines red, added green, context muted.
struct DiffBlock: View {
    let diff: AinkradFileDiff
    /// The hunks carry the file's own line numbers (git's diff in the review pane); an edit's snippet doesn't.
    var hasFileLines = false
    /// Each line's number in a faint gutter (mockup 2's Edit card); only where `hasFileLines`.
    var showsGutter = false
    /// A tick box before each hunk header, for the review pane's "Revert selected".
    var selection: ((AinkradDiffHunk) -> Binding<Bool>)?
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradTypography) private var typography
    @Environment(\.forgeOpener) private var opener

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff.hunks) { hunk in
                HStack(spacing: skin.size.s6) {
                    if let selection {
                        AinkradCheckbox(isOn: selection(hunk)).help("Select this hunk to revert")
                    }
                    Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                        .foregroundStyle(skin.color(skin.text.faint))
                }
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                    if let opener, !diff.path.isEmpty {
                        // Every line opens in Forge where it now is (a removed line: where it was).
                        ForgeRow(
                            open: { Self.open(diff.path, hunk: hunk, at: index, with: opener) },
                            label: hasFileLines ? "↗ :\(Self.fileLine(hunk, at: index))" : "↗ Forge"
                        ) { row(line, number: Self.fileLine(hunk, at: index)) }
                    } else {
                        row(line, number: Self.fileLine(hunk, at: index))
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

    private func row(_ line: AinkradDiffLine, number: Int) -> some View {
        let (sign, color): (String, Color) =
            switch line.kind {
            case .insertion: ("+", statusColors.success)
            case .deletion: ("-", statusColors.danger)
            case .context: (" ", skin.color(skin.text.muted))
            }
        // Long lines wrap under the text, not the sign, so the changed end stays readable.
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if showsGutter && hasFileLines {
                Text("\(number)")
                    .foregroundStyle(skin.color(skin.text.faint))
                    .frame(width: skin.size.s30, alignment: .leading)
                    .accessibilityHidden(true)
            }
            Text("\(sign) ")
            Text(line.text).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .context ? .clear : color.opacity(skin.opacity.o08))
    }
}


/// An agent's edit, numbered where it sits in the file (GP15, mockup 2: "@@ -58,6 +58,8 @@", a 58 59 60 gutter).
/// Edits carry no line numbers, so the file is read off the main thread to find them; until then, or when the file
/// has changed past recognition, the snippet shows as before.
struct EditDiffBlock: View {
    let diff: AinkradFileDiff
    /// Absolute.
    let path: String
    @State private var located: AinkradFileDiff?

    var body: some View {
        DiffBlock(diff: located ?? diff, hasFileLines: located != nil, showsGutter: true)
            // ponytail: re-reads the file whenever the card appears; cache by path + mtime if long threads stutter.
            .task(id: path) {
                let path = path
                let text = await Task.detached(priority: .utility) { try? String(contentsOfFile: path, encoding: .utf8) }
                    .value
                located = text.flatMap { DiffBlock.located(diff, in: $0) }
            }
    }
}

extension DiffBlock {
    /// `diff` (an edit's snippet) renumbered to where it sits in `file`: each hunk found by its new side (the edit
    /// was applied) or else its old side (it waits for approval). Nil when any hunk can't be found.
    static func located(_ diff: AinkradFileDiff, in file: String) -> AinkradFileDiff? {
        var delta = 0  // lines the earlier hunks added
        var hunks: [AinkradDiffHunk] = []
        for hunk in diff.hunks {
            let oldLines = hunk.lines.filter { $0.kind != .insertion }.map(\.text)
            let start: (old: Int, new: Int)
            if let new = FileLocation.line(of: hunk.newLines, in: file), new > 0 {
                start = (new - delta, new)
            } else if let old = FileLocation.line(of: oldLines, in: file), old > 0 {
                start = (old, old + delta)
            } else {
                return nil
            }
            hunks.append(
                AinkradDiffHunk(
                    id: hunk.id, oldStart: start.old, oldCount: hunk.oldCount, newStart: start.new,
                    newCount: hunk.newCount, lines: hunk.lines))
            delta += hunk.newCount - hunk.oldCount
        }
        return hunks.isEmpty ? nil : AinkradFileDiff(path: diff.path, original: diff.original, hunks: hunks)
    }

    /// Hunk line `index`'s line in the file: the new side's, or the old side's for a removed line.
    static func fileLine(_ hunk: AinkradDiffHunk, at index: Int) -> Int {
        let before = hunk.lines.prefix(index)
        if hunk.lines[index].kind == .deletion {
            return hunk.oldStart + before.filter { $0.kind != .insertion }.count
        }
        return hunk.newStart + before.filter { $0.kind != .deletion }.count
    }

    /// Opens `path` in Forge at hunk line `index`: found by the hunk's new side in the file (edits carry no line
    /// numbers), the hunk's own number when it is not there.
    static func open(_ path: String, hunk: AinkradDiffHunk, at index: Int, with opener: ForgeOpener) {
        let offset = hunk.lines.prefix(index).filter { $0.kind != .deletion }.count
        opener.openEdit(path, hunk.newLines, offset, max(1, hunk.newStart) + offset)
    }
}
