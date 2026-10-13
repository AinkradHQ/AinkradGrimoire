import AinkradAppKit
import SwiftUI
import XCTest

@testable import GrimoireFeature

/// The mockup features built after the parity pass, under Neon (see `Snapshot`). No CLI runs: engines are
/// `FakeEngine`s and nothing reads the clock.
@MainActor
final class MockupFeatureSnapshotTests: XCTestCase {
    /// Mockup 4's "Deny…": the bar asks for an optional reason the agent sees.
    func testDenyAsksForAReason() {
        let live = LiveThread(
            entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
            makeEngine: { FakeEngine() })
        let request = ApprovalRequest(
            id: "r1", toolUseID: "t1", toolName: "Bash", input: ["command": "git push -u origin feat/glass-sidebar"],
            summary: "", suggestions: [])
        Snapshot.assertMatches(
            VStack(spacing: 12) {
                ApprovalBar(request: request, workingDirectory: "/repo", live: live)
                ApprovalBar(request: request, workingDirectory: "/repo", live: live, isDenying: true)
            }, named: "approval-deny", size: CGSize(width: 820, height: 170))
    }
}
