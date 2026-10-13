import AinkradAppKit
import Foundation

/// Another app asking Grimoire to start a thread: Forge's Ask Agent sends the project folder and the request
/// (the place, the code, the words). Forge sends it as an `openDocument` (so the host brings an open Grimoire
/// forward instead of opening another), older Forges as `askAgent`; apps that read only `AinkradLaunchIntent`
/// see a folder and ignore the rest.
struct AskLaunch: Codable, Equatable {
    static let kind = "askAgent"

    let kind: String
    /// The project folder.
    let path: String
    /// The whole request: place, code and words — what an older Grimoire puts in the field.
    let prompt: String
    /// Forge's ⌘I parts: the typed words, and the code they are about (file relative to `path`, 1-based lines).
    var request: String?
    var file: String?
    var lines: [Int]?
    var code: String?
    /// Forge's "Ask about this turn…": the thread to continue, rather than a new one.
    var thread: String?

    /// The payload, when it is one of these (anything else is not ours, and is not an error).
    static func decode(_ payload: String?) -> AskLaunch? {
        guard let data = payload?.data(using: .utf8), let launch = try? JSONDecoder().decode(AskLaunch.self, from: data),
            launch.kind == kind || launch.kind == AinkradLaunchIntent.openDocumentKind
        else { return nil }
        return launch
    }

    /// The selection the request is about, when Forge sent its parts.
    var context: AskContext? {
        guard let file, let lines, let first = lines.first, let last = lines.last, first <= last, let code else { return nil }
        return AskContext(project: path, file: file, lines: first...last, code: code)
    }
}

/// The code a request from Forge is about: shown as a chip and a read-only snippet, sent with the words.
struct AskContext: Hashable {
    let project: String
    /// Relative to `project`.
    let file: String
    let lines: ClosedRange<Int>
    let code: String

    /// "SidebarRow.swift · lines 18–21 · 4 lines"
    var label: String {
        let name = (file as NSString).lastPathComponent
        guard lines.count > 1 else { return "\(name) · line \(lines.lowerBound)" }
        return "\(name) · lines \(lines.lowerBound)–\(lines.upperBound) · \(lines.count) lines"
    }

    /// The snippet with its line numbers, as tool output shows them.
    var numbered: String {
        ToolSummary.lines(code).enumerated().map { "\(lines.lowerBound + $0.offset)\t\($0.element)" }.joined(separator: "\n")
    }

    /// What goes to the agent — the same words Forge's own message uses: the place, the code, the request.
    func message(_ request: String) -> String {
        let place = lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)–\(lines.upperBound)"
        return "In \(file), \(place):\n\n```\((file as NSString).pathExtension)\n\(code)\n```\n\n\(request)"
    }
}

/// A new thread another app asked for, prefilled in the main pane's composer. Your edits live here, in the model,
/// so leaving an edited ask can ask first rather than lose them (GD31).
struct ForgeAsk: Hashable {
    let project: String
    let prompt: String
    /// Forge's selection, when it sent one: the chip and snippet above the field.
    var context: AskContext?
    /// The field: the request as you've edited it.
    var request: String
    /// The composer strip's picks; nil keeps the default (the first installed agent, the settings' mode and model).
    var harness: Harness?
    var mode: PermissionMode?
    var agentModel: String?
    var otherModel: String?
    private let sentContext: AskContext?

    init(project: String, prompt: String, context: AskContext? = nil) {
        self.project = project
        self.prompt = prompt
        self.context = context
        self.request = prompt
        self.sentContext = context
    }

    /// Changed since Forge sent it — leaving it then would lose work.
    var isEdited: Bool {
        request != prompt || context != sentContext || harness != nil || mode != nil || agentModel != nil
            || otherModel != nil
    }
}
