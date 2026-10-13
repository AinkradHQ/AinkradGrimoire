import AinkradAppKit
import Foundation

/// What the thread view draws, one row each: transcript items grouped so a
/// tool call carries its own result and the agent's todo list becomes a plan.
enum ThreadEntry: Equatable, Sendable {
    case user(String)
    case text(String)
    case thinking(String)
    case tool(ToolCall)
    case plan([PlanStep])
    /// Grimoire's own quiet line in the transcript (the agent did not answer).
    case note(String)
}

struct ToolCall: Equatable, Sendable {
    var id: String
    var name: String
    var input: JSONValue
    /// `nil` while the tool is still running (or its result was never stored).
    var result: ToolOutput?
    /// The command the agent wrote, when a hook rewrote it before it ran; `input` then holds what runs.
    var rewrittenFrom: String? = nil
    /// How long it ran, when this run saw it start and finish.
    var duration: TimeInterval? = nil
}

struct ToolOutput: Equatable, Sendable {
    var content: String
    var isError: Bool
}

struct PlanStep: Equatable, Sendable {
    enum Status: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }
    var title: String
    var status: Status
}

enum ThreadEntries {
    /// Groups `items` in order. A tool result fills in the call it answers and
    /// never stands alone; a `TodoWrite` call is shown as a plan instead of a
    /// tool card; empty text and thinking blocks are dropped.
    static func build(_ items: [TranscriptItem]) -> [ThreadEntry] {
        var entries: [ThreadEntry] = []
        var toolIndex: [String: Int] = [:]
        for item in items {
            switch item {
            case .user(let text):
                entries.append(.user(text))
            case .assistant(.text(let text)):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { entries.append(.text(text)) }
            case .assistant(.thinking(let text)):
                if !text.isEmpty { entries.append(.thinking(text)) }
            case .assistant(.toolUse(let id, let name, let input)):
                if name == "TodoWrite", let steps = plan(from: input) {
                    entries.append(.plan(steps))
                } else {
                    toolIndex[id] = entries.count
                    entries.append(.tool(ToolCall(id: id, name: name, input: input, result: nil)))
                }
            case .toolResult(let id, let content, let isError):
                guard let index = toolIndex[id], case .tool(var call) = entries[index] else { continue }
                call.result = ToolOutput(content: content, isError: isError)
                entries[index] = .tool(call)
            }
        }
        return entries
    }

    static func plan(from input: JSONValue) -> [PlanStep]? {
        guard let todos = input["todos"]?.arrayValue else { return nil }
        return todos.compactMap { todo in
            guard let title = todo["content"]?.stringValue else { return nil }
            return PlanStep(
                title: title, status: PlanStep.Status(rawValue: todo["status"]?.stringValue ?? "") ?? .pending)
        }
    }
}

/// One-line summaries for a tool card's header.
enum ToolSummary {
    /// The argument worth showing: a command, a path relative to the project,
    /// a pattern or URL — or the first string the input has.
    static func argument(name: String, input: JSONValue, workingDirectory: String) -> String {
        func path(_ key: String) -> String? {
            input[key]?.stringValue.map { relative($0, to: workingDirectory) }
        }
        switch name {
        case "Bash": return input["command"]?.stringValue ?? ""
        case "Read":
            // The file's name, and the range read when it is one (mockup 11: "SidebarRow.swift · lines 40–80").
            let name = input["file_path"]?.stringValue.map { ($0 as NSString).lastPathComponent } ?? ""
            guard let offset = input["offset"]?.doubleValue.map({ Int($0) }) else { return name }
            guard let limit = input["limit"]?.doubleValue.map({ Int($0) }), limit > 0 else {
                return "\(name) · from line \(offset)"
            }
            return "\(name) · lines \(offset)–\(offset + limit - 1)"
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "Update":
            return path("file_path") ?? path("notebook_path") ?? ""
        case "Grep":
            let pattern = input["pattern"]?.stringValue.map { "\"\($0)\"" } ?? ""
            return [pattern, path("path").map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
        case "Glob": return input["pattern"]?.stringValue ?? ""
        case "Patch":
            let paths = (input["changes"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
            guard let first = paths.first else { return "" }
            let more = paths.count > 1 ? " +\(paths.count - 1) more" : ""
            return relative(first, to: workingDirectory) + more
        case "WebFetch": return input["url"]?.stringValue ?? ""
        case "WebSearch": return input["query"]?.stringValue ?? ""
        case "Task", "Agent": return input["description"]?.stringValue ?? ""
        default:
            guard case .object(let object) = input else { return "" }
            return object.keys.sorted().lazy.compactMap { object[$0]?.stringValue }.first ?? ""
        }
    }

    /// A short right-hand note: line counts for reads, +/- for edits, the
    /// first line of an error.
    static func result(name: String, input: JSONValue, output: ToolOutput?) -> String {
        guard let output else { return "running…" }
        if output.isError {
            return output.content.split(separator: "\n").first.map { String($0.prefix(60)) } ?? "failed"
        }
        switch name {
        case "Edit", "MultiEdit":
            let lines = editDiff(input).hunks.flatMap(\.lines)
            let added = lines.filter { $0.kind == .insertion }.count
            let removed = lines.filter { $0.kind == .deletion }.count
            return "+\(added) −\(removed)"
        case "Patch":
            let lines = ReviewChanges.patchChanges(input).compactMap(\.diff).flatMap(\.hunks).flatMap(\.lines)
            return "+\(lines.filter { $0.kind == .insertion }.count) −\(lines.filter { $0.kind == .deletion }.count)"
        case "Write":
            let lines = lineCount(input["content"]?.stringValue ?? "")
            return lines == 1 ? "1 line" : "\(lines) lines"
        case "Grep":
            let matches = output.content.split(separator: "\n").count
            return matches == 1 ? "1 match" : "\(matches) matches"
        case "Glob":
            let files = output.content.split(separator: "\n").count
            return files == 1 ? "1 file" : "\(files) files"
        case "Read", "Bash":
            let lines = lineCount(output.content)
            return lines == 1 ? "1 line" : "\(lines) lines"
        default:
            return ""
        }
    }

    /// An edit's added and removed lines; nil for any other tool.
    static func counts(name: String, input: JSONValue) -> (added: Int, removed: Int)? {
        let lines: [AinkradDiffLine]
        switch name {
        case "Edit", "MultiEdit": lines = editDiff(input).hunks.flatMap(\.lines)
        case "Patch": lines = ReviewChanges.patchChanges(input).compactMap(\.diff).flatMap(\.hunks).flatMap(\.lines)
        default: return nil
        }
        return (lines.filter { $0.kind == .insertion }.count, lines.filter { $0.kind == .deletion }.count)
    }

    /// An `Edit` input (`old_string` → `new_string`) as a line diff.
    static func editDiff(_ input: JSONValue) -> AinkradFileDiff {
        AinkradDiffEngine.compute(
            old: input["old_string"]?.stringValue ?? "", new: input["new_string"]?.stringValue ?? "",
            path: input["file_path"]?.stringValue ?? "", context: 2)
    }

    static func relative(_ path: String, to directory: String) -> String {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    static func lineCount(_ text: String) -> Int { lines(text).count }

    /// A `cat -n` or Read line ("     12\tcode", "    12→code") as its number and its text; `nil` for any other (GD5).
    static func gutter(_ line: Substring) -> (number: Substring, text: Substring)? {
        guard let separator = line.firstIndex(where: { $0 == "\t" || $0 == "→" }) else { return nil }
        let number = line[..<separator]
        guard number.contains(where: \.isNumber), number.allSatisfy({ $0 == " " || $0.isNumber }) else { return nil }
        return (number, line[line.index(after: separator)...])
    }

    /// `text` split into lines; the newline that ends the last line (nearly all
    /// output has one) does not start another, empty one (GD18).
    static func lines(_ text: String) -> [Substring] {
        let body = text.hasSuffix("\n") ? text.dropLast() : Substring(text)
        return text.isEmpty ? [] : body.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
