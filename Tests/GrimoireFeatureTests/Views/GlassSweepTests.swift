import AinkradAppKit
import AppKit
import SwiftUI
import Testing

@testable import GrimoireFeature

/// Grimoire's screens under Neon and Liquid Glass, written as
/// `<dir>/<name>-neon.png` / `-glass.png` for screen-by-screen review. A tool,
/// not a check: it runs only with AINKRAD_SWEEP_DIR and AINKRAD_THEMES_DIR (the
/// catalog's `themes/`) set. Live window captures — off-screen `cacheDisplay`
/// cannot draw Liquid Glass. Sessions are synthetic, so no real titles leak.
@Suite("Grimoire glass sweep")
@MainActor
struct GlassSweepTests {
    @Test("shoot the window under Neon and Glass")
    func shoot() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["AINKRAD_SWEEP_DIR"], let themes = env["AINKRAD_THEMES_DIR"] else {
            print("SKIPPED: set AINKRAD_SWEEP_DIR and AINKRAD_THEMES_DIR — no Glass sweep")
            return
        }
        let glass = try Self.glassSkin(themes: URL(fileURLWithPath: themes))
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let root = try SampleSessions.write()
        defer { try? FileManager.default.removeItem(at: root) }

        let docs = MemoryDocs()
        let settings = SettingsStore(documents: docs)
        settings.toggle("/Users/me/Projects/AinkradGrimoire", mostRecent: "/Users/me/Projects/Ainkrad")
        let model = GrimoireModel(settings: settings, sessionsRoot: root)
        await model.reload()
        model.selectedThreadID = "glass"

        let empty = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        await empty.reload()

        for (theme, skin) in [("neon", AinkradSkin.standard), ("glass", glass)] {
            let hostTheme = HostTheme(HostThemeTokens(skin: skin))
            let screens: [(String, AnyView)] = [
                ("e41-window", AnyView(RootView(model: model, theme: hostTheme))),
                ("e41-no-selection", AnyView(RootView(model: empty, theme: hostTheme))),
            ]
            for (name, view) in screens {
                try LiveGlassCapture.shoot(
                    view.frame(width: 1100, height: 700)
                        .background(skin.color(skin.palette.background))
                        .ainkradSkin(skin)
                        .environment(\.colorScheme, .dark),
                    size: CGSize(width: 1100, height: 700),
                    to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(theme).png"))
            }
        }
    }

    /// `glass-dark.theme` on the standard skin, coloured by `glass-dark.scheme`,
    /// composed the way the host's `ThemeCatalog.compose` does.
    static func glassSkin(themes: URL) throws -> AinkradSkin {
        let dir = themes.appendingPathComponent("glass")
        let base = try JSONEncoder().encode(AinkradSkin.standard)
        let theme = try Data(contentsOf: dir.appendingPathComponent("glass-dark.theme"))
        let variant = try #require(ainkradLoadThemes([base, theme]).themes["glass.dark"])
        var scheme = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("glass-dark.scheme")))
                as? [String: Any])
        scheme.removeValue(forKey: "appearance")
        scheme.removeValue(forKey: "host")
        scheme["base"] = "glass.dark"
        return try AinkradThemeFile(
            decoding: JSONSerialization.data(withJSONObject: scheme), bases: ["glass.dark": variant]
        ).skin
    }
}

/// A `~/.claude/projects`-shaped folder with made-up sessions.
enum SampleSessions {
    static func write() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-sweep-\(UUID())")
        let threads: [(project: String, id: String, title: String, branch: String, age: TimeInterval)] = [
            ("Ainkrad", "glass", "Liquid Glass sidebar polish", "feat/glass-sidebar", 20),
            ("Ainkrad", "release", "Release 0.31 and pin round", "release/0.31", 4 * 60),
            ("Ainkrad/.claude/worktrees/scry-fix", "scry", "Scry markdown newlines", "worktree-scry-fix", 3_600),
            ("Ainkrad", "abi", "ABI check on Xcode beta", "development", 3 * 3_600),
            ("Ainkrad", "lore", "Lore editor theming", "development", 26 * 3_600),
            ("AinkradGrimoire", "engine", "Claude engine over stream-json", "feat/claude-engine", 2 * 3_600),
            ("AinkradGrimoire", "index", "Session index speed", "feat/claude-sessions", 2 * 3_600 + 60),
            ("GitScope", "g1", "Commit graph virtualisation", "main", 3 * 86_400),
            ("AutomotiveAi", "a1", "Twilio webhook retries", "development", 5 * 86_400),
            ("ULYNK", "u1", "Backup scheduler", "main", 9 * 86_400),
        ]
        for thread in threads {
            let cwd = "/Users/me/Projects/\(thread.project)"
            let directory = root.appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(thread.id).jsonl")
            let lines = [
                #"{"type":"user","cwd":"\#(cwd)","gitBranch":"\#(thread.branch)","origin":{"kind":"human"},"message":{"role":"user","content":"go"}}"#,
                #"{"type":"assistant","cwd":"\#(cwd)","message":{"id":"m","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}]}}"#,
                #"{"type":"ai-title","aiTitle":"\#(thread.title)","sessionId":"\#(thread.id)"}"#,
            ]
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -thread.age)], ofItemAtPath: file.path)
        }
        return root
    }
}

/// A real window at desktop level (behind every window, no focus taken) that
/// claims key appearance so glass tints render; `screencapture -l` grabs it.
@MainActor
enum LiveGlassCapture {
    private final class KeyAppearancePanel: NSPanel {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { false }
        @objc var hasKeyAppearance: Bool { true }
        @objc var hasMainAppearance: Bool { true }
        @objc var _hasActiveAppearance: Bool { true }
        @objc var _hasActiveAppearanceIgnoringKeyFocus: Bool { true }
    }

    static func shoot(_ view: some View, size: CGSize, to url: URL) throws {
        let panel = KeyAppearancePanel(
            contentRect: NSRect(origin: CGPoint(x: 200, y: 200), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hasShadow = false
        panel.contentView = NSHostingView(
            rootView: view.environment(\.ainkradMotionBudget, .frozen).environment(\.controlActiveState, .key))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), url.path]
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus == 0 { return }
        // The test runner may lack the Screen Recording grant: hand the window
        // to `.build/capture-broker.sh <dir>`, which runs `screencapture` for it.
        let requests = url.deletingLastPathComponent().appendingPathComponent(".requests", isDirectory: true)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        try "\(panel.windowNumber) \(url.path)".write(
            to: requests.appendingPathComponent(UUID().uuidString + ".req"), atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(FileManager.default.fileExists(atPath: url.path), "no capture for \(url.lastPathComponent)")
    }
}
