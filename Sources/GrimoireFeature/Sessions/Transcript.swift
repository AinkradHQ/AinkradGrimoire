import Foundation

/// One row of a conversation, whether it came from a stored session file or
/// from a live engine — the thread view renders only these.
public enum TranscriptItem: Sendable, Equatable {
    case user(String)
    case assistant(AssistantBlock)
    case toolResult(toolUseID: String, content: String, isError: Bool)
}

extension ClaudeSessions {
    /// A stored session as transcript rows, in order. Subagent turns
    /// (`isSidechain`), injected context (`isMeta`) and bookkeeping lines are
    /// left out; unreadable lines are skipped.
    public static func history(of file: URL) throws -> [TranscriptItem] {
        try history(Data(contentsOf: file))
    }

    static func history(_ data: Data) -> [TranscriptItem] {
        lines(data, dropFirst: false, dropLast: false).flatMap(items(from:))
    }

    static func items(from line: JSONValue) -> [TranscriptItem] {
        guard line["isSidechain"]?.boolValue != true, line["isMeta"]?.boolValue != true else { return [] }
        switch line["type"]?.stringValue {
        case "user":
            if let prompt = humanPrompt(line) { return [.user(prompt)] }
            return (line["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                switch block["type"]?.stringValue {
                case "tool_result":
                    return .toolResult(
                        toolUseID: block["tool_use_id"]?.stringValue ?? "",
                        content: ClaudeProtocol.text(of: block["content"]),
                        isError: block["is_error"]?.boolValue ?? false)
                case "text":
                    return block["text"]?.stringValue.map(TranscriptItem.user)
                default:
                    return nil
                }
            }
        case "assistant":
            return ClaudeProtocol.blocks(of: line["message"]).map(TranscriptItem.assistant)
        default:
            return []
        }
    }
}
