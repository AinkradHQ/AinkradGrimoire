import Foundation
import Testing

@testable import GrimoireFeature

/// Drives the real `opencode` end to end: lists sessions, then runs one turn
/// that needs an approval. Off by default — it costs tokens and needs a
/// signed-in provider (`google/gemini-2.5-flash`). Run with
/// `TEST_RUNNER_GRIMOIRE_LIVE=1 make test`. The session it makes is deleted.
@MainActor
@Suite("OpenCodeEngine (live)", .enabled(if: ProcessInfo.processInfo.environment["GRIMOIRE_LIVE"] == "1"))
struct OpenCodeEngineLiveTests {
    @Test("lists sessions, asks before running a command, finishes the turn")
    func turn() async throws {
        let environment = CLILocator.loginEnvironment()
        let executable = try #require(CLILocator.locate("opencode", path: environment["PATH"] ?? ""))
        let server = OpenCodeServer(executable: executable, environment: environment)
        defer { server.stop() }
        let listed = await OpenCodeSessions.summaries(server: server, limit: 5)
        #expect(listed.allSatisfy { $0.harness == .opencode })
        let models = await OpenCodeSessions.models(server: server, recent: listed)
        #expect(models.contains { $0.id.contains("/") }, "provider defaults come back as provider/model")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grimoire-oc-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = OpenCodeEngine(server: server)
        try engine.start(
            EngineStartOptions(workingDirectory: directory, model: "google/gemini-2.5-flash", permissionMode: .ask))
        try engine.send("Run the shell command `echo grimoire` and reply with its output only.", images: [])

        var session: String?
        var finished: TurnResult?
        let deadline = ContinuousClock.now + .seconds(120)
        for await event in engine.events {
            switch event {
            case .sessionStarted(let info): session = info.sessionID
            case .approval(let request):
                #expect(request.toolName == "Bash")
                try engine.answer(request, with: .allow)
            case .turnFinished(let result): finished = result
            default: break
            }
            if finished != nil || ContinuousClock.now > deadline { break }
        }
        engine.stop()
        if let session { _ = try? await server.call("DELETE", "/session/\(session)", directory: directory.path) }
        #expect(finished?.outcome == .success)
    }
}
