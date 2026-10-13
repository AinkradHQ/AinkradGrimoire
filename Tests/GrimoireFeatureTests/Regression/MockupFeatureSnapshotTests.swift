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
}
