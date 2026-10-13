import AinkradAppKit
import SwiftUI
import XCTest

@testable import GrimoireFeature

/// E5 (screen 11): "↗ Forge" on Grep rows, a Read, an Edit header and its diff lines, the review pane's file and
/// "Review in Forge"; and the New Thread sheet arriving from Forge ⌘I with its selection. Snapshots cannot hover,
/// so the pills are revealed by `revealsForgePills`. See `Snapshot`.
@MainActor
final class ForgeLinkSnapshotTests: XCTestCase {
    func testOpenInForgePills() async throws {
        let model = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()),
            sessionsRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-none-\(UUID())"))
        model.engineOverride = { FakeEngine() }
        model.startThread(project: "/tmp/work", prompt: "Where else do we draw the selection stroke?", model: nil, mode: .ask, worktree: false)
        let live = try XCTUnwrap(model.current)
        live.onSessionID = nil
        func tool(_ id: String, _ name: String, _ input: [String: JSONValue], _ result: String) {
            live.apply(.block(messageID: "m", .toolUse(id: id, name: name, input: .object(input))))
            live.apply(.toolResult(toolUseID: id, content: result, isError: false))
        }
        tool(
            "g", "Grep", ["pattern": .string("strokeBorder"), "path": .string("/tmp/work/Sources/Ainkrad/Features")],
            "Sidebar/SidebarRow.swift:59:.overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(skin.accent) }\n"
                + "Sessions/SessionBrowserRow.swift:27:.background(isSelected ? skin.accent : .clear).strokeBorder(…)\n"
                + "Home/HomeTile.swift:88:tile.strokeBorder(skin.stroke, lineWidth: 1)\n")
        tool("r", "Read", ["file_path": .string("/tmp/work/Sources/Sidebar/SidebarRow.swift"), "offset": .number(40)], "40\tlet a = 1\n")
        tool(
            "e", "Edit",
            [
                "file_path": .string("/tmp/work/Sources/Sidebar/SidebarRow.swift"),
                "old_string": .string("        .padding(.horizontal, skin.size.s8)\n        .overlay(alignment: .bottom) { Rectangle().frame(height: 1) }"),
                "new_string": .string(
                    "        .padding(.horizontal, skin.size.s8)\n        .background {\n            if isSelected { Capsule().glassEffect(.regular) }\n        }"),
            ], "ok")
        live.apply(.turnFinished(TurnResult(outcome: .success, sessionID: "s")))
        model.isReviewOpen = true
        let thread = try XCTUnwrap(model.selectedThread)
        await model.review(for: thread)?.load()
        Snapshot.assertMatches(
            ThreadView(model: model, thread: thread).environment(\.revealsForgePills, true), named: "open-in-forge",
            size: CGSize(width: 1260, height: 640))
    }

    func testNewThreadFromForge() {
        let model = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()),
            sessionsRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-none-\(UUID())"))
        model.newThreadPreset = NewThreadPreset(
            project: "/Users/me/Projects/Ainkrad", prompt: "Make the selection capsule animate in with the motion budget",
            context: AskContext(
                project: "/Users/me/Projects/Ainkrad", file: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift", lines: 18...21,
                code: "        .background {\n            if isSelected { Capsule().glassEffect(.regular) }\n        }\n        .contentShape(Rectangle())"))
        Snapshot.assertMatches(
            NewThreadSheet(model: model) {}.padding(20), named: "composer-from-forge", size: CGSize(width: 600, height: 620))
    }
}
