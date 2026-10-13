import AinkradAppKit
import Foundation
import Testing

@testable import GrimoireFeature

/// E5: what Grimoire tells Forge (turn notices, Open / Review in Forge) and what it reads from Forge.
@MainActor
@Suite("Forge link")
struct ForgeLinkTests {
    private func object(_ json: String?) throws -> [String: Any] {
        let text = try #require(json)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func grepLinesAndEditsFindTheirPlace() {
        let hit = FileLocation.grepHit("Sources/Sidebar/SidebarRow.swift:59:    .overlay { stroke: a:b }")
        #expect(hit?.location == FileLocation(path: "Sources/Sidebar/SidebarRow.swift", line: 59))
        #expect(hit?.text == "    .overlay { stroke: a:b }")
        #expect(FileLocation.grepHit("Sources/a.swift") == nil)  // files_with_matches
        #expect(FileLocation.grepHit("Sources/a.swift-12-context") == nil)
        #expect(FileLocation.grepHit("--") == nil)
        #expect(FileLocation.grepHit("a.swift:x:text") == nil)
        #expect(GrepHits.parse("a.swift:1:x\nb.swift:2:y\n")?.count == 2)
        #expect(GrepHits.parse("a.swift\nb.swift\n") == nil)

        let file = "import A\n\nstruct Row {\n    var body: some View {\n        Text(\"x\")\n    }\n}\n"
        #expect(FileLocation.line(of: ["    var body: some View {", "        Text(\"x\")"], in: file) == 4)
        // Leading blank lines in the edit still land on its first real line's place, less the blanks.
        #expect(FileLocation.line(of: ["", "struct Row {"], in: file) == 2)
        #expect(FileLocation.line(of: ["not there"], in: file) == nil)
    }

    @Test func anEditIsNumberedWhereItSitsInTheFile() {
        let input: JSONValue = [
            "file_path": "/r/a.swift", "old_string": "b\nold\nc", "new_string": "b\nnew1\nnew2\nc",
        ]
        let diff = ToolSummary.editDiff(input)
        let applied = "a\na\na\nb\nnew1\nnew2\nc\nd\n"
        let located = diff.located(in: applied)?.hunks.first
        #expect(located?.newStart == 4 && located?.oldStart == 4)
        // Waiting for approval: the old side is still in the file.
        #expect(diff.located(in: "x\nb\nold\nc\n")?.hunks.first?.oldStart == 2)
        #expect(diff.located(in: "nothing like it\n") == nil, "falls back to the snippet")
    }

    @Test func aTurnNoticeNamesTheFilesItsEditsWrote() throws {
        let edit = JSONValue.object([
            "file_path": .string("/r/Sources/a.swift"), "old_string": .string("a"), "new_string": .string("b"),
        ])
        let write = JSONValue.object(["file_path": .string("CHANGELOG.md"), "content": .string("x\n")])
        let entries: [ThreadEntry] = [
            .user("first"), .tool(ToolCall(id: "0", name: "Edit", input: edit, result: ToolOutput(content: "ok", isError: false))),
            .user("Make the capsule animate"),
            .tool(ToolCall(id: "1", name: "Edit", input: edit, result: ToolOutput(content: "ok", isError: false))),
            .tool(ToolCall(id: "2", name: "Write", input: write, result: ToolOutput(content: "ok", isError: false))),
            .tool(ToolCall(id: "3", name: "Read", input: write, result: ToolOutput(content: "x", isError: false))),
        ]
        let notice = try object(
            ForgeLink.turnNotice(
                entries: entries, root: "/r", thread: "s1", agent: "Claude", startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 20)))
        #expect(notice["kind"] as? String == "agentTurn")
        #expect(notice["turn"] as? Int == 2)
        #expect(notice["prompt"] as? String == "Make the capsule animate")
        #expect(notice["files"] as? [String] == ["/r/Sources/a.swift", "/r/CHANGELOG.md"])
        #expect(notice["thread"] as? String == "s1" && notice["agent"] as? String == "Claude")
        #expect(notice["startedAt"] as? Double == 10 && notice["endedAt"] as? Double == 20)
        // A turn that wrote nothing tells Forge nothing.
        #expect(ForgeLink.turnNotice(entries: [.user("hi"), .text("hello")], root: "/r", thread: "s1", agent: "Claude", startedAt: Date(), endedAt: Date()) == nil)
    }

    @Test func openingInForgeIsAnOpenDocumentForTheHostToFocusForge() throws {
        let open = try object(ForgeLink.openPayload(path: "/r/a.swift", line: 59))
        #expect(open["kind"] as? String == "openDocument" && open["path"] as? String == "/r/a.swift" && open["line"] as? Int == 59)
        #expect(AinkradLaunchIntent.decode(ForgeLink.openPayload(path: "/r/a.swift", line: 59))?.isOpenDocument == true)
        let review = try object(ForgeLink.openPayload(path: "/r", review: true))
        #expect(review["review"] as? Bool == true && review["line"] == nil)
        #expect(ForgeLink.absolute("a.swift", in: "/r") == "/r/a.swift" && ForgeLink.absolute("/x/a.swift", in: "/r") == "/x/a.swift")
    }

    @Test func anAskFromForgeArrivesInlineWithItsSelectionAndNeverSends() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-forge-\(UUID().uuidString.prefix(8))")
        let model = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        model.isComposingNewThread = true
        model.isShowingSettings = true
        model.handleLaunch(
            #"{"kind":"openDocument","path":"/p","prompt":"In a.swift, lines 18–19:…","request":"Animate it","file":"Sources/a.swift","lines":[18,19],"code":"x\ny"}"#
        )
        // Inline in the main pane, not the New Thread sheet; nothing else covers it.
        #expect(!model.isComposingNewThread && !model.isShowingSettings && model.selectedThreadID == nil)
        #expect(model.projects.contains { $0.path == "/p" })
        let context = AskContext(project: "/p", file: "Sources/a.swift", lines: 18...19, code: "x\ny")
        #expect(model.forgeAsk == ForgeAsk(project: "/p", prompt: "Animate it", context: context))
        #expect(context.label == "a.swift · lines 18–19 · 2 lines")
        #expect(context.numbered == "18\tx\n19\ty")
        #expect(context.message("Animate it") == "In Sources/a.swift, lines 18–19:\n\n```swift\nx\ny\n```\n\nAnimate it")
        #expect(model.current == nil)  // nothing started

        // An older Forge's askAgent (no parts) arrives the same way, its whole prompt in the field.
        model.handleLaunch(#"{"kind":"askAgent","path":"/p","prompt":"Explain this"}"#)
        #expect(model.forgeAsk == ForgeAsk(project: "/p", prompt: "Explain this", context: nil))
        // Opening a thread leaves the ask (the header's ✕ clears it the same way; Esc does not).
        model.selectedThreadID = "s1"
        #expect(model.forgeAsk == nil)

        // A plain openDocument (no request) is not an ask.
        #expect(AskLaunch.decode(AinkradLaunchIntent(path: "/p").json) == nil)
    }

    @Test func aTurnEndingTellsForgeAndAFollowUpFromForgeContinuesTheThread() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-forge-\(UUID().uuidString.prefix(8))")
        let model = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        let engine = FakeEngine()
        model.engineOverride = { engine }
        let notices = Notices()
        let observer = NotificationCenter.default.addObserver(forName: ForgeLink.turnNotification, object: nil, queue: nil) {
            if let notice = $0.object as? String { notices.items.append(notice) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.startThread(project: "/work/app", prompt: "Fix it", model: nil, mode: .ask, worktree: false)
        let live = try #require(model.current)
        live.apply(.sessionStarted(SessionInfo(sessionID: "s9", model: "m", permissionMode: .ask, workingDirectory: "/work/app", tools: [])))
        live.apply(.block(messageID: "m1", .toolUse(id: "e1", name: "Write", input: .object(["file_path": .string("/work/app/a.txt"), "content": .string("x")]))))
        live.apply(.toolResult(toolUseID: "e1", content: "ok", isError: false))
        live.apply(.turnFinished(TurnResult(outcome: .success, sessionID: "s9")))
        let notice = try object(notices.items.last)
        #expect(notice["thread"] as? String == "s9" && notice["turn"] as? Int == 1 && notice["root"] as? String == "/work/app")
        #expect(notice["files"] as? [String] == ["/work/app/a.txt"])

        // Forge's "Ask about this turn…": the same thread, sent.
        model.handleLaunch(#"{"kind":"openDocument","path":"/work/app","prompt":"Use the motion token","thread":"s9"}"#)
        for _ in 0..<50 where engine.sent.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(engine.sent == ["Fix it", "Use the motion token"])
        #expect(model.selectedThreadID == "s9" && !model.isComposingNewThread)
    }
}

/// Turn notices as they were posted (synchronously, on the posting thread).
private final class Notices: @unchecked Sendable {
    var items: [String] = []
}
