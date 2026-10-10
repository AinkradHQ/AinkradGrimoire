import Foundation
import Testing

@testable import GrimoireFeature

@MainActor
@Suite("New thread")
struct NewThreadTests {
    @Test("a new thread opens at once as a draft, then takes the id the CLI gives it")
    func startAndAdopt() async throws {
        let engine = FakeEngine()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-new-\(UUID())")
        let model = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        model.engineOverride = { engine }

        model.startThread(
            project: "/work/app", prompt: "Fix the login bug", model: "sonnet", mode: .plan, worktree: true)

        let placeholder = try #require(model.selectedThreadID)
        #expect(placeholder.hasPrefix("new-"))
        #expect(model.current != nil)
        #expect(model.projects.first?.path == "/work/app")
        #expect(model.projects.first?.sessions.first?.title == "Fix the login bug")
        #expect(engine.sent == ["Fix the login bug"])
        #expect(engine.started?.model == "sonnet")
        #expect(engine.started?.permissionMode == .plan)
        #expect(engine.started?.worktree?.hasPrefix("fix-the-login-bug-") == true)
        #expect(engine.started?.resume == nil)

        model.current?.apply(
            .sessionStarted(
                SessionInfo(
                    sessionID: "s-real", model: "claude-sonnet-5-5", permissionMode: .plan,
                    workingDirectory: "/work/app", tools: [])))
        #expect(model.selectedThreadID == "s-real")
        #expect(model.liveThreads["s-real"] != nil)
        #expect(model.liveThreads[placeholder] == nil)
        #expect(model.selectedThread?.id == "s-real")
        // The draft stays listed until the CLI's own file appears in a reload.
        #expect(model.draftThreads.map(\.id) == ["s-real"])
    }

    @Test("worktree names are branch-safe slugs of the prompt")
    func worktreeNames() {
        #expect(GrimoireModel.worktreeName(for: "Fix the login bug!", suffix: "ab12") == "fix-the-login-bug-ab12")
        #expect(GrimoireModel.worktreeName(for: "  ¿¿ ", suffix: "ab12") == "thread-ab12")
        #expect(
            GrimoireModel.worktreeName(for: "one two three four five six seven", suffix: "x")
                == "one-two-three-four-five-x")
    }

    @Test("drafts go on top of their project, or start a project of their own")
    func drafts() {
        let existing = ClaudeProject(
            path: "/a",
            sessions: [
                ClaudeSessionSummary(
                    id: "old", fileURL: URL(fileURLWithPath: "/x"), workingDirectory: "/a", projectPath: "/a",
                    title: "Old",
                    lastActivity: .distantPast)
            ])
        func draft(_ id: String, _ path: String) -> ClaudeSessionSummary {
            ClaudeSessionSummary(
                id: id, fileURL: URL(fileURLWithPath: "/dev/null"), workingDirectory: path, projectPath: path,
                title: id,
                lastActivity: Date())
        }
        let merged = GrimoireModel.adding([draft("n1", "/a"), draft("n2", "/b")], to: [existing])
        #expect(merged.map(\.path) == ["/b", "/a"])
        #expect(merged.last?.sessions.map(\.id) == ["n1", "old"])
    }
}
