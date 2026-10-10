import AinkradAppKit
import Foundation
import Testing

@testable import GrimoireFeature

@MainActor
final class RecordingLauncher: PluginAppLauncher, PluginAppLauncherResult {
    var outcome: PluginLaunchOutcome = .opened
    private(set) var opened: [(appID: String, payload: String?)] = []

    func open(appID: String, payload: String?) { opened.append((appID, payload)) }
    func takePendingLaunch() -> String? { nil }
    func openReportingOutcome(appID: String, payload: String?) -> PluginLaunchOutcome {
        opened.append((appID, payload))
        return outcome
    }
}

@MainActor
@Suite("Terminal")
struct TerminalTests {
    private func thread(_ cwd: String) -> ClaudeSessionSummary {
        ClaudeSessionSummary(
            id: "s", fileURL: URL(fileURLWithPath: "/x"), workingDirectory: cwd, projectPath: "/repo", title: "t",
            lastActivity: .distantPast)
    }

    @Test("the terminal button asks Rune for a shell in the thread's folder (its worktree, if any)")
    func opensRune() throws {
        let launcher = RecordingLauncher()
        let model = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), apps: launcher)
        model.openTerminal(for: thread("/repo/.claude/worktrees/fix-ci"))
        let launch = try #require(launcher.opened.first)
        #expect(launch.appID == "rune")
        let intent = try #require(AinkradLaunchIntent.decode(launch.payload))
        #expect(intent.kind == "openDirectory")
        #expect(intent.path == "/repo/.claude/worktrees/fix-ci")
        #expect(model.terminalProblem == nil)
    }

    @Test("a missing or disabled Rune says what to do")
    func problems() {
        let launcher = RecordingLauncher()
        let model = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), apps: launcher)
        launcher.outcome = .unknownApp("rune")
        model.openTerminal(for: thread("/repo"))
        #expect(model.terminalProblem?.contains("Install Rune") == true)
        launcher.outcome = .disabled("rune")
        model.openTerminal(for: thread("/repo"))
        #expect(model.terminalProblem?.contains("turned off") == true)
        launcher.outcome = .opened
        model.openTerminal(for: thread("/repo"))
        #expect(model.terminalProblem == nil)
    }
}
