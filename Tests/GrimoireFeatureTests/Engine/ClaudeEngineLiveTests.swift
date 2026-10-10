import Foundation
import Testing

@testable import GrimoireFeature

/// Drives the real `claude` CLI end to end. Off by default — it costs tokens
/// and needs a signed-in CLI. Run with `TEST_RUNNER_GRIMOIRE_LIVE=1 make test`.
@MainActor
@Suite("ClaudeEngine (live)", .enabled(if: ProcessInfo.processInfo.environment["GRIMOIRE_LIVE"] == "1"))
struct ClaudeEngineLiveTests {
    /// Collects an engine's events as they arrive.
    @MainActor final class Recorder {
        private(set) var seen: [EngineEvent] = []
        private var cursor = 0

        init(_ engine: ClaudeEngine) {
            Task { [weak self] in
                for await event in engine.events { self?.seen.append(event) }
            }
        }

        /// The next event (after the last one returned) matching `match`, or nil after `timeout`.
        func next(timeout: Duration = .seconds(120), _ match: (EngineEvent) -> Bool) async -> EngineEvent? {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                while cursor < seen.count {
                    defer { cursor += 1 }
                    if match(seen[cursor]) { return seen[cursor] }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            Issue.record("timed out; events: \(seen.map { String(String(describing: $0).prefix(90)) })")
            return nil
        }
    }

    private func makeEngine() throws -> ClaudeEngine {
        let environment = CLILocator.loginEnvironment()
        let executable = try #require(CLILocator.locate("claude", path: environment["PATH"] ?? ""))
        // Project settings only, so the user's own "always allow" rules cannot
        // skip the approval this test is about.
        return ClaudeEngine(
            executable: executable, environment: environment, extraArguments: ["--setting-sources", "project"])
    }

    private static func isTurnEnd(_ event: EngineEvent) -> Bool {
        if case .turnFinished = event { return true }
        return false
    }

    @Test("approve-always, interrupt, then resume as a fork")
    func session() async throws {
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-live-\(UUID())")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let notes = work.appendingPathComponent("notes.txt")
        try "hello world\n".write(to: notes, atomically: true, encoding: .utf8)

        let engine = try makeEngine()
        let events = Recorder(engine)
        try engine.start(EngineStartOptions(workingDirectory: work, model: "haiku", permissionMode: .ask))

        // 1. An edit asks first; "always" adopts the CLI's suggested rule.
        try engine.send("Use the Edit tool to change 'world' to 'there' in notes.txt. Reply DONE.", images: [])
        guard
            case .approval(let request) = await events.next({
                if case .approval = $0 { true } else { Self.isTurnEnd($0) }
            })
        else {
            Issue.record("no approval asked; saw \(events.seen.suffix(5))")
            return
        }
        #expect(request.toolName == "Edit")
        try engine.answer(request, with: .allowAlways)
        let first = await events.next(Self.isTurnEnd)
        #expect(first.map { if case .turnFinished(let r) = $0 { r.outcome == .success } else { false } } == true)
        #expect(try String(contentsOf: notes, encoding: .utf8) == "hello there\n")

        // 2. The adopted rule holds: the next edit does not ask.
        try engine.send("Use the Edit tool to change 'there' to 'friend' in notes.txt. Reply DONE.", images: [])
        _ = await events.next({ if case .approval = $0 { true } else { Self.isTurnEnd($0) } })
        #expect(!events.seen.contains { if case .approval(let r) = $0 { r.id != request.id } else { false } })
        #expect(try String(contentsOf: notes, encoding: .utf8) == "hello friend\n")

        // 3. Interrupt mid-stream: the turn ends as interrupted, the session lives on.
        try engine.send("Count from 1 to 300, one number per line, nothing else.", images: [])
        _ = await events.next({ if case .textDelta = $0 { true } else { false } })
        try engine.interrupt()
        let interrupted = await events.next(Self.isTurnEnd)
        guard case .turnFinished(let result) = interrupted else { return }
        #expect(result.outcome == .interrupted)
        let sessionID = result.sessionID

        engine.stop()
        let exit = await events.next({ if case .exited = $0 { true } else { false } })
        // Any exit code is fine here (1 after an interrupted turn); what matters
        // is that a requested stop is not reported as an error.
        #expect(exit != nil)
        #expect(!events.seen.contains { if case .error = $0 { true } else { false } })

        // 4. Resume as a fork: a new session id, and it remembers the first.
        let fork = try makeEngine()
        let forkEvents = Recorder(fork)
        try fork.start(EngineStartOptions(workingDirectory: work, model: "haiku", resume: sessionID, fork: true))
        try fork.send("Which word did 'world' become first? One word.", images: [])
        let answer = await forkEvents.next(Self.isTurnEnd)
        let forkSession = forkEvents.seen.compactMap {
            if case .sessionStarted(let info) = $0 { info.sessionID } else { nil }
        }
        #expect(forkSession.first != nil && forkSession.first != sessionID)
        guard case .turnFinished(let forkResult) = answer else { return }
        #expect(forkResult.text?.lowercased().contains("there") == true)
        fork.stop()
    }
}
