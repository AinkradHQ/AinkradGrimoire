import Foundation
import Testing

@testable import GrimoireFeature

/// Reasoning effort, as each CLI takes it. No CLI runs: the wire formats are pure.
@Suite("Effort")
struct EffortTests {
    private let options = EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo"), effort: "high")

    @Test("Claude: --effort at spawn, apply_flag_settings mid-session")
    func claude() {
        let arguments = ClaudeProtocol.arguments(for: options)
        #expect(arguments.firstIndex(of: "--effort").map { arguments[$0 + 1] } == "high")
        var wire = ClaudeProtocol()
        let request = wire.control(.effort("xhigh"))["request"]
        #expect(request?["subtype"] == "apply_flag_settings")
        #expect(request?["settings"]?["effortLevel"] == "xhigh")
    }

    @Test("Codex: each turn/start carries the effort")
    func codex() {
        var wire = CodexProtocol()
        _ = wire.startThread(options)
        _ = wire.decode(#"{"id":1,"result":{"thread":{"id":"t1","cwd":"/repo"},"model":"m","cwd":"/repo"}}"#)
        #expect(wire.turn("go", images: [])?["params"]?["effort"] == "high")
        wire.effort = "low"
        #expect(wire.turn("go", images: [])?["params"]?["effort"] == "low")
    }

    @Test("OpenCode: the prompt's variant")
    func openCode() {
        var wire = OpenCodeProtocol()
        #expect(wire.prompt("go", images: [])["variant"] == nil)
        wire.effort = "max"
        #expect(wire.prompt("go", images: [])["variant"] == "max")
    }

    @Test("agy: --effort at spawn, before -p=")
    func agy() {
        var wire = AgyProtocol()
        wire.effort = "medium"
        #expect(wire.arguments().suffix(3) == ["--effort", "medium", "-p="])
    }

    @MainActor
    @Test("a thread's effort goes to its running agent, and to the next one it starts")
    func liveThread() {
        let engine = FakeEngine()
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { engine })
        live.setEffort("low")
        live.ensureStarted()
        #expect(engine.started?.effort == "low")
        live.setEffort("high")
        #expect(engine.efforts == ["high"])
        #expect(live.effort == "high")
        #expect(Effort.title(nil) == "Default" && Effort.title("xhigh") == "Extra high" && Effort.title("high") == "High")
    }
}
