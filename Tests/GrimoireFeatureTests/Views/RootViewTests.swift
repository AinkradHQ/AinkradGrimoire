import AinkradAppKit
import Foundation
import SwiftUI
import Testing

@testable import GrimoireFeature

/// The window builds from a fake host and draws. It renders to pixels instead
/// of inspecting the view tree, so it needs no extra dependency.
@MainActor
@Suite("Root view")
struct RootViewTests {
    @Test func rendersTheWindow() throws {
        let renderer = ImageRenderer(content: GrimoireApp.makeRootView(host: FakeHost()).frame(width: 900, height: 600))
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the root view did not render")
        #expect(image.width == 900)
    }
}

@MainActor
@Suite("Sidebar")
struct SidebarModelTests {
    private func project(_ path: String, _ titles: [String]) -> ClaudeProject {
        ClaudeProject(
            path: path,
            sessions: titles.enumerated().map { index, title in
                ClaudeSessionSummary(
                    id: "\(path)-\(index)", fileURL: URL(fileURLWithPath: "/x"), workingDirectory: path,
                    projectPath: path, title: title, lastActivity: .distantPast)
            })
    }

    @Test("a search that hides everything says so (GD20)")
    func noMatches() {
        let projects = [project("/w/Ainkrad", ["Glass sidebar"])]
        #expect(Sidebar.noMatchTitle(query: " zzz ", visible: []) == "No threads match “zzz”")
        #expect(Sidebar.noMatchTitle(query: "glass", visible: projects) == nil)
        #expect(Sidebar.noMatchTitle(query: "", visible: []) == nil, "no search: the sidebar's own empty state")
    }

    @Test("search keeps matching threads, or a whole project when its name matches")
    func search() {
        let projects = [project("/w/Ainkrad", ["Glass sidebar", "Release"]), project("/w/GitScope", ["Glass tabs"])]
        #expect(GrimoireModel.filter(projects, query: "").count == 2)
        let glass = GrimoireModel.filter(projects, query: "glass")
        #expect(glass.map(\.path) == ["/w/Ainkrad", "/w/GitScope"])
        #expect(glass.first?.sessions.map(\.title) == ["Glass sidebar"])
        #expect(GrimoireModel.filter(projects, query: "gitscope").first?.sessions.count == 1)
        #expect(GrimoireModel.filter(projects, query: "nothing").isEmpty)
    }

    @Test("opened folders without sessions are listed after the rest, once")
    func merge() {
        let merged = GrimoireModel.merge([project("/a", ["t"])], openedFolders: ["/a", "/new"])
        #expect(merged.map(\.path) == ["/a", "/new"])
        #expect(merged.last?.sessions.isEmpty == true)
    }

    @Test("the 10 most recent projects show until 'Show all'; searching shows every match")
    func recentLimit() async {
        let model = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: emptyRoot())
        for index in 0..<13 { model.openFolder(URL(fileURLWithPath: "/p\(index)")) }
        #expect(model.visibleProjects.count == 10)
        #expect(model.hiddenProjectCount == 3)
        model.searchText = "p1"
        #expect(model.visibleProjects.map(\.path) == ["/p1", "/p10", "/p11", "/p12"])
        #expect(model.hiddenProjectCount == 0)
        model.searchText = ""
        model.showsAllProjects = true
        #expect(model.visibleProjects.count == 13)
    }

    @Test("GD17: next/previous thread walks sidebar order, skips collapsed projects, and clamps at both ends")
    func adjacentThread() {
        let projects = [project("/a", ["a0", "a1"]), project("/b", ["b0"]), project("/c", ["c0", "c1"])]
        let open: (ClaudeProject) -> Bool = { $0.path != "/b" }
        func step(_ offset: Int, from selected: String?) -> String? {
            GrimoireModel.adjacentThread(offset, from: selected, in: projects, isExpanded: open)
        }
        #expect(step(1, from: "/a-0") == "/a-1")
        #expect(step(1, from: "/a-1") == "/c-0")  // across the collapsed /b
        #expect(step(-1, from: "/c-0") == "/a-1")
        #expect(step(1, from: "/c-1") == "/c-1")  // last: stays
        #expect(step(-1, from: "/a-0") == "/a-0")  // first: stays
        #expect(step(1, from: nil) == "/a-0")
        #expect(step(-1, from: nil) == "/c-1")
        #expect(step(1, from: "/b-0") == "/a-0")  // hidden selection starts over
        #expect(GrimoireModel.adjacentThread(1, from: nil, in: [], isExpanded: open) == nil)
    }

    private func emptyRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-empty-\(UUID())")
    }

    @Test("relative times are compact")
    func relativeTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(RelativeTime.short(now.addingTimeInterval(-20), now: now, calendar: calendar) == "now")
        #expect(RelativeTime.short(now.addingTimeInterval(-4 * 60), now: now, calendar: calendar) == "4m")
        #expect(RelativeTime.short(now.addingTimeInterval(-3 * 3_600), now: now, calendar: calendar) == "3h")
        #expect(RelativeTime.short(now.addingTimeInterval(-24 * 3_600), now: now, calendar: calendar) == "yesterday")
        #expect(RelativeTime.short(now.addingTimeInterval(-9 * 86_400), now: now, calendar: calendar) != "yesterday")
    }

    @Test("model ids read as names")
    func modelNames() {
        #expect(ModelName.display("claude-opus-5-5") == "opus 5.5")
        #expect(ModelName.display("claude-haiku-5-5") == "haiku 5.5")
        #expect(ModelName.display("gpt-5") == "gpt 5")
        #expect(ModelName.display("sonnet") == "sonnet")
    }

    @Test("each agent's resume command; none for a draft (GD21)")
    func resumeCommands() {
        func thread(_ harness: Harness, id: String = "abc") -> ClaudeSessionSummary {
            ClaudeSessionSummary(
                id: id, harness: harness, fileURL: URL(fileURLWithPath: "/dev/null"), workingDirectory: "/p/it's",
                projectPath: "/p", worktree: nil, title: "t", model: nil, lastActivity: Date())
        }
        #expect(ThreadView.resumeCommand(for: thread(.claude)) == #"cd '/p/it'\''s' && claude --resume abc"#)
        #expect(ThreadView.resumeCommand(for: thread(.codex))?.hasSuffix("&& codex resume abc") == true)
        #expect(ThreadView.resumeCommand(for: thread(.opencode))?.hasSuffix("&& opencode --session abc") == true)
        #expect(ThreadView.resumeCommand(for: thread(.agy))?.hasSuffix("&& agy --conversation abc") == true)
        #expect(ThreadView.resumeCommand(for: thread(.codex, id: "new-1")) == nil)
    }
}
