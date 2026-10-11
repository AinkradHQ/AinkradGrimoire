import Foundation
import Testing

@testable import GrimoireFeature

/// Drives the real `agy`: lists conversations, then runs one short turn in a
/// temporary folder. Off by default — it costs quota and needs a signed-in
/// CLI. Run with `TEST_RUNNER_GRIMOIRE_LIVE=1 make test`.
@MainActor
@Suite("AgyEngine (live)", .enabled(if: ProcessInfo.processInfo.environment["GRIMOIRE_LIVE"] == "1"))
struct AgyEngineLiveTests {
    @Test("lists conversations and finishes a turn")
    func turn() async throws {
        let environment = CLILocator.loginEnvironment()
        let executable = try #require(CLILocator.locate("agy", path: environment["PATH"] ?? ""))
        #expect(AgySessions.summaries(limit: 5).allSatisfy { $0.harness == .agy })
        let models = AgySessions.models(executable: executable, environment: environment)
        // The cheapest listed model, picked by id — the way the model menu sends it.
        let pick = try #require(models.last { $0.id.contains("flash-low") } ?? models.first)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grimoire-agy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = AgyEngine(executable: executable, environment: environment)
        try engine.start(EngineStartOptions(workingDirectory: directory, model: pick.id, permissionMode: .plan))
        try engine.send("Reply with the single word grimoire.", images: [])
        var finished: TurnResult?
        let deadline = ContinuousClock.now + .seconds(120)
        for await event in engine.events {
            if case .turnFinished(let result) = event { finished = result }
            if finished != nil || ContinuousClock.now > deadline { break }
        }
        engine.stop()
        #expect(finished?.outcome == .success)
        #expect(finished?.text?.lowercased().contains("grimoire") == true)
    }
}
