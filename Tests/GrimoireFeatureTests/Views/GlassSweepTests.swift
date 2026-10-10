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
        Self.registerHostFonts()
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let root = try SampleSessions.write()
        defer { try? FileManager.default.removeItem(at: root) }

        let docs = MemoryDocs()
        let settings = SettingsStore(documents: docs)
        settings.toggle("/Users/me/Projects/AinkradGrimoire", mostRecent: "/Users/me/Projects/Ainkrad")
        let model = GrimoireModel(settings: settings, sessionsRoot: root)
        await model.reload()
        model.selectedThreadID = "glass"
        let deadline = Date().addingTimeInterval(5)
        while model.current == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }

        // Screen 4: the same thread waiting on a `git push` approval.
        let waiting = GrimoireModel(settings: settings, sessionsRoot: root)
        await waiting.reload()
        waiting.selectedThreadID = "glass"
        while waiting.current == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let push: JSONValue = ["command": "git push -u origin feat/glass-sidebar"]
        waiting.current?.apply(.block(messageID: "m9", .toolUse(id: "t9", name: "Bash", input: push)))
        waiting.current?.apply(
            .approval(
                ApprovalRequest(
                    id: "r9", toolUseID: "t9", toolName: "Bash", input: push, summary: "git push",
                    suggestions: [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "git push:*"]]]])))

        // Screen 5: the thread with the review pane open on this thread's edits.
        let reviewing = GrimoireModel(settings: settings, sessionsRoot: root)
        await reviewing.reload()
        reviewing.selectedThreadID = "glass"
        while reviewing.current == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        reviewing.isReviewOpen = true
        if let thread = reviewing.selectedThread, let review = reviewing.review(for: thread) {
            review.scope = .thread
            await review.load()
            review.addComment(
                "Use the kit's row background instead of a raw Capsule.",
                on: "Sources/Ainkrad/Features/Sidebar/SidebarRow.swift")
            review.commitMessage = "fix(sidebar): glass capsule selection"
        }

        // Screen 7: the New thread sheet over the window.
        let composing = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        await composing.reload()
        composing.isComposingNewThread = true

        // Screen 8: Settings, with usage a thread reported.
        let configuring = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        await configuring.reload()
        configuring.engineOverride = { FakeEngine() }
        configuring.startThread(
            project: "/Users/me/Projects/Ainkrad", prompt: "go", model: nil, mode: .ask, worktree: false)
        configuring.current?.apply(
            .usage([
                UsageWindow(name: "5-hour", utilization: 0.17, resetsAt: Date(timeIntervalSince1970: 1_791_652_200)),
                UsageWindow(name: "7-day", utilization: 0.22, resetsAt: nil),
            ]))
        configuring.isShowingSettings = true

        // Screen 9: no CLI found, and no threads yet.
        let noCLI = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        noCLI.cli = .missing(searched: "/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        let noThreads = GrimoireModel(
            settings: SettingsStore(documents: MemoryDocs()),
            sessionsRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grimoire-none-\(UUID())")
        )
        await noThreads.reload()

        let empty = GrimoireModel(settings: SettingsStore(documents: MemoryDocs()), sessionsRoot: root)
        await empty.reload()

        for (theme, skin) in [("neon", AinkradSkin.standard), ("glass", glass)] {
            let hostTheme = HostTheme(HostThemeTokens(skin: skin))
            // The host passes the theme's real status colours; a bare
            // `HostTheme` derives them from the accents.
            hostTheme.updateStatusColors(
                HostStatusColors(
                    success: skin.color(skin.palette.success), warning: skin.color(skin.palette.warning),
                    danger: skin.color(skin.palette.danger)))
            let screens: [(String, AnyView)] = [
                ("e42-thread", AnyView(RootView(model: model, theme: hostTheme))),
                ("e43-approval", AnyView(RootView(model: waiting, theme: hostTheme))),
                ("e45-review", AnyView(RootView(model: reviewing, theme: hostTheme))),
                ("e48-settings", AnyView(RootView(model: configuring, theme: hostTheme))),
                ("e49-no-cli", AnyView(RootView(model: noCLI, theme: hostTheme))),
                ("e49-no-threads", AnyView(RootView(model: noThreads, theme: hostTheme))),
                ("e47-new-thread", AnyView(RootView(model: composing, theme: hostTheme))),
                ("e41-no-selection", AnyView(RootView(model: empty, theme: hostTheme))),
            ]
            for (name, view) in screens {
                try LiveGlassCapture.shoot(
                    view.frame(width: 1100, height: 700)
                        .background(skin.color(skin.palette.background))
                        .ainkradSkin(skin)
                        // As the host: Exo 2 under Neon, the system face under Glass.
                        .environment(
                            \.ainkradTypography, AinkradTypography(fontFamilyName: theme == "neon" ? "Exo 2" : nil)
                        )
                        .environment(\.colorScheme, .dark),
                    size: CGSize(width: 1100, height: 700),
                    to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(theme).png"))
            }
        }
    }

    /// The host registers its bundled faces (Exo 2, JetBrains Mono) at launch;
    /// the test runner doesn't, so borrow the installed app's for true-to-app shots.
    static func registerHostFonts() {
        let resources = URL(fileURLWithPath: "/Applications/Ainkrad.app/Contents/Resources")
        let fonts = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        for font in fonts where font.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
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
            var lines = [
                #"{"type":"user","cwd":"\#(cwd)","gitBranch":"\#(thread.branch)","origin":{"kind":"human"},"message":{"role":"user","content":"go"}}"#,
                #"{"type":"assistant","cwd":"\#(cwd)","message":{"id":"m","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}]}}"#,
                #"{"type":"ai-title","aiTitle":"\#(thread.title)","sessionId":"\#(thread.id)"}"#,
            ]
            if thread.id == "glass" { lines = conversation(cwd: cwd, branch: thread.branch) + lines.suffix(1) }
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -thread.age)], ofItemAtPath: file.path)
        }
        return root
    }

    /// Screen 2 of the mockups as session lines: a prompt, thinking, prose,
    /// search / read / edit / build, and the agent's plan.
    static func conversation(cwd: String, branch: String) -> [String] {
        let file = "\(cwd)/Sources/Ainkrad/Features/Sidebar/SidebarRow.swift"
        func user(_ content: String) -> String {
            #"{"type":"user","cwd":"\#(cwd)","gitBranch":"\#(branch)","origin":{"kind":"human"},"message":{"role":"user","content":"\#(content)"}}"#
        }
        func assistant(_ block: String) -> String {
            #"{"type":"assistant","cwd":"\#(cwd)","gitBranch":"\#(branch)","message":{"id":"m","model":"claude-opus-5-5","content":[\#(block)]}}"#
        }
        func result(_ id: String, _ text: String) -> String {
            #"{"type":"user","cwd":"\#(cwd)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"\#(text)"}]}}"#
        }
        return [
            user(
                "The sidebar rows in Liquid Glass still draw a hairline under the selected thread. Remove it and make the selection a glass capsule like Finder."
            ),
            assistant(
                #"{"type":"thinking","thinking":"The stroke is probably an overlay on the row. Search for strokeBorder in the sidebar first."}"#
            ),
            assistant(
                #"{"type":"text","text":"I'll find where the selected row draws its stroke, then switch it to the kit's glass capsule under `skin.usesNativeGlass`."}"#
            ),
            assistant(
                #"{"type":"tool_use","id":"t1","name":"Grep","input":{"pattern":"strokeBorder","path":"\#(cwd)/Sources/Ainkrad/Features/Sidebar"}}"#
            ),
            result("t1", #"SidebarRow.swift:59\nSidebarRow.swift:88\nSidebarHeader.swift:21"#),
            assistant(#"{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"\#(file)"}}"#),
            result("t2", String(repeating: #"line\n"#, count: 141) + "line"),
            assistant(
                #"{"type":"tool_use","id":"t3","name":"Edit","input":{"file_path":"\#(file)","old_string":"        .padding(.horizontal, skin.size.s8)\n        .overlay(alignment: .bottom) { Rectangle().frame(height: 1) }\n        .contentShape(Rectangle())","new_string":"        .padding(.horizontal, skin.size.s8)\n        .background {\n            if isSelected { Capsule().glassEffect(.regular) }\n        }\n        .contentShape(Rectangle())"}}"#
            ),
            result("t3", "The file has been updated."),
            assistant(#"{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"make build"}}"#),
            result("t4", "** BUILD SUCCEEDED **"),
            assistant(
                #"{"type":"tool_use","id":"t5","name":"TodoWrite","input":{"todos":[{"content":"Find the selection stroke","status":"completed"},{"content":"Switch to a glass capsule","status":"completed"},{"content":"Run the sidebar goldens","status":"in_progress"},{"content":"Screenshot Neon | Glass","status":"pending"}]}}"#
            ),
            assistant(
                #"{"type":"text","text":"The selected row now draws a **glass capsule**; the hairline is gone. Next I'll run the sidebar goldens under both themes."}"#
            ),
        ]
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
