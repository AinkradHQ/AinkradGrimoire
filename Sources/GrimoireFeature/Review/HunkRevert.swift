import AinkradAppKit
import Foundation

/// A hunk the review pane can tick for "Revert selected".
struct HunkKey: Hashable, Sendable {
    var path: String
    var hunk: Int
}

/// Reverting hunks by patching the file's text: each hunk's new side (with its context) is found in the file and
/// replaced by its old side. It refuses — nothing written — when a hunk's new side isn't in the file exactly once
/// (the file changed since, or the hunk is too short to place), so it never guesses.
enum HunkRevert {
    /// `text` with `hunks` reversed, or nil when any of them can't be placed. `trustLineNumbers`: the hunks carry
    /// the file's own numbers (git's diff), which settle a hunk whose lines appear more than once.
    static func reverting(_ hunks: [AinkradDiffHunk], in text: String, trustLineNumbers: Bool) -> String? {
        var lines = text.components(separatedBy: "\n")
        // Bottom-up, so a hunk's line number still holds when the ones below it have been reverted.
        for hunk in hunks.sorted(by: { $0.newStart > $1.newStart }) {
            let new = hunk.newLines
            let old = hunk.lines.filter { $0.kind != .insertion }.map(\.text)
            guard !new.isEmpty else { return nil }
            let matches = lines.indices.filter { start in
                start + new.count <= lines.count && Array(lines[start..<start + new.count]) == new
            }
            let at: Int
            if matches.count == 1 {
                at = matches[0]
            } else if trustLineNumbers, matches.contains(hunk.newStart - 1) {
                at = hunk.newStart - 1
            } else {
                return nil
            }
            lines.replaceSubrange(at..<at + new.count, with: old)
        }
        return lines.joined(separator: "\n")
    }

    /// Reverts each file's hunks in the working tree, off the main thread. Returns the paths it refused.
    static func revert(_ files: [(path: String, hunks: [AinkradDiffHunk])], in directory: String, trustLineNumbers: Bool)
        async -> [String]
    {
        await Task.detached(priority: .userInitiated) {
            var refused: [String] = []
            for file in files {
                let url = URL(fileURLWithPath: ForgeLink.absolute(file.path, in: directory))
                guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                    let reverted = reverting(file.hunks, in: text, trustLineNumbers: trustLineNumbers)
                else {
                    refused.append(file.path)
                    continue
                }
                // Re-read right before writing: an edit landing since the read is never overwritten (GD36). In place,
                // not atomically: keeps the file's permissions and any symlink to it.
                guard (try? Data(contentsOf: url)) == data else {
                    refused.append(file.path)
                    continue
                }
                do { try Data(reverted.utf8).write(to: url) } catch { refused.append(file.path) }
            }
            return refused
        }.value
    }

    /// Identifies a hunk across loads and scopes (its ids are per load).
    static func signature(_ path: String, _ hunk: AinkradDiffHunk) -> String {
        ([path] + hunk.lines.map { "\($0.kind)\u{1}\($0.text)" }).joined(separator: "\u{2}")
    }
}
