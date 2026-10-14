import AppKit
import SwiftUI
import XCTest

@testable import GrimoireFeature

/// GD41: a reply streaming in follows the reader only while they are at the bottom. Off-screen (see `Snapshot`):
/// the conversation's own `NSScrollView` is scrolled as a reader would, then deltas arrive.
@MainActor
final class ConversationScrollTests: XCTestCase {
    private func makeLive() -> LiveThread {
        let entries: [ThreadEntry] = (0..<40).flatMap { index in
            [.user("Question \(index)"), .text(String(repeating: "Answer \(index), at some length. ", count: 12))]
        }
        return LiveThread(
            entries: entries, startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/tmp")),
            makeEngine: { FakeEngine() })
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    /// Scrolls as a reader does, with the wheel (positive is up), a step at a time.
    private func wheel(_ scroll: NSScrollView, by points: Int32, settling view: NSView) {
        for _ in 0..<20 {
            guard
                let cg = CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: points / 20, wheel2: 0,
                    wheel3: 0), let event = NSEvent(cgEvent: cg)
            else { return XCTFail("no scroll event") }
            scroll.scrollWheel(with: event)
            Snapshot.settleLayout(view, for: 0.02)
        }
        Snapshot.settleLayout(view, for: 0.2)
    }

    /// The bottom of the document, where a reader following the reply sits.
    private func bottom(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
    }

    private func stream(_ live: LiveThread, deltas: Int, settling view: NSView) {
        for _ in 0..<deltas {
            live.apply(.textDelta(messageID: "m1", text: "More of the reply, streaming in as the agent writes. "))
            Snapshot.settleLayout(view, for: 0.02)
        }
    }

    func testReaderScrolledUpKeepsTheirPlace() throws {
        let live = makeLive()
        let (window, hosting) = Snapshot.host(
            ConversationView(live: live, workingDirectory: "/tmp") { EmptyView() }, size: CGSize(width: 700, height: 500))
        defer { window.close() }
        let scroll = try XCTUnwrap(scrollView(in: hosting))
        wheel(scroll, by: 20_000, settling: hosting)
        stream(live, deltas: 30, settling: hosting)
        XCTAssertLessThan(scroll.contentView.bounds.origin.y, 40, "a reader scrolled up was pulled to the bottom")
        // "Jump to latest" waits at the bottom right.
        Snapshot.assertMatches(hosted: hosting, named: "thread-scrolled-up")
    }

    func testReaderAtTheBottomFollowsTheReply() throws {
        let live = makeLive()
        let (window, hosting) = Snapshot.host(
            ConversationView(live: live, workingDirectory: "/tmp") { EmptyView() }, size: CGSize(width: 700, height: 500))
        defer { window.close() }
        let scroll = try XCTUnwrap(scrollView(in: hosting))
        wheel(scroll, by: -20_000, settling: hosting)
        stream(live, deltas: 30, settling: hosting)
        Snapshot.settleLayout(hosting, for: 0.2)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, bottom(scroll) - 40, "the reply ran off the bottom")
    }
}
