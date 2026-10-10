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
}
