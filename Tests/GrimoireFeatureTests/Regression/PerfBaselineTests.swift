import AinkradAppKit
import AppKit
import SwiftUI
import XCTest

@testable import GrimoireFeature

/// Baselines with generous bounds: they catch a regression by an order of
/// magnitude, not noise. Measured numbers are printed as `PERF …` lines.
@MainActor
final class PerfBaselineTests: XCTestCase {
    /// Recorded turns through each harness's parser and into a thread, over and
    /// over: the events per second a busy agent could stream before Grimoire falls behind.
    func testStreamingThroughput() throws {
        let fixtures = try [
            ("claude-edit-model", Harness.claude), ("opencode-turn", .opencode), ("agy-turn", .agy),
        ].map { (try FixtureReplay.lines($0.0), $0.1) }
        let passes = 30
        var count = 0
        var parsing: [Harness: Duration] = [:]
        var applying = Duration.zero
        let clock = ContinuousClock()
        for _ in 0..<passes {
            let live = LiveThread(
                entries: [], startOptions: EngineStartOptions(workingDirectory: URL(fileURLWithPath: "/repo")),
                makeEngine: { FakeEngine() })
            live.ensureStarted()
            for (lines, harness) in fixtures {
                var events: [EngineEvent] = []
                parsing[harness, default: .zero] += clock.measure { events = Self.decode(lines, harness) }
                applying += clock.measure {
                    for event in events {
                        live.apply(event)
                        if case .approval = event { live.answer(.allow) }
                    }
                }
                count += events.count
            }
        }
        let parsed = parsing.values.reduce(.zero, +)
        let rate = Double(count) / Self.seconds(parsed + applying)
        let perHarness = parsing.map { "\($0.key.displayName) \($0.value)" }.sorted().joined(separator: ", ")
        print(
            "PERF streaming: \(count) events, parse \(parsed) (\(perHarness)), apply \(applying) = \(Int(rate)) events/s"
        )
        XCTAssertGreaterThan(rate, 200, "parser + thread fell below 200 events/s")
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func decode(_ lines: [String], _ harness: Harness) -> [EngineEvent] {
        switch harness {
        case .claude:
            var wire = ClaudeProtocol()
            return lines.filter { $0.hasPrefix("<") }.flatMap { wire.decode(String($0.dropFirst(2))) }
        case .opencode:
            var wire = OpenCodeProtocol()
            wire.sessionID = FixtureReplay.openCodeSession
            return lines.flatMap { line in (try? JSONValue.parse(line)).map { wire.decode($0) } ?? [] }
        case .agy:
            var wire = AgyProtocol()
            return lines.flatMap { wire.decode($0) }
        case .codex:
            return []
        }
    }

    /// A long stored thread (the glass sweep's conversation, repeated to 500+
    /// messages): opening it, its first draw, and scrolling it top to bottom.
    func testLongThreadRenderAndScroll() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-long-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/me/Projects/Ainkrad"
        let directory = root.appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = Array(repeating: SampleSessions.conversation(cwd: cwd, branch: "development"), count: 56).flatMap {
            $0
        }
        try (lines + [#"{"type":"ai-title","aiTitle":"Long thread","sessionId":"long"}"#]).joined(separator: "\n")
            .write(to: directory.appendingPathComponent("long.jsonl"), atomically: true, encoding: .utf8)

        let settings = SettingsStore(documents: MemoryDocs())
        settings.cliPathOverride = "/usr/bin/true"
        let model = GrimoireModel(settings: settings, sessionsRoot: root)
        XCTAssertTrue(model.listers.isEmpty)
        await model.reload()
        let clock = ContinuousClock()
        let opened = clock.now
        model.selectedThreadID = "long"
        while model.current == nil, opened.duration(to: clock.now) < .seconds(20) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let open = opened.duration(to: clock.now)
        let live = try XCTUnwrap(model.current)
        let thread = try XCTUnwrap(model.selectedThread)
        XCTAssertGreaterThanOrEqual(live.entries.count, 500)

        let size = CGSize(width: 820, height: 640)
        var hosted: (NSWindow, NSView)?
        let firstDraw = clock.measure {
            hosted = Snapshot.host(ThreadView(model: model, thread: thread), size: size, settle: 0)
            _ = hosted.map { Snapshot.capture($0.1) }
        }
        let (window, hosting) = try XCTUnwrap(hosted)
        defer { window.close() }
        let scroller = try XCTUnwrap(Self.scrollView(in: hosting), "no scroll view in the thread")
        let clip = scroller.contentView
        let height = scroller.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(height, size.height * 5, "the thread should be many screens tall")

        let steps = 40
        var tops: [CGFloat] = []
        let scroll = clock.measure {
            for step in 0...steps {
                let maxY = max((scroller.documentView?.frame.height ?? 0) - clip.bounds.height, 0)
                clip.scroll(to: CGPoint(x: 0, y: maxY * CGFloat(step) / CGFloat(steps)))
                scroller.reflectScrolledClipView(clip)
                hosting.layoutSubtreeIfNeeded()
                _ = Snapshot.capture(hosting)
                tops.append(clip.bounds.origin.y)
            }
        }
        XCTAssertGreaterThan(Set(tops).count, steps / 2, "the scroll view did not move")
        let perStep = scroll / (steps + 1)
        print(
            "PERF long thread: \(live.entries.count) entries, \(Int(height)) pt tall; open \(open), first draw \(firstDraw), scroll \(steps + 1) steps \(scroll) (\(perStep)/step)"
        )
        XCTAssertLessThan(open, .seconds(5))
        XCTAssertLessThan(firstDraw, .seconds(15))
        XCTAssertLessThan(perStep, .seconds(1))
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroller = view as? NSScrollView, (scroller.documentView?.frame.height ?? 0) > scroller.frame.height {
            return scroller
        }
        for subview in view.subviews { if let found = scrollView(in: subview) { return found } }
        return nil
    }
}
