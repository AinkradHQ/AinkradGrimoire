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
    /// become one card with all their hunks, in order.
    static func fromEntries(_ entries: [ThreadEntry], scope: ReviewScope, workingDirectory: String) -> [FileChange] {
        let slice: ArraySlice<ThreadEntry>
        if scope == .turn, let lastUser = entries.lastIndex(where: { if case .user = $0 { true } else { false } }) {
            slice = entries[(lastUser + 1)...]
        } else {
            slice = entries[...]
        }
        var order: [String] = []
        var hunks: [String: [AinkradDiffHunk]] = [:]
        var created: Set<String> = []
        for entry in slice {
            guard case .tool(let call) = entry, call.result?.isError != true,
                let absolute = call.input["file_path"]?.stringValue
            else { continue }
            let path = ToolSummary.relative(absolute, to: workingDirectory)
            let diff: AinkradFileDiff
            switch call.name {
            case "Edit", "MultiEdit":
                diff = ToolSummary.editDiff(call.input)
            case "Write":
                diff = AinkradDiffEngine.compute(
                    old: "", new: call.input["content"]?.stringValue ?? "", path: path, context: 0)
                if hunks[path] == nil { created.insert(path) }
            default:
                continue
            }
            if hunks[path] == nil { order.append(path) }
            let offset = hunks[path]?.count ?? 0
            hunks[path, default: []] += diff.hunks.enumerated().map { index, hunk in
                AinkradDiffHunk(
                    id: offset + index, oldStart: hunk.oldStart, oldCount: hunk.oldCount, newStart: hunk.newStart,
                    newCount: hunk.newCount, lines: hunk.lines)
            }
        }
        return order.map { path in
            FileChange(
                path: path, status: created.contains(path) ? .added : .modified,
                diff: AinkradFileDiff(path: path, original: "", hunks: hunks[path] ?? []))
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

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                closeFile()
                // `diff --git a/x b/x` — the b side, unless +++ names it later.
                path = line.components(separatedBy: " b/").last
            } else if header == nil, line.hasPrefix("new file mode") {
                status = .added
            } else if header == nil, line.hasPrefix("deleted file mode") {
                status = .deleted
            } else if header == nil, line.hasPrefix("+++ b/") {
                path = String(line.dropFirst(6))
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

    /// `git status --porcelain` → untracked paths (`?? path`).
    static func untracked(fromPorcelain text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            line.hasPrefix("?? ") ? String(line.dropFirst(3)) : nil
        }
    }

    /// Queued review comments as one message to the agent.
    static func message(for comments: [(path: String, text: String)]) -> String {
        "Review comments on your changes:\n" + comments.map { "- \($0.path): \($0.text)" }.joined(separator: "\n")
    }
}
