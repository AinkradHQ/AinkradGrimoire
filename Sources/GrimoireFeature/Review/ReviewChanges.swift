import AinkradAppKit
import Foundation

/// One changed file in the review pane.
struct FileChange: Equatable, Identifiable, Sendable {
    enum Status: String, Sendable {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case untracked = "?"
    }

    var path: String
    var status: Status
    /// `nil` for binary files and untracked files (nothing to diff against).
    var diff: AinkradFileDiff?
    /// The hunks carry the file's own line numbers (git's diff, or an edit found in the file); an agent's edit
    /// that couldn't be found carries its snippet's.
    var hasFileLines = true
    var id: String { path }

    var added: Int { diff?.hunks.flatMap(\.lines).filter { $0.kind == .insertion }.count ?? 0 }
    var removed: Int { diff?.hunks.flatMap(\.lines).filter { $0.kind == .deletion }.count ?? 0 }
}

enum ReviewScope: String, CaseIterable, Sendable {
    case turn = "This turn"
    case thread = "Whole thread"
    case uncommitted = "Uncommitted"
}

enum ReviewChanges {
    /// The files the agent edited, from its own Edit / Write calls: since your
    /// last message (`.turn`) or in the whole thread. Several edits to one file
    /// become one card with all their hunks, in order. An edit that names only
    /// its file (agy's `Update`) is listed with no diff, for `filledFromGit`.
    static func fromEntries(_ entries: [ThreadEntry], scope: ReviewScope, workingDirectory: String) -> [FileChange] {
        let slice: ArraySlice<ThreadEntry>
        if scope == .turn, let lastUser = entries.lastIndex(where: { if case .user = $0 { true } else { false } }) {
            slice = entries[(lastUser + 1)...]
        } else {
            slice = entries[...]
        }
        var order: [String] = []
        var hunks: [String: [AinkradDiffHunk]] = [:]
        var statuses: [String: FileChange.Status] = [:]
        /// Files only an `Update` touched: their diff comes from git.
        var unknown: Set<String> = []
        for entry in slice {
            guard case .tool(let call) = entry, call.result?.isError != true else { continue }
            let edits: [FileChange]
            let absolute = call.input["file_path"]?.stringValue ?? ""
            switch call.name {
            case "Edit", "MultiEdit":
                edits = [FileChange(path: absolute, status: .modified, diff: ToolSummary.editDiff(call.input))]
            case "Write":
                let diff = AinkradDiffEngine.compute(
                    old: "", new: call.input["content"]?.stringValue ?? "", path: absolute, context: 0)
                edits = [FileChange(path: absolute, status: .added, diff: diff)]
            case "Patch":
                edits = patchChanges(call.input)
            case "Update":
                edits = [FileChange(path: absolute, status: .modified, diff: nil)]
            default:
                continue
            }
            for edit in edits where !edit.path.isEmpty {
                guard edit.diff != nil || call.name == "Update" else { continue }
                let path = ToolSummary.relative(edit.path, to: workingDirectory)
                if statuses[path] == nil {
                    order.append(path)
                    statuses[path] = edit.status
                }
                guard let diff = edit.diff else {
                    unknown.insert(path)
                    continue
                }
                let offset = hunks[path]?.count ?? 0
                hunks[path, default: []] += diff.hunks.enumerated().map { index, hunk in
                    AinkradDiffHunk(
                        id: offset + index, oldStart: hunk.oldStart, oldCount: hunk.oldCount, newStart: hunk.newStart,
                        newCount: hunk.newCount, lines: hunk.lines)
                }
            }
        }
        return order.map { path in
            FileChange(
                path: path, status: statuses[path] ?? .modified,
                diff: hunks[path] == nil && unknown.contains(path)
                    ? nil : AinkradFileDiff(path: path, original: "", hunks: hunks[path] ?? []),
                hasFileLines: false)
        }
    }

    /// Fills the changes `fromEntries` left without a diff from `git diff --relative` of those files
    /// (GD24: agy's edits carry no strings). That diff is the file's whole uncommitted change, not only
    /// the agent's part of it; a file git shows no change for gets an empty diff.
    static func filledFromGit(_ files: [FileChange], diff: String) -> [FileChange] {
        let fromGit = Dictionary(parseUnifiedDiff(diff).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return files.map { file in
            guard file.diff == nil else { return file }
            return fromGit[file.path] ?? FileChange(
                path: file.path, status: file.status, diff: AinkradFileDiff(path: file.path, original: "", hunks: []))
        }
    }

    /// A Codex `fileChange` (`Patch`) as changes with absolute paths. An
    /// update's `diff` is bare hunks; an add's or delete's is the whole file.
    static func patchChanges(_ input: JSONValue) -> [FileChange] {
        (input["changes"]?.arrayValue ?? []).compactMap { change in
            guard let path = change["path"]?.stringValue else { return nil }
            let text = change["diff"]?.stringValue ?? ""
            switch change["kind"]?["type"]?.stringValue {
            case "add":
                return FileChange(
                    path: path, status: .added, diff: AinkradDiffEngine.compute(old: "", new: text, path: path, context: 0))
            case "delete":
                return FileChange(
                    path: path, status: .deleted,
                    diff: AinkradDiffEngine.compute(old: text, new: "", path: path, context: 0))
            default:
                let parsed = parseUnifiedDiff("diff --git a/x b/x\n" + text).first
                return FileChange(path: path, status: .modified, diff: parsed?.diff.map {
                    AinkradFileDiff(path: path, original: "", hunks: $0.hunks)
                })
            }
        }
    }

    /// `git diff` output (unified, any context) → one change per file.
    static func parseUnifiedDiff(_ text: String) -> [FileChange] {
        var changes: [FileChange] = []
        var path: String?
        var status = FileChange.Status.modified
        var hunks: [AinkradDiffHunk] = []
        var lines: [AinkradDiffLine] = []
        var header: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)?
        var oldLine = 0
        var newLine = 0
        var binary = false

        func closeHunk() {
            guard let current = header else { return }
            hunks.append(
                AinkradDiffHunk(
                    id: hunks.count, oldStart: current.oldStart, oldCount: current.oldCount, newStart: current.newStart,
                    newCount: current.newCount, lines: lines))
            header = nil
            lines = []
        }
        func closeFile() {
            closeHunk()
            if let path {
                changes.append(
                    FileChange(
                        path: path, status: status,
                        diff: binary ? nil : AinkradFileDiff(path: path, original: "", hunks: hunks)))
            }
            path = nil
            status = .modified
            hunks = []
            binary = false
        }

        // Split on "\n" alone, keeping a CRLF line's "\r" in its text as HunkRevert does: "\r\n" is one Character,
        // so a Character split would merge a CRLF file's lines and swallow the next file's header (GD33).
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                closeFile()
                // `diff --git a/x b/x` — the b side, unless +++ names it later. A name git had to quote reads
                // `"b/…"` (GD37).
                path = line.range(of: " \"b/", options: .backwards).map { gitPath(String(line[$0.lowerBound...])) }
                    ?? line.components(separatedBy: " b/").last
            } else if header == nil, line.hasPrefix("new file mode") {
                status = .added
            } else if header == nil, line.hasPrefix("deleted file mode") {
                status = .deleted
            } else if header == nil, line.hasPrefix("+++ b/") || line.hasPrefix("+++ \"b/") {
                path = gitPath(String(line.dropFirst(4)))
            } else if header == nil, line.hasPrefix("Binary files") {
                binary = true
            } else if line.hasPrefix("@@"), let parsed = hunkHeader(line) {
                closeHunk()
                header = parsed
                oldLine = parsed.oldStart
                newLine = parsed.newStart
            } else if header != nil {
                switch line.first {
                case " ":
                    lines.append(
                        AinkradDiffLine(
                            kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(line.dropFirst())))
                    oldLine += 1
                    newLine += 1
                case "-":
                    lines.append(
                        AinkradDiffLine(
                            kind: .deletion, oldNumber: oldLine, newNumber: nil, text: String(line.dropFirst())))
                    oldLine += 1
                case "+":
                    lines.append(
                        AinkradDiffLine(
                            kind: .insertion, oldNumber: nil, newNumber: newLine, text: String(line.dropFirst())))
                    newLine += 1
                default:
                    break  // "\ No newline at end of file", or the trailing empty line
                }
            }
        }
        closeFile()
        return changes
    }

    /// `@@ -12,3 +12,5 @@ …` → (12, 3, 12, 5); a missing count means 1.
    static func hunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ part: Substring) -> (Int, Int)? {
            let numbers = part.dropFirst().split(separator: ",")
            guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
            return (start, numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    /// `git status --porcelain=v1 -z` → untracked paths (`?? path`). `-z` names every path raw, NUL-ended
    /// (GD37); a rename's or copy's entry is followed by its source path, which is skipped.
    static func untracked(fromPorcelain text: String) -> [String] {
        var paths: [String] = []
        var skipNext = false
        for entry in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if skipNext {
                skipNext = false
            } else if entry.hasPrefix("?? ") {
                paths.append(String(entry.dropFirst(3)))
            } else if entry.first == "R" || entry.first == "C" {
                skipNext = true
            }
        }
        return paths
    }

    /// A path from a diff header (`b/x`, or `"b/x"` when git C-quoted it), without its side prefix or the tab git
    /// puts after a name with a space (GD37).
    static func gitPath(_ field: String) -> String {
        var field = field.hasSuffix("\t") ? String(field.dropLast()) : field
        if field.hasPrefix("\""), field.hasSuffix("\""), field.count >= 2 {
            var bytes: [UInt8] = []
            var scalars = Array(field.utf8.dropFirst().dropLast())[...]
            while let byte = scalars.popFirst() {
                guard byte == UInt8(ascii: "\\"), let next = scalars.popFirst() else {
                    bytes.append(byte)
                    continue
                }
                switch next {
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(next - UInt8(ascii: "0"))
                    for _ in 0..<2 {
                        guard let digit = scalars.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                        value = value * 8 + Int(digit - UInt8(ascii: "0"))
                        scalars.removeFirst()
                    }
                    bytes.append(UInt8(truncatingIfNeeded: value))
                case UInt8(ascii: "a"): bytes.append(7)
                case UInt8(ascii: "b"): bytes.append(8)
                case UInt8(ascii: "t"): bytes.append(9)
                case UInt8(ascii: "n"): bytes.append(10)
                case UInt8(ascii: "v"): bytes.append(11)
                case UInt8(ascii: "f"): bytes.append(12)
                case UInt8(ascii: "r"): bytes.append(13)
                default: bytes.append(next)
                }
            }
            field = String(decoding: bytes, as: UTF8.self)
        }
        return field.hasPrefix("a/") || field.hasPrefix("b/") ? String(field.dropFirst(2)) : field
    }

    /// Queued review comments as one message to the agent — each place (`file:line`), the line quoted, the
    /// comment — then `text`, the message they go with.
    static func message(for comments: [ReviewComment], then text: String = "") -> String {
        let list = comments.map { comment in
            let place = comment.line.map { "\(comment.path):\($0)" } ?? comment.path
            let quote = comment.quote.trimmingCharacters(in: .whitespaces)
            return "- \(place)\n" + (quote.isEmpty ? "" : "  > \(quote)\n") + "  \(comment.text)"
        }
        let block = "Review comments on your changes:\n" + list.joined(separator: "\n")
        return text.isEmpty ? block : block + "\n\n" + text
    }

    /// The agent's edits renumbered where they sit in their files (read off the main thread), so their headers,
    /// Forge pills and comments name real lines. A file whose edits can't all be found keeps the snippet's.
    static func located(_ files: [FileChange], in directory: String) async -> [FileChange] {
        await Task.detached(priority: .userInitiated) {
            files.map { file in
                guard !file.hasFileLines, let diff = file.diff,
                    let text = try? String(contentsOfFile: ForgeLink.absolute(file.path, in: directory), encoding: .utf8),
                    let located = diff.located(in: text)
                else { return file }
                return FileChange(path: file.path, status: file.status, diff: located)
            }
        }.value
    }
}

/// A comment on one line of the review, queued for the agent until it is sent.
struct ReviewComment: Equatable, Sendable {
    var path: String
    /// Nil when the file's line numbers aren't known.
    var line: Int?
    /// The line commented on.
    var quote: String
    var text: String
}
