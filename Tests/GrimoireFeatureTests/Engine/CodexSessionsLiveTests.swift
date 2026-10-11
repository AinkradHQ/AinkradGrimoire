import Foundation
import Testing

@testable import GrimoireFeature

/// Lists and reads the user's real Codex threads through `codex app-server`.
/// Read-only and token-free, but needs the CLI and stored threads. Run with
/// `TEST_RUNNER_GRIMOIRE_LIVE=1 make test`.
@Suite("CodexSessions (live)", .enabled(if: ProcessInfo.processInfo.environment["GRIMOIRE_LIVE"] == "1"))
struct CodexSessionsLiveTests {
    @Test("lists stored threads and reads one back as a transcript")
    func listAndRead() throws {
        let environment = CLILocator.loginEnvironment()
        let executable = try #require(CLILocator.locate("codex", path: environment["PATH"] ?? ""))
        let threads = CodexSessions.summaries(executable: executable, environment: environment, limit: 20)
        let newest = try #require(threads.first, "no stored Codex threads")
        #expect(threads.allSatisfy { $0.harness == .codex })
        #expect(threads == threads.sorted { $0.lastActivity > $1.lastActivity })
        let listing = CodexSessions.listing(
            status: .found(path: executable.path, version: ""), executable: executable, environment: environment)
        #expect(!listing.models.isEmpty, "model/list offers models")
        #expect(!listing.usage.isEmpty, "account/rateLimits/read reports a window")
        let history = CodexSessions.history(threadID: newest.id, executable: executable, environment: environment)
        #expect(history.contains { if case .user = $0 { true } else { false } })
    }
}
