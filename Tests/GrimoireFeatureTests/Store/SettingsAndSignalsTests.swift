import AinkradAppKit
import Foundation
import Testing

@testable import GrimoireFeature

@MainActor
final class RecordingSignals: PluginSignalEmitter {
    private(set) var titles: [String] = []
    private(set) var importances: [SignalImportance] = []

    func emit(
        kind: String, severity: SignalSeverity, title: String, body: String?, importance: SignalImportance,
        deepLink: SignalDeepLink?, actions: [SignalAction], dedupeKey: String?
    ) {
        titles.append(title)
        importances.append(importance)
    }
    func own(limit: Int) -> [SignalEvent] { [] }
    func handleAction(_ actionID: String, _ handler: @escaping @MainActor () async -> Void) -> AgentActionToken {
        AgentActionToken(id: UUID())
    }
    func removeActionHandler(_ token: AgentActionToken) {}
}

@MainActor
@Suite("Settings and signals")
struct SettingsAndSignalsTests {
    @Test("new-thread defaults and the CLI override persist; an older document gets the defaults")
    func settings() {
        let docs = MemoryDocs()
        let store = SettingsStore(documents: docs)
        #expect(store.defaultModel == "opus" && store.defaultMode == .ask && !store.worktreeByDefault)
        #expect(store.notifyWhenNeeded && store.cliPathOverride == nil)
        store.defaultModel = "haiku"
        store.defaultMode = .plan
        store.worktreeByDefault = true
        store.notifyWhenNeeded = false
        store.cliPathOverride = "/opt/claude"
        let reloaded = SettingsStore(documents: docs)
        #expect(reloaded.defaultModel == "haiku" && reloaded.defaultMode == .plan && reloaded.worktreeByDefault)
        #expect(!reloaded.notifyWhenNeeded && reloaded.cliPathOverride == "/opt/claude")

        let old = MemoryDocs()
        old.storage[SettingsStore.key] = Data(#"{"openedFolders":["/a"]}"#.utf8)
        let upgraded = SettingsStore(documents: old)
        #expect(upgraded.openedFolders == ["/a"] && upgraded.defaultModel == "opus" && upgraded.notifyWhenNeeded)
    }

    @Test("the recorded rate-limit event becomes usage windows")
    func usage() throws {
        let line =
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.22,"resetsAt":1791939600},"five_hour":{"utilization":0.17,"resetsAt":1791652200}}}}"#
        var wire = ClaudeProtocol()
        guard case .usage(let windows) = try #require(wire.decode(line).first) else {
            Issue.record("not a usage event")
            return
        }
        #expect(windows.map(\.name) == ["5-hour", "7-day"])
        #expect(windows.first?.utilization == 0.17)
        #expect(windows.first?.resetsAt == Date(timeIntervalSince1970: 1_791_652_200))
    }

    @Test("a thread you aren't looking at posts an urgent Signal when it needs you; the one you're on doesn't")
    func needsYou() {
        let signals = RecordingSignals()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-sig-\(UUID())")
        let model = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root, signals: signals)
        model.engineOverride = { FakeEngine() }
        model.startThread(project: "/w", prompt: "first", model: nil, mode: .ask, worktree: false)
        let first = model.current
        model.startThread(project: "/w", prompt: "second", model: nil, mode: .ask, worktree: false)
        let request = ApprovalRequest(
            id: "r", toolUseID: "t", toolName: "Bash", input: ["command": "ls"], summary: "", suggestions: [])

        first?.apply(.approval(request))
        #expect(signals.titles == ["Grimoire needs you in first"])
        #expect(signals.importances == [.urgent])

        model.settings.notifyWhenNeeded = false
        first?.apply(.approval(request))
        #expect(signals.titles.count == 1, "turned off in Settings")
    }

    @Test("usage reported by any thread reaches the model")
    func usageReachesModel() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-use-\(UUID())")
        let model = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        model.engineOverride = { FakeEngine() }
        model.startThread(project: "/w", prompt: "go", model: nil, mode: .ask, worktree: false)
        model.current?.apply(.usage([UsageWindow(name: "5-hour", utilization: 0.5, resetsAt: nil)]))
        #expect(model.usage[.claude]?.first?.utilization == 0.5)
    }
}
