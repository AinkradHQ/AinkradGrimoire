import AinkradAppKit
import SwiftUI
import XCTest

@testable import GrimoireFeature

/// The mockup features built after the parity pass, under Neon (see `Snapshot`). No CLI runs: engines are
/// `FakeEngine`s and nothing reads the clock.
@MainActor
final class MockupFeatureSnapshotTests: XCTestCase {
    /// Mockup 4's "Deny…": the bar asks for an optional reason the agent sees.
    func testDenyAsksForAReason() {
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { FakeEngine() })
        let request = ApprovalRequest(
            id: "r1", toolUseID: "t1", toolName: "Bash", input: ["command": "git push -u origin feat/glass-sidebar"],
            summary: "", suggestions: [])
        Snapshot.assertMatches(
            VStack(spacing: 12) {
                ApprovalBar(request: request, workingDirectory: "/repo", live: live)
                ApprovalBar(request: request, workingDirectory: "/repo", live: live, isDenying: true)
            }, named: "approval-deny", size: CGSize(width: 820, height: 170))
    }

    /// Deny… puts the caret in the reason field: typing goes straight to the agent's reason.
    func testDenyReasonFieldTakesFocus() {
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { FakeEngine() })
        let request = ApprovalRequest(
            id: "r1", toolUseID: "t1", toolName: "Bash", input: ["command": "git push"], summary: "", suggestions: [])
        let (window, _) = Snapshot.host(
            ApprovalBar(request: request, workingDirectory: "/repo", live: live, isDenying: true),
            size: CGSize(width: 820, height: 120))
        defer { window.close() }
        let editor = window.firstResponder as? NSTextView
        XCTAssertTrue(editor?.isFieldEditor == true, "focus is on \(String(describing: window.firstResponder))")
    }

    /// Mockup 1's busy composer: "■ Stop" on its faint red fill, and a lit ↵ that queues the next message.
    func testBusyComposer() {
        let model = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()),
            sessionsRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-none-\(UUID())"))
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            clock: { started }, makeEngine: { FakeEngine() })
        live.send("Make the sidebar glass.")
        XCTAssertTrue(live.canInterrupt)
        Snapshot.assertMatches(
            ThreadFooter(live: live, model: model, workingDirectory: "/repo", harness: .claude), named: "composer-busy",
            size: CGSize(width: 820, height: 150))
    }

    /// Mockup 9 B: no threads yet — the cyan ❖ at 40 pt over both ways in.
    func testNoThreadsEmptyState() {
        let model = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()),
            sessionsRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-none-\(UUID())"))
        model.cli = .found(path: "/usr/bin/true", version: "2.1.296")
        XCTAssertTrue(model.projects.isEmpty)
        Snapshot.assertMatches(MainPane(model: model), named: "empty-no-threads", size: CGSize(width: 820, height: 420))
    }

    /// GP15 (mockup 2): an Edit card numbers its lines where they sit in the file, hunk header included.
    func testEditCardShowsFileLineNumbers() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-edit-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("SidebarRow.swift")
        let before = (1...57).map { "// line \($0)" }
        let edited = [
            "        .padding(.horizontal, skin.size.s8)", "        .background {",
            "            if isSelected { Capsule().glassEffect(.regular) }", "        }",
            "        .contentShape(Rectangle())",
        ]
        try (before + edited + ["}"]).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let input: JSONValue = [
            "file_path": .string(file.path),
            "old_string": "        .padding(.horizontal, skin.size.s8)\n        .overlay(alignment: .bottom) { Rectangle().frame(height: 1) }\n        .contentShape(Rectangle())",
            "new_string": .string(edited.joined(separator: "\n")),
        ]
        Snapshot.assertMatches(
            EditDiffBlock(diff: ToolSummary.editDiff(input), path: file.path).padding(12), named: "edit-line-numbers",
            size: CGSize(width: 640, height: 200))
    }

    /// Mockup 3's composer: image chips with ✕, the strip's Effort and 📎.
    func testComposerWithImageChips() {
        let model = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()),
            sessionsRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-none-\(UUID())"))
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { FakeEngine() })
        live.setEffort("high")
        let image = EngineImage(mediaType: "image/png", base64: "AAA")
        live.attachments = [
            ImageAttachment(name: "sidebar.png", image: image), ImageAttachment(name: "after-glass.png", image: image),
        ]
        live.draft = "The selected row still draws a hairline — see the screenshots."
        Snapshot.assertMatches(
            ThreadFooter(live: live, model: model, workingDirectory: "/repo", harness: .claude), named: "composer-images",
            size: CGSize(width: 820, height: 190))
    }

    /// Mockup 5: a ticked hunk for Revert selected, a line comment waiting for the next message, Send 1 comment.
    func testReviewWithHunkSelectionAndAComment() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-review-\(UUID())")
        let file = dir.appendingPathComponent("Sidebar/SidebarRow.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let new = "        .background {\n            if isSelected { Capsule().glassEffect(.regular) }\n        }"
        try ((1...57).map { "// \($0)" } + ["        .padding(.horizontal, skin.size.s8)", new, "        .contentShape(Rectangle())"])
            .joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let edit = ThreadEntry.tool(
            ToolCall(
                id: "e1", name: "Edit",
                input: [
                    "file_path": .string(file.path),
                    "old_string": "        .overlay(alignment: .bottom) { Rectangle().frame(height: 1) }",
                    "new_string": .string(new),
                ], result: ToolOutput(content: "ok", isError: false)))
        let live = LiveThread(
            entries: [.user("Make the selection a glass capsule."), edit],
            startOptions: EngineStartOptions(workingDirectory: dir), makeEngine: { FakeEngine() })
        let review = ReviewModel(live: live, workingDirectory: dir.path, environment: [:])
        await review.load()
        let hunk = try XCTUnwrap(review.files.first?.diff?.hunks.first)
        XCTAssertEqual(hunk.newStart, 59, "found in the file")
        review.selectedHunks = [HunkKey(path: "Sidebar/SidebarRow.swift", hunk: hunk.id)]
        review.addComment(
            "Use the kit's row background instead of a raw Capsule.", on: "Sidebar/SidebarRow.swift", line: 60,
            quote: "if isSelected { Capsule().glassEffect(.regular) }")
        review.commitMessage = "fix(sidebar): glass capsule selection"
        Snapshot.assertMatches(
            ReviewPane(review: review, close: {}), named: "review-hunks-comment", size: CGSize(width: 440, height: 520))
    }

    /// GD42: a staged rename (`git mv`) reads as one, old path → new path.
    func testReviewListsARename() async throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-rename-\(UUID())")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sidebar"), withIntermediateDirectories: true)
        let environment = CLILocator.loginEnvironment()
        let git = Git(directory: repo.path, environment: environment)
        try "struct Row {}\n".write(to: repo.appendingPathComponent("Sidebar/Row.swift"), atomically: true, encoding: .utf8)
        for step in [["init", "-q"], ["add", "."], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "a"]] {
            _ = try await git.run(step)
        }
        _ = try await git.run(["mv", "Sidebar/Row.swift", "Sidebar/SidebarRow.swift"])
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: repo), makeEngine: { FakeEngine() })
        let review = ReviewModel(live: live, workingDirectory: repo.path, environment: environment)
        review.scope = .uncommitted
        // The pane reloads from git as it appears; awaiting (not the run loop) lets that land.
        let (window, hosting) = Snapshot.host(ReviewPane(review: review, close: {}), size: CGSize(width: 440, height: 300))
        defer { window.close() }
        for _ in 0..<200 where review.isLoading || review.files.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        Snapshot.settleLayout(hosting, for: 0.2)
        XCTAssertEqual(review.files.first?.oldPath, "Sidebar/Row.swift")
        Snapshot.assertMatches(hosted: hosting, named: "review-rename")
    }
}
